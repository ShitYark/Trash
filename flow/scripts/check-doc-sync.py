#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Stop hook: проверяет синхронность документации модулей с изменениями кода.

Запускается в конце сессии Claude Code. Если изменены файлы кода, которые попадают
под карту flow/meta/code-to-module-map.json, а документ модуля
flow/knowledge/modules/<module>.md не обновлён — выводит напоминание.

Изменённые файлы — незакоммиченные и неотслеживаемые (git status --porcelain):
новые файлы кода тоже считаются.

Правка не требует документации — пометка [skip-doc-check] в сообщении коммита
(читается сообщение HEAD-коммита).

Разрешение пути в модуль: побеждает САМОЕ ДЛИННОЕ совпадение префикса (в том
числе из non_modules, что даёт «файл вне модулей»). Подробности —
flow/meta/conventions.md → «Doc-sync hook».

Тесты: python3 flow/scripts/test_check_doc_sync.py
"""

import json
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
MAP_FILE = REPO_ROOT / "flow" / "meta" / "code-to-module-map.json"
DOCS_DIR = "knowledge/modules"


def run_git(args):
    try:
        result = subprocess.run(
            ["git"] + args,
            capture_output=True,
            text=True,
            check=True,
            cwd=str(REPO_ROOT),
        )
        return result.stdout
    except (subprocess.CalledProcessError, FileNotFoundError):
        return ""


def get_changed_files():
    files = []
    for line in run_git(["status", "--porcelain", "--untracked-files=all"]).splitlines():
        path = line[3:].strip()
        if " -> " in path:  # переименование
            path = path.split(" -> ")[-1]
        if path:
            files.append(path.strip('"'))
    return files


def doc_updated(module, changed_files):
    """Док модуля обновлён: сам файл или под-файл расслоённого модуля (хаб + <module>/)."""
    doc_path = f"flow/{DOCS_DIR}/{module}.md"
    sub_prefix = f"flow/{DOCS_DIR}/{module}/"
    return any(f == doc_path or f.startswith(sub_prefix) for f in changed_files)


def has_skip_marker():
    return "[skip-doc-check]" in run_git(["log", "-1", "--format=%B"])


def resolve_path_module(path, paths, non_modules):
    """Модуль файла по карте путей. Побеждает самое длинное совпадение префикса.

    non_modules участвует в том же сравнении: если самое длинное совпадение —
    оттуда, файл к модулю не относится, возвращается None.
    """
    best_prefix = ""
    best_module = None
    for prefix, module in paths.items():
        if prefix.startswith("_"):  # служебные ключи карты (_comment)
            continue
        if path.startswith(prefix) and len(prefix) > len(best_prefix):
            best_prefix, best_module = prefix, module
    for prefix in non_modules:
        if prefix.startswith("_"):
            continue
        if path.startswith(prefix) and len(prefix) > len(best_prefix):
            best_prefix, best_module = prefix, None
    return best_module


def find_affected_modules(changed_files, mapping):
    paths = mapping.get("paths", {})
    name_prefixes = mapping.get("name_prefixes", {})
    non_modules = mapping.get("non_modules", {})
    affected = set()
    for f in changed_files:
        module = resolve_path_module(f, paths, non_modules)
        if module:
            affected.add(module)
        # name_prefixes — независимая ось (файлы одного модуля, разбросанные
        # по разным директориям), приоритет длины к ней не применяется.
        filename = Path(f).name
        for name_prefix, module in name_prefixes.items():
            if not name_prefix.startswith("_") and filename.startswith(name_prefix):
                affected.add(module)
    return affected


def main():
    changed_files = get_changed_files()
    if not changed_files or has_skip_marker() or not MAP_FILE.exists():
        return 0

    try:
        with open(MAP_FILE, encoding="utf-8") as f:
            mapping = json.load(f)
    except (json.JSONDecodeError, OSError):
        return 0

    warnings = []
    for module in sorted(find_affected_modules(changed_files, mapping)):
        if not doc_updated(module, changed_files):
            warnings.append(f"Модуль '{module}' затронут — но flow/{DOCS_DIR}/{module}.md не обновлён")

    if not warnings:
        return 0

    print()
    print("📋 doc-sync-check: возможны несинхронные правки")
    for w in warnings:
        print(f"  - {w}")
    print()
    print("Если документация для этих модулей не нужна, добавь в commit message пометку [skip-doc-check].")
    print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
