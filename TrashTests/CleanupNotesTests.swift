import Foundation
import Testing
@testable import Trash

/// Тексты окна очистки — только про то, что отмечено и что сделано. Файлы не создаются: тексты считаются по элементам.
struct CleanupNotesTests {
    let home = URL(filePath: "/Users/tester", directoryHint: .isDirectory)

    @Test func singleRuntimeTalksOnlyAboutSimctl() {
        let runtime = ScanItem(url: home.appending(path: "rt"), size: 10, category: .simulatorRuntimes,
                               removal: .runtime(identifier: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
                                                 runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-17-5"))

        let notes = CleanupNotes(items: [runtime])

        #expect(notes.subtitle == "Перед удалением всё проверяется ещё раз: не тронем нужные симуляторам рантаймы.")
        #expect(notes.lines.map(\.text) == ["Рантаймы симуляторов удалит simctl — сразу, без Корзины."])
        #expect(notes.isAlwaysPermanent, "выбора режима нет — одна кнопка")
    }

    @Test func trashContentAloneHasNoModeChoice() {
        let notes = CleanupNotes(items: [ScanItem(url: home.appending(path: ".Trash/file"), size: 10, category: .trash)])

        #expect(notes.isAlwaysPermanent, "Корзина удаляется навсегда при любом режиме — «можно вернуть» было бы неправдой")
        #expect(notes.lines.map(\.text) == ["Содержимое Корзины удаляется навсегда."])
    }

    @Test func simulatorFoldersWithoutSimulatorFollowTheMode() {
        let udid = "11111111-1111-1111-1111-111111111111"
        let items = [
            ScanItem(url: home.appending(path: "rt"), size: 10, category: .simulatorRuntimes,
                     removal: .runtime(identifier: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
                                       runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-17-5")),
            ScanItem(url: home.appending(path: udid), size: 10, category: .simulators, removal: .simulator(udid: udid)),
            ScanItem(url: home.appending(path: "22222222-2222-2222-2222-222222222222"), size: 10, category: .simulators),
        ]

        let notes = CleanupNotes(items: items)

        #expect(notes.lines.map(\.text) == [
            "Рантаймы симуляторов и симуляторы удалит simctl — сразу, без Корзины.",
            "Папки без симулятора удаляются как файлы — по выбранному режиму.",
        ])
        #expect(!notes.isAlwaysPermanent, "папка без симулятора удаляется по выбранному режиму")
        #expect(notes.trashCaption == "Можно вернуть, кроме удалённого через simctl. Остальное место — после очистки Корзины.")
    }

    @Test func reportSummaryNamesOnlyActualDestinations() {
        var report = CleanupReport()
        report.removed = [home.appending(path: "a")]
        report.removedByManagers = 1
        #expect(CleanupReportSheet.summary(of: report) == "Удалено сразу, без Корзины.")

        report.removed.append(home.appending(path: "b"))
        report.movedToTrash = 1
        #expect(CleanupReportSheet.summary(of: report) == "В Корзину: 1\nСразу, без Корзины: 1")

        #expect(CleanupReportSheet.summary(of: CleanupReport()) == "Ничего не удалено — причины ниже.")
    }

    @Test func eachDestinationIsMentionedOnlyWhenSelected() {
        let items = [
            ScanItem(url: URL(filePath: "/Applications/Old.app"), size: 10, category: .installedApplications),
            ScanItem(url: home.appending(path: ".Trash/file"), size: 10, category: .trash),
            ScanItem(url: home.appending(path: "Cellar/libfoo/1.0"), size: 10, category: .homebrew, removal: .brewUninstall(formula: "libfoo")),
        ]

        let notes = CleanupNotes(items: items)

        #expect(notes.lines.map(\.text) == [
            "Пакеты Homebrew удалит brew — сразу, без Корзины.",
            "Содержимое Корзины удаляется навсегда, даже при «Переместить в Корзину».",
            "Программы уходят только в Корзину, даже при «Удалить навсегда».",
        ])
        #expect(notes.subtitle.contains("запущенные программы") && notes.subtitle.contains("нужные другим пакеты Homebrew"))
        #expect(!notes.subtitle.contains("симулятор"))
        #expect(!notes.isAlwaysPermanent, "программы уходят по своему пути — выбор режима остаётся")
        #expect(notes.trashCaption == "Можно вернуть, кроме удалённого через brew и содержимого Корзины. Остальное место — после очистки Корзины.",
                "называются только инструменты отмеченного")
        #expect(notes.permanentCaption == "Вернуть будет нельзя — кроме программ: они уйдут в Корзину.")
    }

    @Test func newToolsAreNamedWithWhatTheyKeep() {
        let items = [
            ScanItem(url: home.appending(path: "docker#images"), size: 10, category: .docker, removal: .dockerPrune(.images)),
            ScanItem(url: home.appending(path: "miniforge3/envs/ml"), size: 10, category: .conda,
                     removal: .condaRemoveEnvironment(conda: "/x/bin/conda", prefix: "/x/envs/ml")),
            ScanItem(url: home.appending(path: "miniforge3/pkgs"), size: 10, category: .conda, removal: .condaClean(conda: "/x/bin/conda")),
            ScanItem(url: home.appending(path: ".ollama/m"), size: 10, category: .ollama, removal: .ollamaDelete(model: "llama3:8b")),
            ScanItem(url: home.appending(path: ".android/avd/tablet.avd"), size: 10, category: .androidSDK),
            ScanItem(url: home.appending(path: "Library/Android/sdk/system-images/android-34/google_apis/arm64-v8a"), size: 10, category: .androidSDK),
        ]

        let notes = CleanupNotes(items: items)

        #expect(notes.lines.map(\.text) == [
            "Данные Docker удалит docker — сразу, без Корзины.",
            "Окружения и кэш пакетов conda удалит сама conda — сразу, без Корзины.",
            "Модели удалит Ollama — сразу, без Корзины.",
        ])
        #expect(notes.subtitle.contains("запущенные эмуляторы Android, нужные эмуляторам образы Android"))
        #expect(notes.subtitle.contains("base conda"))
        #expect(notes.trashCaption.hasPrefix("Можно вернуть, кроме удалённого через docker, conda или Ollama."))
        #expect(!notes.isAlwaysPermanent, "файлы Android — по выбранному режиму")
    }

    @Test func administratorStepsAreNamed() {
        let items = [
            ScanItem(url: URL(filePath: "/usr/local/bin/docker"), size: 0, category: .terminalPrograms, isRecommended: true),
            ScanItem(url: URL(filePath: "/Library/LaunchDaemons/com.docker.vmnetd.plist"), size: 10, category: .backgroundServices, isRecommended: true),
        ]

        let system = { (item: ScanItem) in !item.url.path.hasPrefix(self.home.path) }
        let notes = CleanupNotes(items: items, needsAdministrator: system)

        #expect(notes.lines.map(\.text) == ["Битые ссылки и службы в /Library — с паролем администратора, сразу и без Корзины."])
        #expect(notes.subtitle.contains("ссылки, которые снова ведут на программу") && notes.subtitle.contains("службы, чья программа снова на месте"))
        #expect(notes.isAlwaysPermanent, "от root — выбора режима нет")

        let mixed = CleanupNotes(items: items + [ScanItem(url: home.appending(path: ".local/bin/old"), size: 0, category: .terminalPrograms)],
                                 needsAdministrator: system)
        #expect(!mixed.isAlwaysPermanent, "своя ссылка — по выбранному режиму")
        #expect(mixed.trashCaption == "Можно вернуть, кроме удалённого с паролем администратора. Остальное место — после очистки Корзины.")
    }

    @Test func otherDataIsNamed() {
        let items = [
            ScanItem(url: home.appending(path: "dyld/x"), size: 10, category: .simulatorDyldCaches,
                     removal: .dyldCacheRemove(runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-16-0", build: "20A360")),
            ScanItem(url: home.appending(path: "rt"), size: 10, category: .simulatorRuntimes,
                     removal: .runtime(identifier: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA", runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-16-0")),
            ScanItem(url: home.appending(path: "x"), size: 10, category: .simulators, removal: .simulator(udid: "11111111-1111-1111-1111-111111111111")),
            ScanItem(url: home.appending(path: "Library/Application Support/Slack/Cache"), size: 10, category: .applicationSupportCaches),
        ]

        let notes = CleanupNotes(items: items, needsAdministrator: { _ in false })

        #expect(notes.lines.map(\.text) == ["Рантаймы симуляторов, симуляторы и кэши симуляторов удалит simctl — сразу, без Корзины."])
        #expect(notes.subtitle.contains("кэши запущенных программ") && notes.subtitle.contains("кэши рантаймов с запущенным симулятором"))
    }

    @Test func filesOnlyNeedNoNote() {
        let notes = CleanupNotes(items: [ScanItem(url: home.appending(path: "Library/Caches/com.example"), size: 10, category: .userCaches)])

        #expect(notes.lines.isEmpty, "куда уйдут файлы, говорят кнопки — плашка не нужна")
        #expect(notes.subtitle == "Перед удалением всё проверяется ещё раз: не тронем системные папки и файлы вне разрешённых.")
        #expect(!notes.isAlwaysPermanent)
        #expect(notes.trashCaption == "Можно вернуть. Место освободится, когда очистите Корзину.")
    }
}
