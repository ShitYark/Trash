#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Линтер глоссария flow/rules/glossary.md (conventions.md → «Правила для глоссария»).

Проверки:
  1. Каждый файловый путь из колонки «Куда идти» существует (правило резолва — шапка
     глоссария: без каталога -> flow/knowledge/modules/, с каталогом -> flow/knowledge/,
     известные корни (flow/, .claude/, Trash/, ...) -> от корня репо).                      [ошибка]
  2. Правила строки — триггеры: не длиннее TRIG_MAX символов; без бэктиков, кавычек «»,
     пояснений в скобках, имён методов в camelCase; «Куда идти»: не длиннее DEST_MAX символов,
     первый сегмент до «;» — ровно один документ или каталог, без названий разделов в «» и §;
     нигде нет **жирного**; строка — единственная, что ведёт в свой документ.                [ошибка]
     В режиме --changed — только для новых и изменённых строк относительно HEAD.
  3. Точный дубль триггер-токена между строками таблицы.                                    [предупреждение]
  4. Размер файла: больше SIZE_WARN — предупреждение; больше SIZE_MAX — ошибка.              [ошибка]

Запуск:
  python3 flow/scripts/check-glossary.py             # полный прогон
  python3 flow/scripts/check-glossary.py --changed   # только если глоссарий менялся (Stop-hook); тихо, если чисто

Exit: 0 — чисто, 1 — есть находки; в --changed при ОШИБКАХ — 2 (Stop-хук блокирует завершение,
агент видит причину и чинит сам).

Тесты: python3 flow/scripts/test_check_glossary.py
"""
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
GLOSSARY = os.path.join(ROOT, "flow", "rules", "glossary.md")
GLOSSARY_REL = "flow/rules/glossary.md"
SIZE_WARN = 40_000
SIZE_MAX = 60_000   # ~25 тыс. токенов — один Read
TRIG_MAX = 400
DEST_MAX = 300
ROOT_PREFIXES = ("flow/", ".claude/", "Trash/", "TrashTests/", "Trash.xcodeproj/")
EXTS = (".md", ".swift", ".py", ".sh", ".json")
METHOD = re.compile(r"\b[a-z]+[A-Z][A-Za-z0-9]*\b")
NOT_METHODS = {"iOS", "iPad", "iPadOS", "iPhone", "macOS", "watchOS", "tvOS", "visionOS", "xcodebuild"}


def glossary_changed() -> bool:
    out = subprocess.check_output(["git", "-C", ROOT, "status", "--porcelain", "--untracked-files=all"], text=True)
    return any(ln[3:].strip().endswith(GLOSSARY_REL) for ln in out.splitlines())


def base_text():
    """Глоссарий в HEAD — от него считаются изменённые строки; файла в HEAD нет — пусто."""
    try:
        return subprocess.check_output(["git", "-C", ROOT, "show", f"HEAD:{GLOSSARY_REL}"],
                                       text=True, stderr=subprocess.DEVNULL)
    except (subprocess.CalledProcessError, OSError):
        return ""


def resolve(token: str):
    """Путь из ячейки -> абсолютный путь по правилу шапки глоссария (или None: не путь)."""
    if not token.endswith(EXTS) or " " in token:
        return None
    if token.startswith(ROOT_PREFIXES):
        return os.path.join(ROOT, token)
    if token.endswith(".md"):
        sub = token if "/" in token else "modules/" + token
        return os.path.join(ROOT, "flow", "knowledge", sub)
    return None


def parse_rows(text: str):
    rows = []
    for n, line in enumerate(text.splitlines(), 1):
        if not line.startswith("|") or line.startswith("|---"):
            continue
        cells = [c.strip() for c in line.strip("|").split("|")]
        if len(cells) != 2 or cells[0] == "Слова-триггеры":
            continue
        rows.append((n, cells[0], cells[1]))
    return rows


def target(dest: str):
    """Основная цель строки: документ из первого сегмента «Куда идти», у расслоённого — с под-файлом."""
    first = dest.split(";")[0]
    docs = [t for t in re.findall(r"`([^`]+)`", first) if t.endswith((".md", "/"))]
    if len(docs) != 1:
        return None
    doc = docs[0] if "/" in docs[0] else "modules/" + docs[0]
    sub = re.search(r"под-файл\w*\s+([\w-]+)", first)
    return f"{doc[:-3]}/{sub.group(1)}.md" if sub and doc.endswith(".md") else doc


def row_problems(trig: str, dest: str):
    """Нарушения правил строки: что в триггерах и в «Куда идти» быть не должно."""
    p = []
    if len(trig) > TRIG_MAX:
        p.append(f"триггеры длиннее {TRIG_MAX} символов ({len(trig)}) — оставь имена, описания вынеси в док")
    if "`" in trig:
        p.append("бэктики в триггерах — колонка без разметки")
    if "«" in trig or "»" in trig:
        p.append("кавычки «» в триггерах — колонка без разметки")
    if re.search(r"\s\(", trig):
        p.append("пояснение в скобках в триггерах — пояснения в док")
    methods = sorted({m for m in METHOD.findall(trig) if m not in NOT_METHODS})
    if methods:
        p.append(f"имена методов в триггерах ({', '.join(methods[:3])}) — им место в «Кодовых якорях» дока")
    if len(dest) > DEST_MAX:
        p.append(f"«Куда идти» длиннее {DEST_MAX} символов ({len(dest)}) — путь и короткая пометка «когда»")
    docs = [t for t in re.findall(r"`([^`]+)`", dest.split(";")[0]) if t.endswith((".md", "/"))]
    if len(docs) != 1:
        p.append(f"первый сегмент «Куда идти» — документов {len(docs)}, основной должен быть один")
    if "«" in dest or "»" in dest or "§" in dest:
        p.append("название раздела в «Куда идти» — раздел агент находит по оглавлению дока")
    if "**" in trig or "**" in dest:
        p.append("жирное выделение в таблице")
    return p


def check(text: str, base=None):
    """-> (ошибки, предупреждения). base — текст глоссария в HEAD для режима --changed:
    правила строки проверяются только у строк, которых в base нет; None — по всем строкам."""
    rows = parse_rows(text)
    errors, warns = [], []

    for n, _trig, dest in rows:
        for token in re.findall(r"`([^`]+)`", dest):
            full = resolve(token)
            if full and not os.path.isfile(full):
                errors.append(f"строка {n}: путь не существует: {token}")

    unchanged = {f"{t}|{d}" for _n, t, d in parse_rows(base)} if base is not None else set()
    first_row = {}
    for n, _trig, dest in rows:
        first_row.setdefault(target(dest), n)
    for n, trig, dest in rows:
        if f"{trig}|{dest}" in unchanged:
            continue
        errors += [f"строка {n}: {msg}" for msg in row_problems(trig, dest)]
        same = first_row.get(target(dest))
        if target(dest) and same != n:
            errors.append(f"строка {n}: ведёт в тот же документ, что строка {same} — строка = один документ, слей их")

    seen = {}
    for n, trig, _dest in rows:
        for token in re.split(r"[;,]", trig):
            t = re.sub(r"\*\*|`", "", token).strip().lower()
            if len(t) < 4:
                continue
            if t in seen and seen[t] != n:
                warns.append(f"дубль триггера «{t}»: строки {seen[t]} и {n}")
            else:
                seen.setdefault(t, n)

    size = len(text.encode("utf-8"))
    if size > SIZE_MAX:
        errors.append(f"размер глоссария {size} байт > {SIZE_MAX}: не помещается в один Read — сократи строки")
    elif size > SIZE_WARN:
        warns.append(f"размер глоссария {size} байт > {SIZE_WARN} (цель ≤30 КБ) — пора ревизию")
    return errors, warns


def main() -> int:
    changed_mode = "--changed" in sys.argv
    if changed_mode and not glossary_changed():
        return 0
    errors, warns = check(open(GLOSSARY, encoding="utf-8").read(), base_text() if changed_mode else None)
    if not errors and not warns:
        if not changed_mode:
            print("check-glossary: чисто")
        return 0
    out = sys.stderr if (changed_mode and errors) else sys.stdout
    print("📖 check-glossary: находки в flow/rules/glossary.md", file=out)
    for e in errors:
        print(f"  ОШИБКА: {e}", file=out)
    for w in warns:
        print(f"  предупреждение: {w}", file=out)
    if changed_mode and errors:
        print("  Исправь перед завершением. Строка: имена терминов → путь основного документа; описания, "
              "методы и разделы — в док модуля. Правила — flow/meta/conventions.md → «Правила для глоссария».",
              file=out)
        return 2
    return 1


if __name__ == "__main__":
    sys.exit(main())
