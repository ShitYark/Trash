# Карта файлов Claude-flow

## Точка входа (грузится в каждой сессии)

| Путь | Назначение |
|---|---|
| `AGENTS.md` | Рубрикатор проекта: описание, карта репозитория, навигация, маршрутизация в команды |
| `CLAUDE.md` | Мост для Claude Code: `@AGENTS.md` |
| `flow/rules/root-rule.md` | Общие правила работы — `@import` из `AGENTS.md` |
| `flow/rules/response-format.md` | Формат ответов в чате — `@import` из `AGENTS.md` |

## Знания и правила (`flow/`)

| Путь | Назначение | Загрузка |
|---|---|---|
| `flow/rules/glossary.md` | Глоссарий: термин → документ за один переход | Лениво, поиском в начале задачи |
| `flow/rules/naming-conventions.md` | Сообщение коммита, имя ветки, кто коммитит | В момент формирования имени |
| `flow/knowledge/modules/` | Документация модулей: `scanning`, `cleanup`, `main-window` | По переходу из глоссария |
| `flow/knowledge/engineering/` | Код-стайл, сборка и тесты, правило проверки фактов, gotchas | По переходу из глоссария |
| `flow/project-map.md` | Вспомогательная карта слоёв и потоков | Когда глоссария недостаточно |
| `flow/history/<module>-history.md` | Хроника правок модуля. **Изолирована** от навигации | Только субагентом `context` и `/dev:history` |
| `flow/history/<module>-history/<period>.md` | Архивные периоды истории | Из дайджеста главного файла |
| `flow/plans/` | Планы рабочих задач | Только в рамках задачи |
| `flow/meta/` | Документация про сам flow, карта code→module, feedback-log, планы flow | Только при задачах про flow (`/dev:meta`) |

## Команды и субагенты

| Путь | Назначение |
|---|---|
| `.claude/commands/dev/code.md` | `/dev:code` — правка кода: интерпретация → артефакты → история → план → реализация → проверка → тесты → ревью → документация → отчёт |
| `.claude/commands/dev/analyze.md` | `/dev:analyze` — жалоба на поведение: баг, так задумано или ограничение macOS |
| `.claude/commands/dev/search.md` | `/dev:search` — поиск и объяснение без правок |
| `.claude/commands/dev/review.md` | `/dev:review` — review диффа; вызывает человек |
| `.claude/commands/dev/history.md` | `/dev:history` — генерация и архивация истории модуля; вызывает человек или автотриггер |
| `.claude/commands/dev/meta.md` | `/dev:meta` — изменения самого flow; вызывает человек |
| `.claude/commands/dev/artifacts.md` | Внутренний шаг: краш-репорты, логи, скриншоты, листинги |
| `.claude/agents/context.md` | Субагент `context` (sonnet): пересечения с историей модуля и решения «намеренно» |
| `.claude/agents/code-reviewer.md` | Субагент `code-reviewer` (opus): ревью диффа, безопасность удаления — первый приоритет |

## Хуки, скрипты и конфиг

| Путь | Назначение |
|---|---|
| `.claude/settings.json` | Хуки и `includeCoAuthoredBy: false`. Команда хука пропускает, если скрипта нет по `CLAUDE_PROJECT_DIR` |
| `flow/scripts/guard-bash.py` | PreToolUse (Bash): блокирует `git push`, `git commit`, переключение веток, `xcodebuild` мимо make, запись в `/tmp`, `rm` / `find -delete` вне проекта. Обход — `FLOW_ALLOW_*=1` по просьбе пользователя |
| `flow/scripts/check-doc-sync.py` | Stop: изменён код модуля, а его документ нет — напоминание. Карта — `flow/meta/code-to-module-map.json` |
| `flow/scripts/check-links.py` | Stop (`--changed`) и `make flow-check`: битые относительные ссылки |
| `flow/scripts/check-glossary.py` | Stop (`--changed`, ошибка блокирует завершение) и `make flow-check`: правила строк глоссария, пути, размер |
| `flow/scripts/check-sizes.py` | Stop (`--changed`) и `make flow-check`: пороги размеров истории, глоссария, документов |
| `flow/scripts/test_*.py` | Тесты скриптов и команд хуков — `make flow-test` |
| `Makefile` | `make build` / `test` / `run` / `clean` / `flow-check` / `flow-test` |
| `tmp/<topic>/` | Временные файлы агента, в `.gitignore` |
| `Debug/` | Debug-артефакты от пользователя, в `.gitignore` |

## Что НЕ грузится автоматически

- `flow/knowledge/**` — только через глоссарий.
- `flow/history/**` — изолировано, только субагенты и `/dev:history`.
- `flow/meta/**` — только при задачах про flow.
- `flow/plans/**` — только текущая задача.
