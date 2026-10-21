#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Тесты check-glossary.py на синтетических таблицах и на реальном глоссарии.
Запуск: python3 flow/scripts/test_check_glossary.py"""
import importlib.util
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("check_glossary", pathlib.Path(__file__).with_name("check-glossary.py"))
glossary = importlib.util.module_from_spec(spec)
spec.loader.exec_module(glossary)

HEADER = "| Слова-триггеры | Куда идти |\n|---|---|\n"
failed = 0
total = 0


def errors_of(rows, base=None):
    errors, _warns = glossary.check(HEADER + rows, base)
    return errors


def expect(condition, message):
    global failed, total
    total += 1
    if not condition:
        failed += 1
        print(f"FAIL: {message}")


good = "| Очистка, SafetyGuard | `cleanup.md`; `scanning.md` — откуда корни |\n"
expect(errors_of(good) == [], f"чистая строка: {errors_of(good)}")

cases = [
    ("| Очистка, `SafetyGuard` | `cleanup.md` |\n", "бэктики"),
    ("| Очистка «быстрая» | `cleanup.md` |\n", "кавычки"),
    ("| Очистка (удаление) | `cleanup.md` |\n", "скобках"),
    ("| Очистка, canDelete | `cleanup.md` |\n", "методов"),
    ("| Очистка | `cleanup.md` `scanning.md` |\n", "документов 2"),
    ("| Очистка | `cleanup.md` — раздел «Контракт» |\n", "раздела"),
    ("| **Очистка** | `cleanup.md` |\n", "жирное"),
    ("| Очистка | `nope.md` |\n", "не существует"),
    ("| Очистка | `cleanup.md` |\n| Удаление | `cleanup.md` |\n", "тот же документ"),
    ("| " + "слово, " * 80 + " | `cleanup.md` |\n", "длиннее"),
]
for rows, needle in cases:
    errors = errors_of(rows)
    expect(any(needle in e for e in errors), f"ожидалась ошибка «{needle}», получено {errors}")

# --changed: старая строка с нарушением не блокирует, новая — блокирует.
old = "| Очистка, canDelete | `cleanup.md` |\n"
expect(errors_of(old, base=HEADER + old) == [], "неизменённая строка не проверяется в --changed")
expect(errors_of(old, base=HEADER) != [], "новая строка проверяется в --changed")

# Реальный глоссарий проекта чист.
real_errors, _ = glossary.check((ROOT / "flow" / "rules" / "glossary.md").read_text(encoding="utf-8"))
expect(real_errors == [], f"реальный глоссарий: {real_errors}")

print(f"{'FAILED' if failed else 'OK'}: test_check_glossary {total - failed}/{total}")
sys.exit(1 if failed else 0)
