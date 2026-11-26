#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Deterministic NULL fake agent for ratchet case PORT-06 (no-change expected).

Makes NO source change, emits opencode-style JSONL events (step_start /
step_finish) on stdout, and writes a valid ``eval_report.json`` (empty
changed_files, the case's verify command, tests_passed true) at the scratch
root so the grader's reporting metric is satisfied.

Usage (invoked by runner.py):
    fake_null_port06.py "<prompt>"
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

CASE_ID = "PORT-06"
VERIFY_COMMANDS = [
    "rg -q \"kProtocolId = 'airi-channel/1'\" "
    "apps/flutter/lib/daemon_client/protocol.dart && "
    "! rg -q 'anima-channel/1' apps/flutter/lib/daemon_client/protocol.dart",
]


def _emit_step_start() -> None:
    print(json.dumps({"type": "step_start", "sessionID": "fake-null-port06",
                      "part": {"index": 0}}))


def _emit_step_finish() -> None:
    print(json.dumps({
        "type": "step_finish",
        "sessionID": "fake-null-port06",
        "part": {
            "reason": "stop",
            "cost": 0.0,
            "tokens": {"input": 0, "output": 0, "reasoning": 0,
                       "cache": {"read": 0, "write": 0}},
        },
    }))


def main(argv: list[str]) -> int:
    _ = argv  # prompt text is irrelevant for the deterministic null agent
    root = Path.cwd()

    _emit_step_start()

    # No source change: PORT-06 requires the protocol id to stay untouched.
    report = {
        "case_id": CASE_ID,
        "changed_files": [],
        "commands": VERIFY_COMMANDS,
        "tests_passed": True,
    }
    (root / "eval_report.json").write_text(
        json.dumps(report, indent=2) + "\n", encoding="utf-8")

    _emit_step_finish()
    print("null PORT-06: no source change")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))