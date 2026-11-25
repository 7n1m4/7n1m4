#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Deterministic grader for the `ports-done-today` ratchet flow.

Reads ONE case row (10-key JSONL schema) plus a run directory that holds the
candidate under test, and emits a ratchet `grade` dict:

    {"case_id": str,
     "metrics": {"scope_precision": float, "behavior": float,
                 "verification": float, "reporting": float},
     "score": float,
     "status": "ok" | "truncated",
     "failures": [str, ...],            # failure classes
     "details": {...}}                  # human-readable evidence

Score formula (documented, fixed; weights sum to 1.0):

    score = 0.35 * behavior
          + 0.25 * scope_precision
          + 0.25 * verification
          + 0.15 * reporting

Metric definitions
------------------
scope_precision  Share of the diff that stayed inside the case allowlist.
                 1.0 for an empty diff (a "should-not-change" case is
                 satisfied by touching nothing), 0.0 as soon as a
                 `forbidden_paths` entry is touched, otherwise
                 allowed_changes / total_changes.  With an empty allowlist any
                 change at all scores 0.0.
behavior         Required-pattern coverage in the post-image, gated to 0.0 by
                 any `forbidden_patterns` hit on an added line and by a missing
                 `expected_files` entry.  No required patterns -> 1.0 unless a
                 gate fires.
verification     Mean of `verify_commands` exit status: 1.0 when every declared
                 command exits 0, 0.0 when any exits non-zero, 1.0 when the case
                 declares none.  A command that cannot be found is NOT a score
                 signal: it raises the `environment_error` failure class.
reporting        Machine-readable `eval_report.json` in the run dir: schema
                 validity, case id match, changed-file list consistent with the
                 real diff, and declared commands/tests_passed consistent with
                 what was actually executed.

Failure classes
---------------
patch_apply_failed, scope_violation, behavior_regression, test_failure,
missing_or_invalid_report, report_inconsistent, environment_error,
truncated_output

Only the Python standard library is used.  Verification-command failures are
score signal; only a missing command (or a missing candidate tree) is an
environment error.
"""

from __future__ import annotations

import argparse
import fnmatch
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Iterable, Sequence

# --------------------------------------------------------------------------- #
# Tunables
# --------------------------------------------------------------------------- #

WEIGHTS = {
    "behavior": 0.35,
    "scope_precision": 0.25,
    "verification": 0.25,
    "reporting": 0.15,
}

DEFAULT_TIMEOUT_S = 900.0
MAX_SCAN_BYTES = 2_000_000
SKIP_DIRS = frozenset({
    ".git", "node_modules", "build", ".dart_tool", "coverage", "dist",
    ".next", "target", "__pycache__", ".venv", "vendor", ".gradle",
    ".idea", ".vscode", "out", ".turbo", ".cache",
})

FAIL_PATCH = "patch_apply_failed"
FAIL_SCOPE = "scope_violation"
FAIL_BEHAVIOR = "behavior_regression"
FAIL_TEST = "test_failure"
FAIL_REPORT = "missing_or_invalid_report"
FAIL_REPORT_INCONSISTENT = "report_inconsistent"
FAIL_ENV = "environment_error"
FAIL_TRUNCATED = "truncated_output"

_HUNK_RE = re.compile(r"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@")


class PatchError(RuntimeError):
    """The submitted unified diff does not apply to the base tree."""


# --------------------------------------------------------------------------- #
# Path globs
# --------------------------------------------------------------------------- #

def _normalize(path: str) -> str:
    return path.replace("\\", "/").lstrip("./")


def path_matches(path: str, pattern: str) -> bool:
    """Case-sensitive allowlist match.

    `crates/` (trailing slash) is a subtree match; a bare `crates` also matches
    the subtree so hand-written cases behave the same either way.  Otherwise
    fnmatch against the repo-relative path.
    """
    p = _normalize(path)
    pat = _normalize(pattern)
    if not pat:
        return False
    if pat.endswith("/"):
        return p.startswith(pat)
    if fnmatch.fnmatchcase(p, pat) or p == pat:
        return True
    return p.startswith(pat + "/")


def matches_any(path: str, patterns: Iterable[str]) -> bool:
    return any(path_matches(path, pat) for pat in patterns)


# --------------------------------------------------------------------------- #
# Unified diff parsing / application
# --------------------------------------------------------------------------- #

@dataclass
class FilePatch:
    path: str
    old_path: str | None = None
    hunks: list[tuple[int, list[str], list[str]]] = field(default_factory=list)
    added: list[str] = field(default_factory=list)
    removed: list[str] = field(default_factory=list)
    is_new: bool = False
    is_delete: bool = False


def _strip_prefix(token: str) -> str:
    if token.startswith(("a/", "b/")):
        return token[2:]
    return token


def parse_unified_diff(text: str) -> list[FilePatch]:
    """Parse a unified diff into per-file hunks.  Raises PatchError on garbage."""
    lines = text.splitlines()
    files: list[FilePatch] = []
    cur: FilePatch | None = None
    in_hunks = False
    old_no = new_no = 0
    old_rem = new_rem = 0

    for raw in lines:
        if raw.startswith("diff --git "):
            cur = None
            in_hunks = False
            continue
        if raw.startswith("new file mode"):
            if cur is None:
                raise PatchError("`new file mode` without a `diff --git` header")
            cur.is_new = True
            continue
        if raw.startswith("deleted file mode"):
            if cur is None:
                raise PatchError("`deleted file mode` without a `diff --git` header")
            cur.is_delete = True
            continue
        if raw.startswith("rename from "):
            if cur is None:
                raise PatchError("`rename from` without a `diff --git` header")
            cur.old_path = _strip_prefix(raw[len("rename from "):].strip())
            continue
        if raw.startswith("rename to "):
            if cur is None:
                raise PatchError("`rename to` without a `diff --git` header")
            cur.path = _strip_prefix(raw[len("rename to "):].strip())
            continue
        if raw.startswith("--- "):
            token = raw[4:].strip()
            if token == "/dev/null":
                if cur is None:
                    raise PatchError("`--- /dev/null` without a file header")
                cur.is_new = True
            elif cur is not None and cur.old_path is None:
                cur.old_path = _strip_prefix(token.split("\t")[0])
            in_hunks = False
            continue
        if raw.startswith("+++ "):
            token = raw[4:].strip()
            if cur is None:
                cur = FilePatch(path="")
            if token == "/dev/null":
                cur.is_delete = True
            else:
                cur.path = _strip_prefix(token.split("\t")[0])
            in_hunks = False
            continue

        m = _HUNK_RE.match(raw)
        if m:
            if cur is None or not cur.path:
                raise PatchError("hunk header without a file path")
            old_no = int(m.group(1))
            old_rem = int(m.group(2)) if m.group(2) is not None else 1
            new_no = int(m.group(3))
            new_rem = int(m.group(4)) if m.group(4) is not None else 1
            cur.hunks.append((old_no, [], []))
            in_hunks = True
            continue

        if not in_hunks or cur is None:
            continue
        if raw.startswith("\\"):  # "\ No newline at end of file"
            continue
        if raw.startswith("+"):
            cur.hunks[-1][2].append(raw[1:])
            cur.added.append(raw[1:])
            new_rem -= 1
        elif raw.startswith("-"):
            cur.hunks[-1][1].append(raw[1:])
            cur.removed.append(raw[1:])
            old_rem -= 1
        elif raw.startswith(" ") or raw == "":
            cur.hunks[-1][1].append(raw[1:] if raw else "")
            cur.hunks[-1][2].append(raw[1:] if raw else "")
            old_rem -= 1
            new_rem -= 1
        else:
            raise PatchError(f"unexpected diff line: {raw[:60]!r}")

    if not lines:
        raise PatchError("empty diff")
    for fp in files:
        if not fp.hunks and not (fp.is_new or fp.is_delete):
            raise PatchError(f"no hunks for {fp.path}")
    return [fp for fp in files if fp.path]


def _find_block(base: Sequence[str], block: Sequence[str], start: int,
                hint: int) -> int | None:
    if not block:
        return max(0, min(hint, len(base)))
    if base[start:start + len(block)] == list(block):
        return start
    span = 4000
    lo = max(0, hint - span)
    hi = min(len(base) - len(block), hint + span)
    for off in range(0, max(hi - lo, 0) + 1):
        for cand in (hint + off, hint - off):
            if lo <= cand <= hi and base[cand:cand + len(block)] == list(block):
                return cand
    return None


def apply_hunks(base: Sequence[str], hunks: Sequence[tuple[int, list[str], list[str]]],
                path: str) -> list[str]:
    out: list[str] = []
    idx = 0
    for old_start, old_block, new_block in hunks:
        hint = max(0, old_start - 1)
        found = _find_block(base, old_block, idx, hint)
        if found is None:
            raise PatchError(
                f"hunk at line {old_start} of {path} does not apply")
        out.extend(base[idx:found])
        out.extend(new_block)
        idx = found + len(old_block)
    out.extend(base[idx:])
    return out


def read_text(path: Path) -> str | None:
    try:
        if path.stat().st_size > MAX_SCAN_BYTES:
            return None
        data = path.read_bytes()
    except OSError:
        return None
    if b"\0" in data[:4096]:
        return None
    return data.decode("utf-8", "replace")


# --------------------------------------------------------------------------- #
# Candidate preparation
# --------------------------------------------------------------------------- #

@dataclass
class Candidate:
    root: Path | None
    changed: dict[str, str]          # path -> "added|modified|deleted|renamed"
    added_lines: list[tuple[str, str]]  # (path, line)
    patch_ok: bool
    patch_note: str
    env_error: str | None = None
    temp_dir: Path | None = None

    def cleanup(self) -> None:
        if self.temp_dir is not None:
            shutil.rmtree(self.temp_dir, ignore_errors=True)


def _git(root: Path, args: Sequence[str]) -> str | None:
    try:
        proc = subprocess.run(
            ["git", "-C", str(root), *args],
            capture_output=True, text=True, timeout=60,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if proc.returncode != 0:
        return None
    return proc.stdout


def _changed_from_git(root: Path) -> tuple[dict[str, str], list[tuple[str, str]]] | None:
    out = _git(root, ["status", "--porcelain=v1", "-z", "--untracked-files=all"])
    if out is None:
        return None
    changed: dict[str, str] = {}
    for entry in out.split("\0"):
        if len(entry) < 4:
            continue
        code, path = entry[:2], entry[3:]
        if " -> " in path:  # rename
            path = path.split(" -> ", 1)[1]
        if code == "!!":
            continue
        if code == "??":
            changed[path] = "added"
        elif "D" in code:
            changed[path] = "deleted"
        elif "R" in code:
            changed[path] = "renamed"
        else:
            changed[path] = "modified"

    diff = _git(root, ["diff", "-U0", "--no-color", "HEAD", "--no-ext-diff"])
    added: list[tuple[str, str]] = []
    if diff:
        cur = ""
        for line in diff.splitlines():
            if line.startswith("+++ b/"):
                cur = line[6:]
            elif line.startswith("+++ /dev/null"):
                cur = ""
            elif line.startswith("+") and cur and not line.startswith("+++"):
                added.append((cur, line[1:]))
    for path, status in changed.items():
        if status == "added":
            text = read_text(root / path)
            if text is not None:
                added.extend((path, ln) for ln in text.splitlines())
    return changed, added


def _changed_from_report(run_dir: Path, root: Path) -> tuple[dict[str, str], list[tuple[str, str]]] | None:
    report = load_report(run_dir)
    if not isinstance(report, dict):
        return None
    files = report.get("changed_files")
    if not isinstance(files, list):
        return None
    changed: dict[str, str] = {}
    added: list[tuple[str, str]] = []
    for item in files:
        if not isinstance(item, str) or not item:
            continue
        path = _normalize(item)
        changed[path] = "modified"
        text = read_text(root / path)
        if text is not None:
            added.extend((path, ln) for ln in text.splitlines())
    return changed, added


def prepare_candidate(run_dir: Path, repo_root: Path) -> Candidate:
    worktree = run_dir / "worktree"
    if worktree.is_dir():
        got = _changed_from_git(worktree)
        note = "worktree"
        if got is None:
            got = _changed_from_report(run_dir, worktree)
            note = "worktree (changed_files from eval_report.json; no git metadata)"
        if got is None:
            got = ({}, [])
            note = "worktree (no git metadata and no eval_report.json: diff unknown)"
        changed, added = got
        return Candidate(worktree, changed, added, True, note)

    patch_path = run_dir / "patch.diff"
    if not patch_path.is_file():
        alt = sorted(run_dir.glob("*.patch")) + sorted(run_dir.glob("*.diff"))
        if alt:
            patch_path = alt[0]
    if not patch_path.is_file():
        return Candidate(
            None, {}, [], False,
            "no worktree/ or patch.diff in run dir",
            env_error=None,
        )

    text = read_text(patch_path)
    if text is None:
        return Candidate(None, {}, [], False,
                         f"{patch_path.name} is missing or unreadable")
    try:
        parsed = parse_unified_diff(text)
    except PatchError as exc:
        return Candidate(None, {}, [], False, f"parse: {exc}")
    if not parsed:
        return Candidate(None, {}, [], False, "parse: diff has no file sections")

    tmp = Path(tempfile.mkdtemp(prefix="ratchet-grade-"))
    changed: dict[str, str] = {}
    added: list[tuple[str, str]] = []
    try:
        for fp in parsed:
            src = repo_root / (fp.old_path or fp.path)
            base_text = "" if fp.is_new else read_text(src) or ""
            base = base_text.splitlines()
            try:
                new_lines = apply_hunks(base, fp.hunks, fp.path)
            except PatchError as exc:
                return Candidate(None, {}, [], False, f"apply: {exc}")
            dest = tmp / fp.path
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.write_text("\n".join(new_lines) + ("\n" if new_lines else ""),
                            encoding="utf-8")
            changed[fp.path] = ("added" if fp.is_new else
                                "deleted" if fp.is_delete else
                                "renamed" if fp.old_path and fp.old_path != fp.path
                                else "modified")
            added.extend((fp.path, ln) for ln in fp.added)
    except OSError as exc:
        shutil.rmtree(tmp, ignore_errors=True)
        return Candidate(None, {}, [], False, f"write temp tree: {exc}")

    return Candidate(tmp, changed, added, True, "patch.diff", temp_dir=tmp)


# --------------------------------------------------------------------------- #
# Reporting artifact
# --------------------------------------------------------------------------- #

def load_report(run_dir: Path) -> Any:
    for name in ("eval_report.json", "report/eval_report.json",
                 "reports/eval_report.json"):
        path = run_dir / name
        if path.is_file():
            text = read_text(path)
            if text is None:
                return None
            try:
                return json.loads(text)
            except json.JSONDecodeError:
                return None
    return None


def _report_metrics(report: Any, case_id: str, changed: dict[str, str],
                    verify_commands: Sequence[str],
                    verification: float) -> tuple[float, list[str]]:
    if report is None:
        return 0.0, [FAIL_REPORT]
    if not isinstance(report, dict):
        return 0.0, [FAIL_REPORT]
    failures: list[str] = []
    parts = 0.0

    required_keys = ("case_id", "changed_files", "commands", "tests_passed")
    if all(k in report for k in required_keys):
        parts += 0.4
    else:
        failures.append(FAIL_REPORT)

    if report.get("case_id") == case_id:
        parts += 0.2
    else:
        failures.append(FAIL_REPORT_INCONSISTENT)

    declared = report.get("changed_files")
    if isinstance(declared, list) and all(isinstance(x, str) for x in declared):
        if {(_normalize(x)) for x in declared} == set(changed):
            parts += 0.2
        else:
            failures.append(FAIL_REPORT_INCONSISTENT)
    else:
        failures.append(FAIL_REPORT_INCONSISTENT)

    cmds = report.get("commands")
    tests_passed = report.get("tests_passed")
    if isinstance(cmds, list) and isinstance(tests_passed, bool):
        if set(cmds) <= set(verify_commands) and tests_passed == (verification >= 1.0):
            parts += 0.2
        else:
            failures.append(FAIL_REPORT_INCONSISTENT)
    else:
        failures.append(FAIL_REPORT_INCONSISTENT)

    return min(1.0, parts), failures


# --------------------------------------------------------------------------- #
# Metric computation
# --------------------------------------------------------------------------- #

def _iter_text_files(root: Path) -> Iterable[tuple[str, str]]:
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = sorted(d for d in dirnames if d not in SKIP_DIRS)
        for name in sorted(filenames):
            path = Path(dirpath) / name
            rel = path.relative_to(root).as_posix()
            text = read_text(path)
            if text is not None:
                yield rel, text


def _scope(case: dict[str, Any], changed: dict[str, str]) -> tuple[float, list[str]]:
    allowed = list(case.get("allowed_paths") or [])
    forbidden = list(case.get("forbidden_paths") or [])
    if not changed:
        return 1.0, []
    violations = sorted(p for p in changed if matches_any(p, forbidden))
    if violations:
        return 0.0, [FAIL_SCOPE]
    if not allowed:
        return 0.0, [FAIL_SCOPE]
    inside = [p for p in changed if matches_any(p, allowed)]
    precision = len(inside) / len(changed)
    if precision < 1.0:
        return round(precision, 6), [FAIL_SCOPE]
    return 1.0, []


def _behavior(case: dict[str, Any], cand: Candidate) -> tuple[float, list[str]]:
    required = [p for p in (case.get("required_patterns") or []) if p]
    forbidden = [p for p in (case.get("forbidden_patterns") or []) if p]
    expected = [p for p in (case.get("expected_files") or []) if p]
    failures: list[str] = []

    if cand.root is None:
        return 0.0, [FAIL_BEHAVIOR]

    haystacks: list[str] = []
    if cand.changed:
        for path in cand.changed:
            if cand.changed[path] == "deleted":
                continue
            text = read_text(cand.root / path)
            if text is not None:
                haystacks.append(text)
    else:
        haystacks = [text for _, text in _iter_text_files(cand.root)]
    corpus = "\n".join(haystacks)

    hit_forbidden = [p for p in forbidden
                     if any(p in line for _, line in cand.added_lines)]
    if not cand.added_lines and forbidden:
        hit_forbidden = [p for p in forbidden if p in corpus]
    if hit_forbidden:
        failures.append(FAIL_BEHAVIOR)

    missing_expected = [p for p in expected if not (cand.root / p).is_file()]
    if missing_expected:
        failures.append(FAIL_BEHAVIOR)

    found = [p for p in required if p in corpus]
    coverage = 1.0 if not required else len(found) / len(required)
    if required and coverage < 1.0:
        failures.append(FAIL_BEHAVIOR)

    score = coverage
    if hit_forbidden or missing_expected:
        score = 0.0
    return round(score, 6), failures


def _verification(case: dict[str, Any], cand: Candidate, repo_root: Path,
                  timeout: float) -> tuple[float, list[str], list[dict[str, Any]]]:
    commands = [c for c in (case.get("verify_commands") or []) if c]
    if not commands:
        return 1.0, [], []
    if cand.root is None:
        return 0.0, [FAIL_ENV], []
    cwd = cand.root if cand.root.is_dir() else repo_root
    results: list[dict[str, Any]] = []
    failures: list[str] = []
    env_failure = False
    for cmd in commands:
        try:
            proc = subprocess.run(
                cmd, shell=True, cwd=str(cwd), capture_output=True,
                text=True, timeout=timeout,
            )
            code = proc.returncode
            err = (proc.stderr or "")[-2000:]
            out = (proc.stdout or "")[-2000:]
            if code == 127 or "command not found" in err or "No such file or directory" in err or "not recognized as an internal" in out:
                env_failure = True
                results.append({"command": cmd, "exit": code, "env_error": True})
                continue
            results.append({"command": cmd, "exit": code})
            if code != 0:
                failures.append(FAIL_TEST)
        except subprocess.TimeoutExpired:
            results.append({"command": cmd, "exit": None, "timeout": True})
            failures.append(FAIL_TEST)
    if env_failure:
        failures.append(FAIL_ENV)
        return 0.0, failures, results
    return (1.0 if not failures else 0.0), failures, results


# --------------------------------------------------------------------------- #
# Public entry point
# --------------------------------------------------------------------------- #

def grade_case(case: dict[str, Any], run_dir: str | os.PathLike[str],
               repo_root: str | os.PathLike[str] | None = None,
               timeout: float = DEFAULT_TIMEOUT_S,
               truncated: bool | None = None) -> dict[str, Any]:
    """Grade one case row against a run directory.  Never raises."""
    run_dir = Path(run_dir)
    if repo_root is None:
        repo_root = Path.cwd()
    repo_root = Path(repo_root)
    case_id = str(case.get("id") or "<unknown>")

    if truncated is None:
        truncated = _detect_truncated(run_dir)
    if truncated is None:
        truncated = False

    cand = Candidate(None, {}, [], False, "candidate not prepared")
    cand = prepare_candidate(run_dir, repo_root)
    scope, scope_fail = _scope(case, cand.changed)
    behavior, behavior_fail = _behavior(case, cand)
    verification, verify_fail, verify_detail = _verification(
        case, cand, repo_root, timeout)
    report = load_report(run_dir)
    reporting, report_fail = _report_metrics(
        report, case_id, cand.changed,
        [c for c in (case.get("verify_commands") or []) if c],
        verification)

    failures: list[str] = []
    if not cand.patch_ok:
        failures.append(FAIL_PATCH)
    failures.extend(scope_fail)
    failures.extend(behavior_fail)
    failures.extend(verify_fail)
    failures.extend(report_fail)
    if truncated:
        failures.append(FAIL_TRUNCATED)

    score = sum(WEIGHTS[k] * v for k, v in (
        ("behavior", behavior),
        ("scope_precision", scope),
        ("verification", verification),
        ("reporting", reporting),
    ))
    if not cand.patch_ok:
        score = 0.0
    if truncated:
        # A truncated run cannot earn behavior credit; the other metrics still
        # describe what was submitted.
        score = min(score, 1.0 - WEIGHTS["behavior"])

    details = {
        "candidate": cand.patch_note,
        "changed_files": cand.changed,
        "patch_ok": cand.patch_ok,
        "verify": verify_detail,
        "report_present": report is not None,
        "truncated": bool(truncated),
    }
    if cand.env_error:
        details["env_error"] = cand.env_error

    grade = {
        "case_id": case_id,
        "metrics": {
            "scope_precision": round(scope, 6),
            "behavior": round(behavior, 6),
            "verification": round(verification, 6),
            "reporting": round(reporting, 6),
        },
        "score": round(score, 6),
        "status": "truncated" if truncated else "ok",
        "failures": _dedupe(failures),
        "details": details,
    }
    cand.cleanup()
    return grade


def _dedupe(items: Iterable[str]) -> list[str]:
    seen: dict[str, None] = {}
    for item in items:
        seen.setdefault(item, None)
    return list(seen)


def _detect_truncated(run_dir: Path) -> bool | None:
    status = run_dir / "status.json"
    if status.is_file():
        text = read_text(status)
        if text is not None:
            try:
                data = json.loads(text)
            except json.JSONDecodeError:
                data = None
            if isinstance(data, dict) and isinstance(data.get("status"), str):
                return data["status"] == "truncated"
    if (run_dir / "truncated").exists():
        return True
    return None


# --------------------------------------------------------------------------- #
# CLI
# --------------------------------------------------------------------------- #

def load_cases(path: str | os.PathLike[str]) -> list[dict[str, Any]]:
    cases: list[dict[str, Any]] = []
    with open(path, "r", encoding="utf-8") as handle:
        for lineno, line in enumerate(handle, 1):
            line = line.strip()
            if not line:
                continue
            try:
                row = json.loads(line)
            except json.JSONDecodeError as exc:
                raise SystemExit(f"{path}:{lineno}: invalid JSON: {exc}")
            if not isinstance(row, dict):
                raise SystemExit(f"{path}:{lineno}: case row is not an object")
            cases.append(row)
    return cases


def main(argv: Sequence[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--cases", help="cases.jsonl path")
    ap.add_argument("--case-id", help="select this case id from --cases")
    ap.add_argument("--case-json", help="inline case row JSON")
    ap.add_argument("--case-file", help="file holding one case row JSON")
    ap.add_argument("--run-dir", required=True, help="dir with worktree/ or patch.diff")
    ap.add_argument("--repo-root", default=None)
    ap.add_argument("--timeout", type=float, default=DEFAULT_TIMEOUT_S)
    ap.add_argument("--truncated", choices=["auto", "yes", "no"], default="auto")
    ap.add_argument("--out", default=None, help="write grade JSON here (default <run-dir>/grade.json)")
    ap.add_argument("--no-write", action="store_true")
    args = ap.parse_args(argv)

    if args.case_json:
        case = json.loads(args.case_json)
    elif args.case_file:
        with open(args.case_file, "r", encoding="utf-8") as handle:
            case = json.load(handle)
    elif args.cases:
        cases = load_cases(args.cases)
        if args.case_id:
            matches = [c for c in cases if str(c.get("id")) == args.case_id]
            if not matches:
                raise SystemExit(f"case id {args.case_id!r} not in {args.cases}")
            case = matches[0]
        elif len(cases) == 1:
            case = cases[0]
        else:
            raise SystemExit("--case-id is required with a multi-case file")
    else:
        raise SystemExit("one of --case-json/--case-file/--cases is required")

    repo_root = Path(args.repo_root) if args.repo_root else Path.cwd()
    truncated = {"auto": None, "yes": True, "no": False}[args.truncated]
    grade = grade_case(case, args.run_dir, repo_root, args.timeout, truncated)

    payload = json.dumps(grade, indent=2, sort_keys=False)
    if not args.no_write:
        out = Path(args.out) if args.out else Path(args.run_dir) / "grade.json"
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(payload + "\n", encoding="utf-8")
    print(payload)
    return 0


if __name__ == "__main__":
    sys.exit(main())