#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Тесты check-doc-sync.py и согласованности карты code-to-module-map.json с документами модулей.
Запуск: python3 flow/scripts/test_check_doc_sync.py"""
import importlib.util
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("check_doc_sync", pathlib.Path(__file__).with_name("check-doc-sync.py"))
doc_sync = importlib.util.module_from_spec(spec)
spec.loader.exec_module(doc_sync)

MAPPING = json.loads((ROOT / "flow" / "meta" / "code-to-module-map.json").read_text(encoding="utf-8"))
KEY_FILES_RE = re.compile(r"^### Ключевые файлы\s*$(.*?)(?=^##|\Z)", re.M | re.S)

failed = 0
total = 0


def expect(condition, message):
    global failed, total
    total += 1
    if not condition:
        failed += 1
        print(f"FAIL: {message}")


def resolve(path):
    return doc_sync.resolve_path_module(path, MAPPING.get("paths", {}), MAPPING.get("non_modules", {}))


# 1. Реальная карта: файл -> модуль.
for path, module in [
    ("Trash/Views/ContentView.swift", "main-window"),
    ("Trash/Views/NewScreen/Row.swift", "main-window"),
    ("Trash/ViewModels/CleanupViewModel.swift", "main-window"),
    ("Trash/App/TrashApp.swift", "main-window"),
    ("Trash/Services/Cleaner.swift", "cleanup"),
    ("Trash/Services/SafetyGuard.swift", "cleanup"),
    ("Trash/Services/CleanupScanner.swift", "scanning"),
    ("Trash/Models/CleanupCategory.swift", "scanning"),
    ("Trash/Assets.xcassets/AppIcon.appiconset/Contents.json", None),
    ("Trash.xcodeproj/project.pbxproj", None),
    ("flow/rules/glossary.md", None),
]:
    expect(resolve(path) == module, f"{path} -> {resolve(path)!r}, ожидался {module!r}")

# 2. Приоритет самого длинного префикса и non_modules.
paths = {"A/": "wide", "A/B/": "narrow", "A/B/file.swift": "exact"}
non_modules = {"A/vendor/": "vendored"}
expect(doc_sync.resolve_path_module("A/x.swift", paths, non_modules) == "wide", "широкое правило")
expect(doc_sync.resolve_path_module("A/B/y.swift", paths, non_modules) == "narrow", "частное перебивает широкое")
expect(doc_sync.resolve_path_module("A/B/file.swift", paths, non_modules) == "exact", "точный путь файла")
expect(doc_sync.resolve_path_module("A/vendor/z.swift", paths, non_modules) is None, "non_modules даёт «вне модулей»")

# 3. Затронутые модули и обновлённый док.
changed = ["Trash/Services/Cleaner.swift", "flow/knowledge/modules/cleanup.md", "Trash/Views/ContentView.swift"]
affected = doc_sync.find_affected_modules(changed, MAPPING)
expect(affected == {"cleanup", "main-window"}, f"затронуты {affected}")
expect(doc_sync.doc_updated("cleanup", changed), "док cleanup обновлён")
expect(not doc_sync.doc_updated("main-window", changed), "док main-window не обновлён")
expect(doc_sync.doc_updated("x", ["flow/knowledge/modules/x/part.md"]), "под-файл расслоённого модуля")

# 4. Согласованность карты с репозиторием.
modules = {m for k, m in MAPPING.get("paths", {}).items() if not k.startswith("_")}
for module in sorted(modules):
    expect((ROOT / "flow" / "knowledge" / "modules" / f"{module}.md").is_file(), f"у модуля {module} нет документа")
for key in MAPPING.get("paths", {}):
    if not key.startswith("_"):
        expect((ROOT / key).exists(), f"путь карты не существует: {key}")

# 5. Каждый ключевой файл из документа модуля ведёт картой в этот модуль.
for doc in sorted((ROOT / "flow" / "knowledge" / "modules").glob("*.md")):
    section = KEY_FILES_RE.search(doc.read_text(encoding="utf-8"))
    expect(section is not None, f"{doc.name}: нет секции ### Ключевые файлы")
    if not section:
        continue
    for line in section.group(1).splitlines():
        match = re.match(r"^- /(\S+)", line.strip())
        if match:
            path = match.group(1)
            expect((ROOT / path).exists(), f"{doc.name}: ключевой файл не существует: {path}")
            owner = resolve(path)
            expect(owner == doc.stem, f"{doc.name}: {path} по карте ведёт в {owner!r}")

print(f"{'FAILED' if failed else 'OK'}: test_check_doc_sync {total - failed}/{total}")
sys.exit(1 if failed else 0)
