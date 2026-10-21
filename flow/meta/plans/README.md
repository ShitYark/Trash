# Планы улучшений Claude-flow

Планы изменений самого flow. Формат плана — [../conventions.md](../conventions.md), раздел «Правила для планов». Работа с планами — команда `/dev:meta`.

## Workflow статусов

Прямой путь: `proposed` → `approved` → `in_progress` → `done`.

Боковые переходы:

- `rejected` — план отклонён, причина указана в теле. Возможен с любого статуса до `done`.
- `on_hold` — план приостановлен, ждёт внешнего события. Возврат в `approved` или `in_progress`.

| Переход | Условия |
|---|---|
| `proposed → approved` | Открытые вопросы разрешены, объём работы понятен |
| `approved → in_progress` | Старт реализации |
| `in_progress → done` | Все критерии готовности выполнены, `make flow-check` чист |
| любой → `rejected` | Принято решение не делать; причина — в теле плана |
| `approved` / `in_progress` → `on_hold` | Нужно внешнее событие или решение |

При любом переходе обновляются `status` и `updated` во frontmatter и строка плана в таблице ниже.

## Планы

| План | Статус | Обновлён | Суть |
|---|---|---|---|
| [port-whitebox-flow](port-whitebox-flow.md) | `done` | 2026-10-12 | Перенос Claude-flow из WhiteBox iOS с адаптацией под Trash |
