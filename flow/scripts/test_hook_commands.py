#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Тесты команд хуков из .claude/settings.json: каждая находит свой скрипт из любого cwd.

Хук стартует в cwd агента, а тот уезжает за каждым `cd`. Скрипт по пути от cwd из подкаталога
не находится, python3 выходит с кодом 2, а для PreToolUse это «заблокировать»: Bash мёртв
до конца хода. Тест имитирует запуск харнессом (shell-команда, CLAUDE_PROJECT_DIR в окружении,
JSON в stdin) из подкаталога репо и из каталога вне git. Отдельно — команда хука с
CLAUDE_PROJECT_DIR, где скрипта нет: хук обязан пропустить, а не заблокировать.
Запуск: python3 flow/scripts/test_hook_commands.py"""
import json
import os
import pathlib
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
SETTINGS = ROOT / ".claude" / "settings.json"
# guard по-прежнему блокирует нарушения и пропускает обычные команды
GUARD_CASES = [("xcodebuild -scheme Trash build", 2), ("git push", 2), ("rm -rf ~/Library/Caches", 2), ("ls", 0)]


def hook_commands():
    hooks = json.loads(SETTINGS.read_text(encoding="utf-8"))["hooks"]
    return [(event, h["command"]) for event, groups in hooks.items() for g in groups for h in g["hooks"]]


def run(command, cwd, payload, project_dir):
    env = dict(os.environ, CLAUDE_PROJECT_DIR=str(project_dir))
    r = subprocess.run(["/bin/sh", "-c", command], cwd=cwd, env=env,
                       input=json.dumps(payload), capture_output=True, text=True)
    return r.returncode, r.stderr.strip()


def main():
    failed = total = 0
    with tempfile.TemporaryDirectory() as outside:
        for cwd in (ROOT / "flow" / "knowledge", pathlib.Path(outside)):
            for event, command in hook_commands():
                cases = GUARD_CASES if "guard-bash.py" in command else [(None, None)]
                for bash, want in cases:
                    payload = {"hook_event_name": event, "cwd": str(cwd)}
                    if bash:
                        payload.update(tool_name="Bash", tool_input={"command": bash})
                    code, err = run(command, cwd, payload, ROOT)
                    total += 1
                    lost = "can't open file" in err or "Traceback" in err
                    if lost or (want is not None and code != want):
                        print(f"FAIL: {command!r} cwd={cwd} bash={bash!r} -> exit {code}: {err[:200]}")
                        failed += 1
        # Скрипта нет по CLAUDE_PROJECT_DIR — хук пропускает, Bash не блокируется.
        for event, command in hook_commands():
            payload = {"hook_event_name": event, "cwd": outside,
                       "tool_name": "Bash", "tool_input": {"command": "ls"}}
            code, err = run(command, outside, payload, outside)
            total += 1
            if code != 0:
                print(f"FAIL (нет скрипта — ожидался пропуск): {command!r} -> exit {code}: {err[:200]}")
                failed += 1
    print(f"{'FAILED' if failed else 'OK'}: test_hook_commands {total - failed}/{total}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
