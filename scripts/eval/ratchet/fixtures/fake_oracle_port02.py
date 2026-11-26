#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Deterministic ORACLE fake agent for ratchet case PORT-02 (change-expected).

Emits opencode-style JSONL events (step_start / step_finish) on stdout, makes a
harmless, unique, valid Dart change inside the EXISTING ``vaultStatus()``
wrapper in the scratch copy of
``apps/flutter/lib/daemon_client/daemon_client.dart`` (adds a
``// ratchet-oracle-vault`` marker comment inside its body -- no duplicate
declaration, so ``dart analyze`` stays clean), and writes a valid
``eval_report.json`` at the scratch root. The report's ``commands`` list is the
case's own ``verify_commands`` and ``tests_passed`` is true, so the grader's
reporting metric is satisfied.

The scratch base is the working tree, which already contains a
``vaultStatus()`` wrapper. The oracle anchors on the unique
``_callOk('vault.status')`` line inside that wrapper and inserts the marker
comment immediately before it, guaranteeing a non-empty diff without ever
redeclaring ``vaultStatus``.

Usage (invoked by runner.py):
    fake_oracle_port02.py "<prompt>"
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

TARGET = "apps/flutter/lib/daemon_client/daemon_client.dart"
CASE_ID = "PORT-02"
VERIFY_COMMANDS = [
    "sh -c 'cd apps/flutter && dart analyze lib/daemon_client/daemon_client.dart'",
    "rg -q 'vaultStatus' apps/flutter/lib/daemon_client/daemon_client.dart",
]

# The vault.status RPC call line is unique to the vaultStatus() wrapper body.
ANCHOR = "    final reply = await _callOk('vault.status');\n"
MARKER = "    // ratchet-oracle-vault\n"


def _emit_step_start() -> None:
    print(json.dumps({"type": "step_start", "sessionID": "fake-oracle-port02",
                      "part": {"index": 0}}))


def _emit_step_finish() -> None:
    print(json.dumps({
        "type": "step_finish",
        "sessionID": "fake-oracle-port02",
        "part": {
            "reason": "stop",
            "cost": 0.0,
            "tokens": {"input": 0, "output": 0, "reasoning": 0,
                       "cache": {"read": 0, "write": 0}},
        },
    }))


def main(argv: list[str]) -> int:
    _ = argv  # prompt text is irrelevant for the deterministic oracle
    root = Path.cwd()

    _emit_step_start()

    target = root / TARGET
    if not target.is_file():
        raise SystemExit(f"oracle: target not found: {target}")
    text = target.read_text(encoding="utf-8")
    if "ratchet-oracle-vault" not in text:
        if ANCHOR not in text:
            raise SystemExit("oracle: vault.status anchor not found")
        target.write_text(text.replace(ANCHOR, MARKER + ANCHOR, 1),
                          encoding="utf-8")

    report = {
        "case_id": CASE_ID,
        "changed_files": [TARGET],
        "commands": VERIFY_COMMANDS,
        "tests_passed": True,
    }
    (root / "eval_report.json").write_text(
        json.dumps(report, indent=2) + "\n", encoding="utf-8")

    _emit_step_finish()
    print("oracle PORT-02: added vaultStatus marker comment")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))