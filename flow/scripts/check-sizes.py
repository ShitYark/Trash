#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Сторож размеров файлов flow: сигналит о превышении порогов читаемости.

Пороги (байты; курс кириллического markdown ~2.42 байта/токен):
  flow/history/<module>-history.md          44 000  — порог архивации
  flow/rules/glossary.md                    40 000  — цель ≤30 КБ, сигнал с 40 КБ
  flow/knowledge/modules/<module>/<file>.md 44 000  — под-файл расслоённого модуля
  flow/knowledge/modules/<module>.md        44 000  — хаб, если модуль расслоён
  flow/knowledge/**/*.md                   122 880  — не влезает даже в два Read

Запуск:
  python3 flow/scripts/check-sizes.py             # полный скан
  python3 flow/scripts/check-sizes.py --changed   # только изменённые в git файлы (Stop-hook); тихо, если чисто

Exit: 0 — чисто, 1 — есть превышения (предупреждения, не блокировка).
"""
import glob
import os
import pathlib
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
ROOT_PATH = pathlib.Path(ROOT)


def limit_for(rel: str):
    if rel == "flow/rules/glossary.md":
        return 40_000, "цель ≤30 КБ — ревизия глоссария (conventions → «Правила для глоссария»)"
    if rel.startswith("flow/history/") and rel.endswith("-history.md") and rel.count("/") == 2:
        return 44_000, "порог архивации — нужен `/dev:history <module>`"
    if rel.startswith("flow/knowledge/modules/") and rel.endswith(".md"):
        if rel.count("/") == 4:  # под-файл расслоённого модуля: modules/<module>/<file>.md
            return 44_000, "под-файл перерос — раздели по интенту, обнови индекс хаба (conventions → «Расслоённый документ модуля»)"
        if rel.count("/") == 3 and (ROOT_PATH / rel).with_suffix("").is_dir():
            return 44_000, "хаб расслоённого модуля перерос — контент в хаб не дописывается, вынеси в под-файлы"
    if rel.startswith("flow/knowledge/") and rel.endswith(".md"):
        return 122_880, "не читается даже двумя Read — расслой через `/dev:meta`"
    return None, None


def is_reference_catalog(rel: str) -> bool:
    try:
        with open(ROOT_PATH / rel, encoding="utf-8") as f:
            return "reference-catalog" in f.read(500)
    except OSError:
        return False


def changed_files():
    out = subprocess.check_output(["git", "-C", ROOT, "status", "--porcelain", "--untracked-files=all"], text=True)
    res = []
    for ln in out.splitlines():
        p = ln[3:].strip().strip('"')
        if " -> " in p:
            p = p.split(" -> ")[-1]
        if os.path.isfile(os.path.join(ROOT, p)):
            res.append(p)
    return res


def all_files():
    pats = ["flow/rules/glossary.md", "flow/history/*-history.md", "flow/knowledge/**/*.md"]
    res = []
    for pat in pats:
        res += [os.path.relpath(f, ROOT) for f in glob.glob(os.path.join(ROOT, pat), recursive=True)]
    return sorted(set(res))


def main() -> int:
    changed = "--changed" in sys.argv
    files = changed_files() if changed else all_files()
    findings = []
    for rel in files:
        limit, hint = limit_for(rel)
        if not limit or is_reference_catalog(rel):
            continue
        size = os.path.getsize(os.path.join(ROOT, rel))
        if size > limit:
            findings.append(f"  {rel}: {size:,} байт > {limit:,} — {hint}".replace(",", " "))
    if not findings:
        if not changed:
            print("check-sizes: чисто")
        return 0
    print("📏 check-sizes: файлы за порогом читаемости")
    for f in findings:
        print(f)
    return 1


if __name__ == "__main__":
    sys.exit(main())
