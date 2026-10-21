#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Линтер относительных markdown-ссылок.

Ловит ссылки, ведущие в НЕсуществующий файл — битая глубина `../`, опечатки путей,
переезды файлов. Игнорирует внешние URL, якоря `#...`, суффиксы `:123` / `:123-456`
(номер строки), `%20`, `<плейсхолдеры>` в путях, ссылки на gitignored `tmp/`.

Использование:
  python3 flow/scripts/check-links.py              # дефолт: flow/ + .claude/ + AGENTS.md/CLAUDE.md
  python3 flow/scripts/check-links.py flow/history # скан указанных папок
  python3 flow/scripts/check-links.py --changed    # только изменённые в git .md (Stop-hook); тихо, если чисто

Exit 0 — чисто; 1 — есть битые ссылки.
"""
import os
import re
import subprocess
import sys
import urllib.parse

LINK_RE = re.compile(r"\[[^\]]*\]\(([^)]+)\)")
# суффикс номера строки в конце пути: :123 или :123-456
LINE_SUFFIX = re.compile(r":\d+(?:[-‐‑–]\d+)?$")
# Исключаемые зоны: tmp (эфемерное), plans/history (рабочие и исторические доки с вольными
# ссылками). Их можно линтовать явно, передав папку аргументом.
SKIP_DIRS = {".git", "tmp", "DerivedData", "plans", "history"}


def repo_root():
    # От расположения скрипта, не от cwd: Stop-хук стартует в cwd агента.
    return os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def walk_md(roots):
    out = []
    for r in roots:
        for dp, dns, fns in os.walk(r):
            dns[:] = [d for d in dns if d not in SKIP_DIRS]
            out += [os.path.join(dp, fn) for fn in fns if fn.endswith(".md")]
    return out


def changed_md(root):
    lines = subprocess.check_output(["git", "-C", root, "status", "--porcelain", "--untracked-files=all"],
                                    text=True).splitlines()
    res = []
    for ln in lines:
        p = ln[3:].strip().strip('"')
        if " -> " in p:
            p = p.split(" -> ")[-1]
        if "/plans/" in p or "/history/" in p or p.startswith("tmp/"):
            continue
        full = os.path.join(root, p)
        if p.endswith(".md") and os.path.isfile(full):
            res.append(full)
    return res


def check(files):
    broken, checked = [], 0
    for f in files:
        try:
            text = open(f, encoding="utf-8").read()
        except (OSError, UnicodeDecodeError):
            continue
        for m in LINK_RE.finditer(text):
            tgt = m.group(1).strip()
            if tgt.startswith(("http://", "https://", "mailto:", "x-apple", "#")):
                continue
            tgt = tgt.split("#")[0].strip()
            if not tgt or tgt == "..." or any(c in tgt for c in "<>{}"):
                continue
            if "tmp/" in tgt:
                continue
            tgt = LINE_SUFFIX.sub("", urllib.parse.unquote(tgt))
            checked += 1
            resolved = os.path.normpath(os.path.join(os.path.dirname(f), tgt))
            if not os.path.exists(resolved):
                broken.append((f, m.group(0)[:60], tgt))
    return broken, checked


def main():
    root = repo_root()
    changed = "--changed" in sys.argv
    dirs = [a for a in sys.argv[1:] if not a.startswith("--")]

    if changed:
        files = changed_md(root)
    else:
        roots = [os.path.join(root, d) for d in (dirs or ["flow", ".claude"])]
        files = walk_md(roots)
        if not dirs:
            files += [p for p in (os.path.join(root, fn) for fn in ("AGENTS.md", "CLAUDE.md")) if os.path.isfile(p)]

    broken, checked = check(files)
    rel = lambda p: os.path.relpath(p, root)

    if broken:
        print(f"check-links: БИТЫЕ относительные ссылки ({len(broken)}):")
        for f, link, tgt in broken:
            print(f"  {rel(f)}: {link} -> {tgt}")
        sys.exit(1)

    if not changed:
        print(f"check-links: ✓ чисто ({checked} ссылок в {len(files)} файлах)")


if __name__ == "__main__":
    main()
