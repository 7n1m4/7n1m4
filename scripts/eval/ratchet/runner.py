#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Ratchet runner for the `ports-done-today` flow.

One row per (case, rep) goes to ``<out>/results.jsonl``; attempts that never
produced a scorable output go to ``<out>/errors.jsonl``.  The candidate tree is
a throwaway directory holding only the files a case is allowed to touch, so the
model under test cannot read ground truth and a trial leaves fresh state.

Command shape (the host fills ``{variant}`` and ``{flow_dir}``)::

    python3 scripts/eval/ratchet/runner.py --variant baseline --out <flow>/baseline

Environment knobs (all optional):
    RATCHET_MODEL     opencode model id (default a keyless free model)
    RATCHET_AGENT_CMD template for the coding agent; ``{model} {prompt} {cwd}``
                      are substituted, which is how the fake-agent smoke test
                      replaces the real ``opencode run`` entry point
    RATCHET_REPS      reps per case (default 1)
    RATCHET_CONCURRENCY  parallel cases (default 3)
    RATCHET_CASE_TIMEOUT_S  hard per-case wall-clock ceiling (default 900)
    RATCHET_MAX_ATTEMPTS  agent attempts per slot before errors.jsonl (default 3)
    RATCHET_RETRY_BASE_S  first backoff delay (default 5)
    RATCHET_CASES     cases.jsonl override
    RATCHET_REPO_ROOT base tree for the diff (default: this checkout)
"""

from __future__ import annotations

import argparse
import json
import os
import random
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from typing import Any, Sequence

sys.path.insert(0, str(Path(__file__).resolve().parent))
import grader  # noqa: E402  (sibling module; path set above)

DEFAULT_MODEL = "kilo/baidu/ernie-5.5-flash-preview:free"
DEFAULT_AGENT_CMD = (
    "opencode run --auto --model {model} --title ratchet-{variant}-{case_id}-rep{rep}"
    " --format json {prompt}"
)
TRACE_ROLE = {
    "user": "user",
    "assistant": "assistant",
    "reasoning": "assistant",
    "tool": "tool_call",
}
FAIL_INFRA = "infra_error"
FAIL_TIMEOUT = "case_timeout"
FAIL_AGENT = "agent_error"
FAIL_MODEL = "served_model_mismatch"
FAIL_BAD_RESPONSE = "unscorable_response"

_STATUS_RE = re.compile(r"^@@ -\d+(?:,\d+)? \+\d+(?:,\d+)? @@", re.M)




# --------------------------------------------------------------------------- #
# Environment
# --------------------------------------------------------------------------- #

def _env_float(name: str, default: float) -> float:
    raw = os.environ.get(name)
    if not raw:
        return default
    try:
        value = float(raw)
    except ValueError:
        return default
    return value if value > 0 else default


def _env_int(name: str, default: int) -> int:
    return int(_env_float(name, default))


def _cfg() -> dict[str, Any]:
    return {
        "model": os.environ.get("RATCHET_MODEL") or DEFAULT_MODEL,
        "agent_cmd": os.environ.get("RATCHET_AGENT_CMD") or DEFAULT_AGENT_CMD,
        "reps": _env_int("RATCHET_REPS", 1),
        "concurrency": _env_int("RATCHET_CONCURRENCY", 3),
        "case_timeout": _env_float("RATCHET_CASE_TIMEOUT_S", 900.0),
        "max_attempts": _env_int("RATCHET_MAX_ATTEMPTS", 3),
        "retry_base": _env_float("RATCHET_RETRY_BASE_S", 5.0),
    }


# --------------------------------------------------------------------------- #
# Slot bookkeeping (idempotent resume)
# --------------------------------------------------------------------------- #

def _read_jsonl(path: Path) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    if not path.is_file():
        return rows
    with path.open("r", encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            try:
                row = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(row, dict):
                rows.append(row)
    return rows


def _slot_key(row: dict[str, Any]) -> tuple[str, int] | None:
    prompt_id = row.get("prompt_id")
    rep = row.get("rep")
    if not isinstance(prompt_id, str) or not isinstance(rep, int):
        return None
    return prompt_id, rep


def _done_slots(out_dir: Path) -> set[tuple[str, int]]:
    done: set[tuple[str, int]] = set()
    for row in _read_jsonl(out_dir / "results.jsonl"):
        key = _slot_key(row)
        if key:
            done.add(key)
    for row in _read_jsonl(out_dir / "errors.jsonl"):
        key = _slot_key(row)
        if key and row.get("failure_class") not in (FAIL_BAD_RESPONSE, FAIL_MODEL):
            done.add(key)
    return done


def _append_jsonl(path: Path, row: dict[str, Any]) -> None:
    with path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(row, ensure_ascii=False) + "\n")
        handle.flush()


def _write_json(path: Path, payload: Any) -> None:
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
                   encoding="utf-8")
    tmp.replace(path)


# --------------------------------------------------------------------------- #
# Candidate tree: only the case's writable surface, diffed against the base
# --------------------------------------------------------------------------- #

def _case_surface(case: dict[str, Any]) -> list[str]:
    return [p for p in (case.get("allowed_paths") or []) if p]


def _copy_surface(repo_root: Path, dest: Path, paths: Sequence[str]) -> None:
    for rel in paths:
        if rel == ".":
            continue
        src = repo_root / rel
        if src.is_dir():
            shutil.copytree(src, dest / rel, dirs_exist_ok=True,
                            ignore=shutil.ignore_patterns(
                                ".dart_tool", "build", "node_modules", ".git"))
        elif src.is_file():
            target = dest / rel
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(src, target)


def _strip_leading_abs_path(value: str) -> str:
    """Strip a leading absolute path, keeping tail after last /a/ or /b/."""
    if not value:
        return value
    prefix = tempfile.gettempdir()
    if value.startswith(prefix):
        value = value[len(prefix):]
        if value.startswith(os.sep):
            value = value[len(os.sep):]
    while value.startswith("a/") or value.startswith("b/"):
        value = value[2:]
    best = -1
    best_marker = "/a/"
    for marker in ("/a/", "/b/"):
        pos = value.rfind(marker)
        if pos > best:
            best = pos
            best_marker = marker
    if best >= 0:
        return value[best + len(best_marker):]
    return value


def _drop_report_sections(text: str, rel: str = "") -> str | None:
    """Remove ``diff --git`` sections whose b-path is eval_report.json."""
    if not text:
        return None
    lines = text.splitlines(keepends=True)
    out: list[str] = []
    i = 0
    n = len(lines)
    while i < n:
        if lines[i].startswith("diff --git "):
            start = i
            i += 1
            while i < n and not lines[i].startswith("diff --git "):
                i += 1
            section = lines[start:i]
            header = section[0]
            parts = header.rstrip("\n").split()
            bpath = ""
            if len(parts) >= 4:
                btoken = parts[3]
                if btoken.startswith("b/"):
                    bpath = btoken[2:]
            if bpath == "eval_report.json" or bpath.endswith("/eval_report.json"):
                continue
            if rel:
                rel_i = rel
            else:
                rel_i = bpath
                for marker in ("/scratch/work/", "/worktree/"):
                    pos = rel_i.rfind(marker)
                    if pos >= 0:
                        rel_i = rel_i[pos + len(marker):]
                        break
                rel_i = _strip_leading_abs_path(rel_i)
            old_null = any(l.startswith("--- /dev/null") for l in section)
            new_null = any(l.startswith("+++ /dev/null") for l in section)
            if old_null:
                new_null = False
            if new_null:
                old_null = False
            hunks = [l for l in section
                     if not (l.startswith("diff --git ") or l.startswith("index ")
                             or l.startswith("--- ") or l.startswith("+++ ")
                             or l.startswith("new file mode")
                             or l.startswith("deleted file mode"))]
            if not any(l.startswith("@@") for l in hunks):
                continue
            header = [f"diff --git a/{rel_i} b/{rel_i}"]
            header.append(f"+++ b/{rel_i}")
            header.append(f"--- a/{rel_i}")
            out.extend(h + "\n" for h in header)
            out.extend(hunks)
        else:
            out.append(lines[i])
            i += 1
    result = "".join(out)
    if not _STATUS_RE.search(result or ""):
        return None
    return result


def _git_diff(repo_root: Path, base: Path, work: Path, rel: str) -> str | None:
    """Unified diff of one path, work tree vs base tree, a/ b/ prefixed."""
    if rel == ".":
        try:
            proc = subprocess.run(
                ["git", "-C", str(repo_root), "diff", "--no-color", "--no-ext-diff",
                 "--src-prefix=a/", "--dst-prefix=b/", "--no-index", "--",
                 str(base), str(work)],
                capture_output=True, text=True, timeout=120,
            )
        except (OSError, subprocess.SubprocessError):
            return None
        if proc.returncode not in (0, 1):
            return None
        if not _STATUS_RE.search(proc.stdout or ""):
            return None
        return _drop_report_sections(proc.stdout, "")
    if not (work / rel).exists() and not (base / rel).exists():
        return None
    try:
        proc = subprocess.run(
            ["git", "-C", str(repo_root), "diff", "--no-color", "--no-ext-diff",
             "--src-prefix=a/", "--dst-prefix=b/", "--no-index", "--",
             str(base / rel), str(work / rel)],
            capture_output=True, text=True, timeout=120,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if proc.returncode not in (0, 1):
        return None
    return _drop_report_sections(proc.stdout, rel)


def _collect_patch(repo_root: Path, base: Path, work: Path,
                   paths: Sequence[str]) -> str:
    chunks = [_git_diff(repo_root, base, work, rel) for rel in paths]
    return "".join(c for c in chunks if c)


def _has_diff(text: str) -> bool:
    return bool(_STATUS_RE.search(text))


# --------------------------------------------------------------------------- #
# Agent invocation
# --------------------------------------------------------------------------- #

def _report_rel(case: dict[str, Any]) -> str:
    return "eval_report.json"


def _build_prompt(case: dict[str, Any], variant: str, rep: int) -> str:
    report_rel = _report_rel(case)
    report_target = report_rel
    return (
        "You are working inside a scratch copy of the AnimA repository that "
        "contains ONLY the files this task may modify. Never touch a path "
        "outside it, and never read or write anything outside the current "
        "directory.\n\n"
        f"Task ({case.get('id')}, trial {variant} rep {rep}):\n"
        f"{case.get('prompt')}\n\n"
        f"When you are done, write {report_target} (repo-relative; not part of "
        "the diff) with exactly these keys:\n"
        '  {"case_id": "<the task id above>", "changed_files": '
        '["<repo-relative path>"], "commands": ["<verify command you ran>"], '
        '"tests_passed": <true only if every listed command exited 0>}\n'
        "changed_files must list every file you created, modified or deleted, "
        "repo-relative, and nothing else. Then reply with one short line "
        "summarising what changed."
    )


def _agent_argv(cfg: dict[str, Any], variant: str, case_id: str, rep: int,
                prompt: str) -> list[str]:
    text = cfg["agent_cmd"]
    for key, value in (
        ("model", cfg["model"]),
        ("variant", variant),
        ("case_id", case_id),
        ("rep", str(rep)),
    ):
        text = text.replace("{" + key + "}", value)
    head, sep, tail = text.partition("{prompt}")
    argv = shlex.split(head)
    argv.append(prompt)
    if sep:
        argv.extend(shlex.split(tail))
    return argv


def _parse_events(stream: str) -> tuple[str | None, dict[str, Any] | None,
                                     str | None, bool, str | None]:
    """Return (session_id, usage, error_message, truncated, served_model) from opencode JSONL events."""
    session: str | None = None
    usage: dict[str, int] = {"input": 0, "output": 0, "reasoning": 0,
                             "cache_read": 0, "cache_write": 0}
    cost = 0.0
    saw_finish = False
    error: str | None = None
    truncated = False
    served: str | None = None
    for line in stream.splitlines():
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        if not isinstance(event, dict):
            continue
        session = event.get("sessionID") or session
        kind = event.get("type")
        if kind == "error":
            err = event.get("error")
            if isinstance(err, dict):
                error = f"{err.get('type')}: {err.get('message')}"
            else:
                error = str(err)
        elif kind == "step_finish":
            part = event.get("part")
            if isinstance(part, dict):
                saw_finish = True
                cost += float(part.get("cost") or 0.0)
                tokens = part.get("tokens")
                if isinstance(tokens, dict):
                    usage["input"] += int(tokens.get("input") or 0)
                    usage["output"] += int(tokens.get("output") or 0)
                    usage["reasoning"] += int(tokens.get("reasoning") or 0)
                    cache = tokens.get("cache")
                    if isinstance(cache, dict):
                        usage["cache_read"] += int(cache.get("read") or 0)
                        usage["cache_write"] += int(cache.get("write") or 0)
                reason = part.get("reason")
                truncated = reason not in (None, "stop")
                model = part.get("model") or part.get("modelID")
                if model:
                    served = model
    if error:
        return session, None, error, False, served
    if not saw_finish:
        return session, None, "no step_finish event", False, served
    usage["cost"] = cost
    return session, usage, None, truncated, served


def _export_trace(session: str, dest: Path, timeout: float) -> Path | None:
    try:
        proc = subprocess.run(
            ["opencode", "session", "export", "--sanitize", session],
            capture_output=True, text=True, timeout=max(timeout, 60.0),
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if proc.returncode != 0 or not proc.stdout.strip():
        return None
    try:
        payload = json.loads(proc.stdout)
    except json.JSONDecodeError:
        return None
    _write_json(dest, payload)
    return dest


def _export_model(dest: Path) -> str | None:
    try:
        payload = json.loads(dest.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    info = payload.get("info") if isinstance(payload, dict) else None
    if not isinstance(info, dict):
        return None
    provider = info.get("providerID")
    model_id = info.get("id")
    if provider and model_id:
        return f"{provider}/{model_id}"
    return model_id or provider


def _trace_from_events(events: list[dict[str, Any]]) -> list[dict[str, Any]]:
    trace: list[dict[str, Any]] = []
    for event in events:
        kind = event.get("type")
        part = event.get("part") if isinstance(event.get("part"), dict) else {}
        if kind == "text" and part.get("text"):
            trace.append({"role": "assistant", "content": part["text"]})
        elif kind == "tool_use":
            state = part.get("state") if isinstance(part.get("state"), dict) else {}
            trace.append({
                "role": "tool_call",
                "content": json.dumps(state.get("input") or {}, ensure_ascii=False),
                "name": part.get("tool") or part.get("name") or "tool",
            })
    return trace


# --------------------------------------------------------------------------- #
# One slot
# --------------------------------------------------------------------------- #

def _slot_dir(out_dir: Path, case_id: str, rep: int) -> Path:
    return out_dir / "slots" / f"{case_id}_rep{rep}"


def _run_attempt(cfg: dict[str, Any], case: dict[str, Any], variant: str,
                 rep: int, repo_root: Path, slot: Path) -> dict[str, Any]:
    """One agent attempt in a fresh scratch tree. Returns an error fragment or a scorable row fragment."""
    scratch = slot / "scratch"
    base = scratch / "base"
    work = scratch / "work"
    for tree in (base, work):
        if tree.exists():
            shutil.rmtree(tree)
        tree.mkdir(parents=True)
    surface = _case_surface(case)
    if not surface:
        surface = ["."]
    _copy_surface(repo_root, base, surface)
    _copy_surface(repo_root, work, surface)

    argv = _agent_argv(cfg, variant, str(case.get("id")), rep,
                       _build_prompt(case, variant, rep))
    started = time.monotonic()
    try:
        proc = subprocess.run(
            argv, cwd=str(work), capture_output=True, text=True,
            timeout=cfg["case_timeout"],
        )
        stdout, stderr, code = proc.stdout, proc.stderr, proc.returncode
    except subprocess.TimeoutExpired as exc:
        stdout = exc.stdout if isinstance(exc.stdout, str) else ""
        stderr = exc.stderr if isinstance(exc.stderr, str) else ""
        code, timed_out = None, True
    else:
        timed_out = False
    latency = round(time.monotonic() - started, 3)

    events: list[dict[str, Any]] = []
    for line in stdout.splitlines():
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(event, dict):
            events.append(event)

    session, usage, agent_error, truncated, served = _parse_events(stdout)
    if timed_out:
        return {"kind": "error", "failure_class": FAIL_TIMEOUT,
                "detail": f"case exceeded {cfg['case_timeout']}s", "usage": None,
                "session": session, "events": events, "latency": latency}
    if agent_error:
        return {"kind": "error", "failure_class": FAIL_AGENT,
                "detail": agent_error, "usage": None, "session": session,
                "events": events, "latency": latency}
    if code != 0:
        return {"kind": "error", "failure_class": FAIL_AGENT,
                "detail": f"agent exit {code}: {stderr.strip()[-500:]}",
                "usage": None, "session": session, "events": events,
                "latency": latency}

    if session:
        _export_trace(session, slot / "trace.json", cfg["case_timeout"])
    if not (slot / "trace.json").is_file():
        fallback = _trace_from_events(events)
        if fallback:
            _write_json(slot / "trace.json", fallback)

    if served and served != cfg["model"]:
        return {"kind": "error", "failure_class": FAIL_MODEL,
                "detail": f"served model {served} != {cfg['model']}",
                "usage": usage, "session": session, "events": events,
                "latency": latency}

    patch = _collect_patch(repo_root, base, work, surface)
    change_expected = bool(_case_surface(case))
    if change_expected and not _has_diff(patch):
        return {"kind": "error", "failure_class": FAIL_BAD_RESPONSE,
                "detail": "agent produced no diff",
                "usage": usage, "session": session, "events": events,
                "latency": latency}

    # An empty patch.diff is a valid no-change submission for cases with
    # empty allowed_paths (rejection/no-change cases).
    (slot / "patch.diff").write_text(patch or "", encoding="utf-8")

    report_src = work / "eval_report.json"
    if report_src.is_file():
        shutil.copy2(report_src, slot / "eval_report.json")

    return {"kind": "row", "usage": usage, "session": session,
            "events": events, "latency": latency, "patch": patch,
            "truncated": truncated}


def _grade_slot(case: dict[str, Any], slot: Path, repo_root: Path,
                truncated: bool) -> dict[str, Any]:
    return grader.grade_case(case, slot, repo_root, truncated=truncated)


def _run_slot(cfg: dict[str, Any], case: dict[str, Any], variant: str, rep: int,
              out_dir: Path, repo_root: Path, train: bool) -> None:
    slot = _slot_dir(out_dir, str(case.get("id")), rep)
    slot.mkdir(parents=True, exist_ok=True)
    delay = cfg["retry_base"]
    for attempt in range(1, cfg["max_attempts"] + 1):
        result = _run_attempt(cfg, case, variant, rep, repo_root, slot)
        if result["kind"] == "row":
            break
        _append_jsonl(out_dir / "errors.jsonl", {
            "prompt_id": case.get("id"), "rep": rep,
            "prompt": case.get("prompt"), "tags": case.get("tags") or [],
            "failure_class": result["failure_class"],
            "detail": result["detail"], "attempt": attempt,
            "latency_s": result["latency"],
        })
        if attempt == cfg["max_attempts"]:
            return
        time.sleep(delay + random.uniform(0, delay))
        delay = min(delay * 2, 60.0)

    grade = _grade_slot(case, slot, repo_root, truncated=result["truncated"])
    trace = slot / "trace.json"
    if train and trace.is_file():
        published = out_dir / "traces" / f"{case.get('id')}_rep{rep}.json"
        published.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(trace, published)
    elif trace.is_file():
        trace.unlink(missing_ok=True)

    row = {
        "prompt_id": case.get("id"),
        "rep": rep,
        "prompt": case.get("prompt"),
        "tags": case.get("tags") or [],
        "grade": grade,
        "status": grade["status"],
        "model": cfg["model"],
        "usage": result["usage"],
        "latency_s": result["latency"],
        "attempts": attempt,
    }
    _append_jsonl(out_dir / "results.jsonl", row)


# --------------------------------------------------------------------------- #
# Main
# --------------------------------------------------------------------------- #

def main(argv: Sequence[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--variant", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--repo-root", default=None)
    ap.add_argument("--cases", default=None)
    ap.add_argument("--case-id", default=None, help="run one case only")
    args = ap.parse_args(argv)

    cfg = _cfg()
    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)
    (out_dir / "errors.jsonl").touch(exist_ok=True)
    repo_root = Path(args.repo_root) if args.repo_root else Path(
        os.environ.get("RATCHET_REPO_ROOT") or Path(__file__).resolve().parents[3])
    cases_path = Path(args.cases or os.environ.get("RATCHET_CASES")
                      or Path(__file__).resolve().parent / "cases.jsonl")
    cases = grader.load_cases(cases_path)
    if args.case_id:
        cases = [c for c in cases if str(c.get("id")) == args.case_id]
        if not cases:
            raise SystemExit(f"case id {args.case_id!r} not in {cases_path}")

    split = _load_split(out_dir.parent)
    done = _done_slots(out_dir)
    jobs: list[tuple[dict[str, Any], int, bool]] = []
    for case in cases:
        case_id = str(case.get("id"))
        train = case_id in split["train"] if split else True
        for rep in range(1, cfg["reps"] + 1):
            if (case_id, rep) in done:
                continue
            jobs.append((case, rep, train))

    if not jobs:
        print(f"{args.variant}: nothing to do ({len(done)} slots already done)")
        return 0

    print(f"{args.variant}: {len(jobs)} slot(s), model={cfg['model']}")
    with ThreadPoolExecutor(max_workers=max(1, cfg["concurrency"])) as pool:
        futures = [
            pool.submit(_run_slot, cfg, case, args.variant, rep, out_dir,
                        repo_root, train)
            for case, rep, train in jobs
        ]
        for future in futures:
            future.result()
    return 0


def _load_split(flow_dir: Path) -> dict[str, list[str]] | None:
    state = flow_dir / "_state.json"
    if not state.is_file():
        return None
    try:
        data = json.loads(state.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    train = data.get("train_ids") or []
    test = data.get("test_ids") or []
    if not train and not test:
        return None
    return {"train": [str(x) for x in train], "test": [str(x) for x in test]}


if __name__ == "__main__":
    sys.exit(main())