# Swift Testing: неочевидные ошибки сборки тестов

Ошибки, причина которых не выводится из текста компилятора. Ищи по тексту ошибки в индексе. Правила и формат — `flow/meta/conventions.md` → «Правила для gotchas-документов».

## Индекс симптомов

| Текст ошибки / симптом | Куда |
|---|---|
| `macro expansion #expect: error: call can throw, but it is not marked with 'try'` на строке без бросающих вызовов | Правило 1 |
| Десятки тестов `failed (0.000 seconds)`, `Early unexpected exit … Crash: Trash at … Runner._applyScopingTraits`; в краш-репорте `EXC_BREAKPOINT`, `dispatch_assert_queue_fail` | Правило 2 |

## Правила

### 1. Внутри `#expect` — замыкание, а не key path, в функциях высшего порядка

`#expect(items.allSatisfy(\.isDeletable))` не собирается: макрос разворачивает вызов с key path-аргументом в форму, которую компилятор считает бросающей. Пишите замыканием:

```swift
#expect(items.allSatisfy { $0.isDeletable })
```

Вне `#expect` key path работает как обычно. Примеры: `allSatisfy`, `contains(where:)`, `filter` прямо в условии `#expect`.

### 2. Статический метод SwiftUI-вью — на главном акторе: для тестов `nonisolated`

Тип с `View` неявно изолирован на `@MainActor`, вместе со статическими методами. Тест Swift Testing по умолчанию идёт не на главном акторе, но компилятор вызов пропускает: SwiftUI объявляет протокол с `@preconcurrency`. Во время выполнения проверка изоляции роняет **весь процесс тестов**, и падают соседние тесты, а не только виновный.

Чистую функцию вью, нужную тестам, помечай `nonisolated` или выноси в отдельный тип:

```swift
nonisolated static func summary(of report: CleanupReport) -> String { … }
```

Виновника ищи в краш-репорте `~/Library/Logs/DiagnosticReports/Trash-*.ips`: поток с `_swift_task_checkIsolatedSwift` и над ним — вызванный метод и строка теста.

## Записи-случаи

#### 2026-10-13 — 43 теста «упали» за 0,000 с из-за одного вызова метода вью

- Симптом: `make test` — `Early unexpected exit`, падают тесты разных наборов, у всех 0,000 с.
- Причина: тест вызвал `CleanupReportSheet.summary(of:)` — статический метод вью, неявно `@MainActor` — вне главного актора; сработала проверка изоляции во время выполнения.
- Правильно: `nonisolated static func summary(of:)`.
- Урок: массовые падения за 0,000 с — сначала краш-репорт, а не сами тесты.

#### 2026-10-12 — `call can throw` на `allSatisfy(\.isDeletable)` в `#expect`

- Симптом: `TerminalScannerTests` не собирается, ошибка указывает на `#expect(result.items.allSatisfy(\.isDeletable))`.
- Причина: развёртка макроса `#expect` для вызова функции с key path-аргументом.
- Правильно: `#expect(result.items.allSatisfy { $0.isDeletable })`.
- Урок: при «call can throw» внутри `#expect` без `try`-вызовов — сначала заменить key path на замыкание.
