#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""PreToolUse-хук (matcher: Bash): блокирует команды, нарушающие протокол flow.

Вход: JSON на stdin ({"tool_input": {"command": ...}, "cwd": ...}).
Выход: exit 0 — команда разрешена; exit 2 — заблокирована, причина в stderr
(агент видит её и корректирует действие). Любая ошибка самого хука -> exit 0
(guard не должен ронять легитимную работу).

Каждое правило — узкий паттерн + флаг обхода в самой команде (FLOW_ALLOW_*=1):
флаг ставится только по явной просьбе пользователя в чате.

Тесты: python3 flow/scripts/test_guard_bash.py
"""
import json
import os
import re
import shlex
import sys

# Корень проекта — от расположения скрипта, не от cwd.
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
# Системный scratchpad Claude — временные файлы самого агента.
SCRATCH_PREFIXES = ("/tmp/claude", "/private/tmp/claude")
GLOB_CHARS = set("*?[")
SHELLS = {"bash", "sh", "zsh"}


def git_verb(cmd: str, verb: str):
    return re.search(r"\bgit(\s+-C\s+\S+|\s+-\S+)*\s+" + verb + r"\b", cmd)


def simple_commands(cmd: str):
    """Команда -> список простых команд (списки слов), разделители && || ; | ( ) > и т.п."""
    lexer = shlex.shlex(cmd, posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    commands, current = [], []
    for token in lexer:
        if token and set(token) <= set("();<>|&"):
            if current:
                commands.append(current)
            current = []
        else:
            current.append(token)
    if current:
        commands.append(current)
    return commands


def strip_prefixes(words):
    """Убирает присваивания окружения (FOO=1) и обёртки sudo / command / env."""
    while words and (re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", words[0]) or words[0] in ("sudo", "command", "env")):
        words = words[1:]
    return words


def deletion_targets(words):
    """Цели удаления в простой команде: rm <цели>, find <пути> ... -delete. Иначе — пустой список."""
    words = strip_prefixes(words)
    if not words:
        return []
    if words[0] == "xargs" and "rm" in words:
        words = words[words.index("rm"):]
    if words[0] == "rm":
        targets, options_done = [], False
        for word in words[1:]:
            if word == "--" and not options_done:
                options_done = True
            elif word.startswith("-") and not options_done:
                continue
            else:
                targets.append(word)
        return targets
    if words[0] == "find" and "-delete" in words:
        paths = []
        for word in words[1:]:
            if word.startswith("-") or word in ("(", "!"):
                break
            paths.append(word)
        return paths or ["."]
    return []


def nested_scripts(words):
    """bash -c "<скрипт>" — вложенный скрипт тоже проверяется."""
    words = strip_prefixes(words)
    if words and os.path.basename(words[0]) in SHELLS and "-c" in words:
        index = words.index("-c") + 1
        if index < len(words):
            return [words[index]]
    return []


def resolve(target: str, cwd: str):
    """Абсолютный нормализованный путь цели или None, если его не вычислить статически."""
    home = os.path.expanduser("~")
    if target.startswith("~"):
        target = home + target[1:]
    target = target.replace("${HOME}", home).replace("$HOME", home)
    if "$" in target or "`" in target:
        return None
    if not os.path.isabs(target):
        if not cwd:
            return None
        target = os.path.join(cwd, target)
    return os.path.normpath(target)


def deletion_problem(target: str, cwd: str):
    """Причина запрета удалить цель или None."""
    path = resolve(target, cwd)
    if path is None:
        return f"{target}: путь не вычислить статически (переменная или подстановка)"
    if path.startswith(SCRATCH_PREFIXES):
        return None
    root = os.path.normpath(ROOT)
    if path == root:
        return f"{target}: корень проекта целиком"
    if not path.startswith(root + os.sep):
        return f"{target}: вне проекта ({path})"
    relative = os.path.relpath(path, root)
    if relative == ".git" or relative.startswith(".git" + os.sep):
        return f"{target}: репозиторий git"
    if os.path.dirname(path) == root and GLOB_CHARS & set(os.path.basename(path)):
        return f"{target}: маска в корне проекта"
    return None


def deletion_problems(cmd: str, cwd: str, depth: int = 0):
    try:
        commands = simple_commands(cmd)
    except ValueError:
        return []  # незакрытые кавычки — не наш случай, команду не трогаем
    problems = []
    for words in commands:
        problems += [p for t in deletion_targets(words) if (p := deletion_problem(t, cwd))]
        if depth < 2:
            for script in nested_scripts(words):
                problems += deletion_problems(script, cwd, depth + 1)
    return problems


def check(cmd: str, cwd: str):
    """Возвращает текст блокировки или None."""
    # 1. git push — запрещён всегда: ветку отдаёт пользователь.
    if git_verb(cmd, "push"):
        return ("git push запрещён протоколом flow: коммиты и пуш делает пользователь "
                "(flow/rules/naming-conventions.md). Отчитайся готовыми изменениями и сообщением коммита.")

    # 2. git commit — коммитит пользователь; агент — только по явной просьбе.
    if git_verb(cmd, "commit") and "FLOW_ALLOW_COMMIT=1" not in cmd:
        return ("git commit запрещён: коммиты делает пользователь, агент предлагает строку сообщения "
                "(flow/rules/naming-conventions.md). Если пользователь явно попросил закоммитить — "
                "повтори команду, добавив в неё FLOW_ALLOW_COMMIT=1.")

    # 3. Переключение веток (root-rule п.9). `git checkout -- <файл>` разрешён.
    if git_verb(cmd, "(checkout|switch)") and " -- " not in cmd and "FLOW_ALLOW_CHECKOUT=1" not in cmd:
        return ("Переключение веток запрещено (root-rule п.9): читай чужую ветку через "
                "git show/log/blame <ветка> -- <путь>. Если переключение явно попросил пользователь — "
                "повтори команду, добавив в неё FLOW_ALLOW_CHECKOUT=1.")

    # 4. xcodebuild с build/test/clean/archive — только через make (root-rule п.1).
    #    Интроспекция (-list, -showBuildSettings, -version) разрешена.
    if (re.search(r"\bxcodebuild\b", cmd)
            and re.search(r"(?<![-/\w])(test|build|clean|archive|build-for-testing|test-without-building)(?=$|\s)", cmd)
            and "FLOW_ALLOW_XCODEBUILD=1" not in cmd):
        return ("Сборка и тесты — только через make build / make test / make run (root-rule п.1). "
                "Голый xcodebuild — лишь для интроспекции (-list, -showBuildSettings). "
                "Осознанный обход по просьбе пользователя — повтори с FLOW_ALLOW_XCODEBUILD=1.")

    # 5. Запись в /tmp — временные файлы агента живут в tmp/<topic>/ проекта (root-rule п.6).
    if (re.search(r"(>>?|\btee(\s+-a)?)\s+/(private/)?tmp/(?!claude)", cmd)
            and "FLOW_ALLOW_TMP=1" not in cmd):
        return ("Временные файлы агента — только в tmp/<topic>/ внутри проекта, не в /tmp (root-rule п.6). "
                "Осознанное исключение — повтори с FLOW_ALLOW_TMP=1.")

    # 6. Удаление вне проекта (root-rule п.2): агент не удаляет файлы пользователя.
    if "FLOW_ALLOW_RM=1" not in cmd:
        problems = deletion_problems(cmd, cwd)
        if problems:
            return ("Удаление вне проекта запрещено (root-rule п.2: безопасность удаления). "
                    "Логику очистки проверяй тестами во временной папке. Заблокировано: "
                    + "; ".join(problems)
                    + ". Только по явной просьбе пользователя — повтори с FLOW_ALLOW_RM=1.")

    return None


def main() -> int:
    try:
        data = json.load(sys.stdin)
        cmd = (data.get("tool_input") or {}).get("command") or ""
        cwd = data.get("cwd") or ""
        msg = check(cmd, cwd) if cmd else None
    except Exception:
        return 0
    if msg:
        print(msg, file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
