#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Deterministic preflight smoke for the ratchet harness (airi-b6f7).

Runs two fake agents through the REAL ``runner.py`` -> ``grader.py`` pipeline
with no model calls, then asserts the grades are exactly 1.0 with no failures
and ``report_present`` true:

  * PORT-02  oracle fake agent  (inserts a real ``vaultStatus()`` wrapper)
  * PORT-06  null   fake agent  (makes no source change)

If either grade is not perfect, the harness (runner/grader/cases) is broken --
NOT the fake patch. This is the whole point of the fixture: a malformed fake
patch can never again be mistaken for a grader/runner bug.

Only the Python standard library is used.  No network, no model, fast.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
RATCHET_DIR = HERE
REPO_ROOT = HERE.parents[2]  # HERE=ratchet -> eval -> scripts -> AnimA

ORACLE = HERE / "fixtures" / "fake_oracle_port02.py"
NULL = HERE / "fixtures" / "fake_null_port06.py"

# (case_id, fake-agent path, variant)
CASES = [
    ("PORT-02", ORACLE, "oracle"),
    ("PORT-06", NULL, "null"),
]


def _run_one(case_id: str, agent: Path, variant: str) -> dict:
    out_dir = Path(tempfile.mkdtemp(prefix=f"ratchet-smoke-{case_id}-"))
    env = dict(os.environ)
    env["RATCHET_AGENT_CMD"] = f"{sys.executable} {agent.resolve()} {{prompt}}"
    env["RATCHET_CASE_TIMEOUT_S"] = "120"
    env["RATCHET_MAX_ATTEMPTS"] = "1"
    env["RATCHET_RETRY_BASE_S"] = "0"
    env["RATCHET_CONCURRENCY"] = "1"
    env["RATCHET_REPS"] = "1"
    proc = subprocess.run(
        [sys.executable, str(RATCHET_DIR / "runner.py"),
         "--variant", variant,
         "--out", str(out_dir),
         "--repo-root", str(REPO_ROOT),
         "--case-id", case_id],
        env=env, capture_output=True, text=True, timeout=300,
    )
    results_path = out_dir / "results.jsonl"
    row = None
    if results_path.is_file():
        lines = [ln for ln in results_path.read_text().splitlines() if ln.strip()]
        if lines:
            row = json.loads(lines[-1])
    return {"case_id": case_id, "variant": variant, "out_dir": out_dir,
            "runner_rc": proc.returncode, "runner_stdout": proc.stdout,
            "runner_stderr": proc.stderr, "row": row}


def main() -> int:
    failures: list[str] = []
    for case_id, agent, variant in CASES:
        if not agent.is_file():
            failures.append(f"{case_id}: missing fake agent {agent}")
            continue
        res = _run_one(case_id, agent, variant)
        row = res["row"]
        print(f"=== {case_id} ({variant}) ===")
        print(f"runner rc={res['runner_rc']}")
        if res["runner_stdout"].strip():
            print("stdout:", res["runner_stdout"].strip())
        if res["runner_stderr"].strip():
            print("stderr:", res["runner_stderr"].strip()[-500:])
        if row is None:
            failures.append(f"{case_id}: no results row (runner rc={res['runner_rc']})")
            print("RESULT: NO ROW\n")
            continue
        grade = row.get("grade") or {}
        score = grade.get("score")
        fails = grade.get("failures") or []
        report_present = (grade.get("details") or {}).get("report_present")
        status = grade.get("status")
        print(f"score={score} status={status} failures={fails} "
              f"report_present={report_present}")
        print(f"metrics={grade.get('metrics')}")
        ok = (score == 1.0 and not fails and report_present is True)
        print("RESULT:", "PASS" if ok else "FAIL")
        if not ok:
            failures.append(
                f"{case_id}: score={score} failures={fails} "
                f"report_present={report_present}")
        print()
    if failures:
        print("SMOKE FAILED:")
        for f in failures:
            print("  -", f)
        return 1
    print("SMOKE PASSED: PORT-02 oracle and PORT-06 null both score 1.0, "
          "no failures, report_present true.")
    return 0


if __name__ == "__main__":
    sys.exit(main())