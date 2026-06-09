#!/usr/bin/env python3
"""Self-test for the PreToolUse harness guard. Run: python3 scripts/guard_agent_test.py"""
import json
import subprocess
import sys

GUARD = "scripts/guard_agent.py"

CASES = [
    # (tool, field, value, expected_exit)
    ("Edit", "file_path", "bindings/pg_agent.swift", 2),
    ("Edit", "file_path", "pgAgent.xcodeproj/project.pbxproj", 2),
    ("Edit", "file_path", "src/ffi.rs", 0),
    ("Edit", "file_path", "PgAgentApp/PgAgentApp.swift", 0),
    ("Bash", "command", "r" + "m -rf src", 2),
    ("Bash", "command", "r" + "m -rf build .build", 0),
    ("Bash", "command", "r" + "m -rf build pgAgent.xcodeproj", 0),
    ("Bash", "command", "r" + "m -rf build && r" + "m -rf ~", 2),
    ("Bash", "command", "git push origin main --force", 2),
    ("Bash", "command", "git push origin main", 0),
    ("Bash", "command", "git reset --hard HEAD~1", 2),
    ("Bash", "command", 'grep "DROP TABLE" foo.sql', 0),
    ("Bash", "command", 'psql -c "DROP TABLE users"', 2),
    ("Bash", "command", "cargo build", 0),
    ("Bash", "command", "just mac-bindings", 0),
]


def run(tool, field, value):
    payload = json.dumps({"tool_name": tool, "tool_input": {field: value}})
    p = subprocess.run([sys.executable, GUARD], input=payload,
                       capture_output=True, text=True)
    return p.returncode


def main():
    failures = 0
    for tool, field, value, expected in CASES:
        got = run(tool, field, value)
        ok = got == expected
        failures += not ok
        print(f"{'✅' if ok else '❌'} {tool:5} {value[:48]:48} -> {got} (want {expected})")
    print(f"\n{'ALL PASS' if not failures else str(failures) + ' FAILED'}")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
