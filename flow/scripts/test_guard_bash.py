#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Тесты guard-bash.py: таблица (команда, cwd) -> блок/пропуск.
Запуск: python3 flow/scripts/test_guard_bash.py"""
import json
import pathlib
import subprocess
import sys

GUARD = pathlib.Path(__file__).with_name("guard-bash.py")
ROOT = str(pathlib.Path(__file__).resolve().parents[2])
SUB = ROOT + "/flow/knowledge"
OUTSIDE = "/Users/someone/Projects/Other"

BLOCK = [
    # git
    ("git push", ROOT),
    ("git push origin main", ROOT),
    ("git -C /some/path push", ROOT),
    ("git commit -m 'Добавлено x'", ROOT),
    ("git -C . commit -m 'x'", ROOT),
    ("git checkout feature", ROOT),
    ("git checkout -b feature", ROOT),
    ("git switch main", ROOT),
    # сборка мимо make
    ("xcodebuild -project Trash.xcodeproj -scheme Trash build", ROOT),
    ("xcodebuild test -scheme Trash -destination 'platform=macOS'", ROOT),
    ("xcodebuild clean -project Trash.xcodeproj", ROOT),
    ("xcodebuild build-for-testing -scheme Trash", ROOT),
    # запись в /tmp
    ("echo hi > /tmp/out.txt", ROOT),
    ("sort data | tee /tmp/log.txt", ROOT),
    ("cat x >> /private/tmp/dump.json", ROOT),
    # удаление вне проекта
    ("rm -rf ~/Library/Caches/com.example", ROOT),
    ("rm -rf $HOME/.Trash/x", ROOT),
    ("rm -rf \"${HOME}/Library/Logs\"", ROOT),
    ("rm /Users/someone/Documents/file.txt", ROOT),
    ("rm -rf /", ROOT),
    ("rm -rf /*", ROOT),
    ("sudo rm -rf /Library/Caches", ROOT),
    ("rm -rf ../Other", ROOT),
    ("rm -rf DerivedData", OUTSIDE),                          # относительный путь от чужого cwd
    ("rm -rf \"$DIR\"", ROOT),                                # не вычислить статически
    ("rm -rf .", ROOT),                                       # корень проекта целиком
    ("rm -rf *", ROOT),                                       # маска в корне проекта
    ("rm -rf .git", ROOT),
    ("rm -rf .git/hooks", ROOT),
    ("make build && rm -rf ~/Downloads/x", ROOT),
    ("ls; rm -r ~/Desktop/x", ROOT),
    ("find ~/Library/Caches -name '*.db' -delete", ROOT),
    ("find / -delete", ROOT),
    ("bash -c 'rm -rf ~/Library'", ROOT),
    ("FOO=1 rm -rf ~/x", ROOT),
    ("rm -- -weird ~/x", ROOT),
]
PASS = [
    ("git status", ROOT),
    ("git log --oneline", ROOT),
    ("git diff HEAD", ROOT),
    ("git show main:Makefile", ROOT),
    ("git checkout -- Trash/Views/ContentView.swift", ROOT),  # восстановление файла
    ("FLOW_ALLOW_COMMIT=1 git commit -m 'Добавлено x'", ROOT),
    ("FLOW_ALLOW_CHECKOUT=1 git checkout main", ROOT),
    ("xcodebuild -list -project Trash.xcodeproj", ROOT),      # интроспекция разрешена
    ("xcodebuild -showBuildSettings -scheme Trash", ROOT),
    ("xcodebuild -version", ROOT),
    ("make build", ROOT),
    ("make test", SUB),
    ("echo tmp > /private/tmp/claude-501/scratch/x.txt", ROOT),
    ("echo 'в тексте упоминается /tmp/foo без редиректа'", ROOT),
    ("rm -rf DerivedData", ROOT),
    ("rm -rf tmp/cleanup-history", ROOT),
    ("rm -f Debug/old.ips", ROOT),
    ("rm -rf ../../tmp/topic", SUB),                          # внутри проекта из подкаталога
    ("rm -rf " + ROOT + "/tmp/x", OUTSIDE),                    # абсолютный путь внутрь проекта
    ("rm -rf /private/tmp/claude-501/scratch/dd", ROOT),      # scratchpad агента
    ("rm -rf /tmp/claude-501/x", ROOT),
    ("find tmp -name '*.tsv' -delete", ROOT),
    ("find . -name '*.orig'", ROOT),                          # без -delete — только поиск
    ("grep -rn 'rm -rf ~' flow/", ROOT),                      # rm в тексте аргумента
    ("echo rm -rf /", ROOT),
    ("git rm --cached Trash/x.swift", ROOT),
    ("FLOW_ALLOW_RM=1 rm -rf ~/Library/Caches/com.example.trash-test", ROOT),
    ("du -sk ~/Library/Caches", ROOT),
    ("ls -la ~/.Trash", ROOT),
]


def run(cmd, cwd):
    payload = json.dumps({"tool_name": "Bash", "tool_input": {"command": cmd}, "cwd": cwd})
    r = subprocess.run([sys.executable, str(GUARD)], input=payload, capture_output=True, text=True)
    return r.returncode, r.stderr.strip()


def main():
    failed = 0
    for cmd, cwd in BLOCK:
        code, err = run(cmd, cwd)
        if code != 2 or not err:
            print(f"FAIL (ожидался блок): {cmd!r} cwd={cwd} -> exit {code}")
            failed += 1
    for cmd, cwd in PASS:
        code, err = run(cmd, cwd)
        if code != 0:
            print(f"FAIL (ожидался пропуск): {cmd!r} cwd={cwd} -> exit {code}: {err}")
            failed += 1
    total = len(BLOCK) + len(PASS)
    print(f"{'FAILED' if failed else 'OK'}: test_guard_bash {total - failed}/{total}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
