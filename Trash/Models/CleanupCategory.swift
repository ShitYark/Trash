import Foundation

/// Группа категорий: «Система» — по пункту боковой панели на категорию; «Xcode» и «Терминал» — по одному пункту с разделами.
enum CategoryGroup: String, CaseIterable, Identifiable, Sendable {
    case system
    case applications
    case xcode
    case terminal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "Система"
        case .applications: "Программы"
        case .xcode: "Xcode"
        case .terminal: "Терминал"
        }
    }

    /// Иконка пункта боковой панели для групп, которые показываются одним пунктом.
    var systemImage: String {
        switch self {
        case .system: "internaldrive"
        case .applications: "square.grid.2x2"
        case .xcode: "hammer.fill"
        case .terminal: "terminal"
        }
    }

    var categories: [CleanupCategory] {
        CleanupCategory.allCases.filter { $0.group == self }
    }

    /// Скрывать пустые разделы: в «Терминале» у каждого пользователя свой набор инструментов,
    /// и разделы инструментов, которых на этом Mac нет, не показываются.
    var hidesEmptySections: Bool {
        self == .terminal
    }
}

/// Как сканер находит элементы категории.
enum ScanMethod: Sendable {
    /// Каждый непосредственный потомок корневых папок — отдельный элемент.
    case children
    /// Потомки корня с подписью проекта из `info.plist`.
    case derivedData
    /// Потомки корней с версией системы; самая свежая версия не отмечается.
    case deviceSupport
    /// Пакеты `.xcarchive` из папок по датам.
    case archives
    /// Симуляторы из `simctl` и папки без симулятора.
    case simulators
    /// Рантаймы из `simctl runtime`.
    case runtimes
    /// Неактивные копии Xcode в папке программ.
    case applications
    /// Компоненты Android SDK и эмуляторы.
    case androidSDK
    /// Пакеты Homebrew из `brew info --json=v2 --installed`.
    case homebrew
    /// Кэши и дистрибутивы Gradle; дистрибутивы — кроме самой свежей версии.
    case gradle
    /// Программы, поставленные мимо Homebrew.
    case programs
    /// Агенты и службы `launchd`.
    case services
    /// Версии языков из менеджеров версий.
    case languageVersions
    /// Диск Docker Desktop и что в нём можно освободить — по `docker system df`.
    case docker
    /// Окружения и кэш пакетов conda.
    case conda
    /// Неактивные порты, исходники и сборки MacPorts.
    case macPorts
    /// Модели Ollama по манифестам.
    case ollama
    /// Программы из папок программ.
    case installedApplications
    /// Данные программ, которых больше нет.
    case appLeftovers
    /// Кэши dyld рантаймов в `/Library/Developer/CoreSimulator/Caches/dyld`.
    case dyldCaches
    /// Кэши Chromium внутри `~/Library/Application Support`.
    case applicationSupportCaches
    /// Установщики в `~/Downloads`.
    case installers
}

/// Категория мусора, которую умеет находить приложение.
enum CleanupCategory: String, CaseIterable, Identifiable, Sendable {
    case userCaches
    case userLogs
    case trash
    case simulatorRuntimes
    case simulators
    case xcodeDerivedData
    case xcodeDeviceSupport
    case xcodeArchives
    case swiftUIPreviews
    case documentationCache
    case packageCaches
    case xcodeCaches
    case xcodeLogs
    case xcodeProducts
    case xcodeApplications
    case androidSDK
    case homebrew
    case gradle
    case toolCaches
    case terminalPrograms
    case backgroundServices
    case languageVersions
    case docker
    case conda
    case macPorts
    case ollama
    case installedApplications
    case appLeftovers
    case simulatorDyldCaches
    case applicationSupportCaches
    case downloadedInstallers

    var id: String { rawValue }

    var group: CategoryGroup {
        switch self {
        case .userCaches, .userLogs, .trash, .applicationSupportCaches, .downloadedInstallers: .system
        case .androidSDK, .homebrew, .gradle, .toolCaches, .terminalPrograms, .backgroundServices, .languageVersions,
             .docker, .conda, .macPorts, .ollama: .terminal
        case .installedApplications, .appLeftovers: .applications
        default: .xcode
        }
    }

    var title: String {
        switch self {
        case .userCaches: "Кэши приложений"
        case .userLogs: "Журналы"
        case .trash: "Корзина"
        case .simulatorRuntimes: "Рантаймы симуляторов"
        case .simulators: "Симуляторы"
        case .xcodeDerivedData: "DerivedData"
        case .xcodeDeviceSupport: "Device Support"
        case .xcodeArchives: "Архивы"
        case .swiftUIPreviews: "Превью SwiftUI"
        case .documentationCache: "Кэш документации"
        case .packageCaches: "Кэши пакетов"
        case .xcodeCaches: "Кэши Xcode и симуляторов"
        case .xcodeLogs: "Логи Xcode"
        case .xcodeProducts: "Products"
        case .xcodeApplications: "Старые версии Xcode"
        case .androidSDK: "Android SDK и эмуляторы"
        case .homebrew: "Homebrew"
        case .gradle: "Gradle"
        case .toolCaches: "Кэши менеджеров пакетов"
        case .terminalPrograms: "Программы вне Homebrew"
        case .backgroundServices: "Фоновые службы"
        case .languageVersions: "Версии языков"
        case .docker: "Docker"
        case .conda: "conda"
        case .macPorts: "MacPorts"
        case .ollama: "Модели Ollama"
        case .installedApplications: "Установленные программы"
        case .appLeftovers: "Остатки удалённых программ"
        case .simulatorDyldCaches: "Общие кэши симуляторов"
        case .applicationSupportCaches: "Кэши в данных программ"
        case .downloadedInstallers: "Установщики в Загрузках"
        }
    }

    var summary: String {
        switch self {
        case .userCaches:
            "Временные данные приложений. Приложения создадут их заново при необходимости."
        case .userLogs:
            "Журналы приложений и отчёты о сбоях."
        case .trash:
            "Файлы в Корзине. Удаляются безвозвратно."
        case .simulatorRuntimes:
            "Образы систем для симуляторов — самые большие файлы Xcode. Меткой «мусор» помечены те, которыми не пользуется ни один симулятор; сами не отмечаются — удаление через simctl сразу и без Корзины. Скачиваются заново в настройках Xcode."
        case .simulators:
            "Симуляторы со всеми данными приложений. Меткой «мусор» помечены недоступные — их рантайм удалён — и папки, которых simctl не знает; сами не отмечаются. Симуляторы удаляет simctl — сразу и без Корзины."
        case .xcodeDerivedData:
            "Промежуточные результаты сборки по проектам. Безопасно удалять — пересоберутся автоматически."
        case .xcodeDeviceSupport:
            "Символы для отладки на устройствах по версиям систем. Самая свежая версия не отмечена: она нужна для текущего устройства."
        case .xcodeArchives:
            "Архивы сборок из Organizer. В них символы для разбора крашей выпущенных версий — удаляйте осознанно."
        case .swiftUIPreviews:
            "Симуляторы и сборки для превью SwiftUI. Xcode создаст их заново."
        case .documentationCache:
            "Скачанная документация Xcode. Загрузится заново при открытии."
        case .packageCaches:
            "Кэши Swift Package Manager, CocoaPods и Carthage. Пакеты скачаются заново при сборке."
        case .xcodeCaches:
            "Кэши Xcode, симуляторов и клонов симуляторов для параллельных тестов."
        case .xcodeLogs:
            "Логи с подключённых устройств и журналы симуляторов."
        case .xcodeProducts:
            "Кэш Organizer: данные App Store Connect о выпущенных версиях — краши, метрики, иконки. Xcode загрузит их заново."
        case .xcodeApplications:
            "Копии Xcode, кроме выбранной в xcode-select. Удаляются только в Корзину; удаляйте только ненужные бета-версии."
        case .androidSDK:
            "Образы систем, build-tools, NDK, платформы и эмуляторы Android. Меткой «мусор» помечены образы, которые не использует ни один эмулятор, и build-tools и NDK, кроме самой свежей версии; сами не отмечаются. Запущенный эмулятор и образ, нужный эмулятору, не удаляются; эмулятор, platform-tools и cmdline-tools — только поиск."
        case .homebrew:
            "Пакеты, поставленные через brew. Меткой «мусор» помечены зависимости, которые больше ничему не нужны, и старые версии — их удаляют brew uninstall и brew cleanup, сразу и без Корзины. Сами не отмечаются; старые версии формулы отмечаются вместе."
        case .gradle:
            "Кэш зависимостей и дистрибутивы Gradle. Скачаются заново при сборке; самая свежая версия дистрибутива не отмечена."
        case .toolCaches:
            "Загрузки npm, pip, Yarn, pnpm, Poetry, Go, Cargo, Maven, Flutter, Bun, Homebrew и ~/.cache. Скачаются заново при необходимости."
        case .terminalPrograms:
            "Python с python.org, глобальные npm-пакеты, команды в /usr/local/bin и ~/.local/bin. Меткой «мусор» помечены ссылки на уже удалённые программы — только их приложение и удаляет; сами не отмечаются. В чужих папках, например /usr/local/bin, — с паролем администратора, сразу и без Корзины."
        case .backgroundServices:
            "Агенты и службы, которые запускаются в фоне. Меткой «мусор» помечены те, чья программа уже удалена, — только их приложение и удаляет: удаляет plist, и после перезагрузки служба не загрузится; сами не отмечаются. Службы в /Library — с паролем администратора, сразу и без Корзины."
        case .languageVersions:
            "Версии языков из nvm, fnm, Volta, pyenv, rbenv, rustup, SDKMAN, asdf и mise. Меткой «мусор» помечены все, кроме активных; сами не отмечаются. Активную версию удалить нельзя."
        case .docker:
            "Диск виртуальной машины Docker Desktop, разобранный по docker system df: остановленные контейнеры, неиспользуемые образы и кэш сборки удаляет docker prune — сразу и без Корзины, при запущенном Docker Desktop. Тома и остальное на диске — только поиск. Место вернётся в macOS через несколько минут."
        case .conda:
            "Окружения и кэш пакетов conda, Miniforge, Anaconda и micromamba. Окружение удаляет conda remove --all, кэш — conda clean --all: сразу и без Корзины. Сами не отмечаются; размер — оценка без файлов, общих с другими окружениями."
        case .macPorts:
            "Неактивные версии портов, скачанные исходники и папки сборки MacPorts. Неактивные версии удаляет port uninstall — сразу и без Корзины, а если MacPorts поставлен от root — с паролем администратора; сами не отмечаются. Исходники и папки сборки чистите сами: sudo port reclaim."
        case .ollama:
            "Скачанные модели Ollama. Сами не отмечаются: модель — ваш выбор, а не мусор. Удаляет сама Ollama, как ollama rm, — сразу и без Корзины; она должна быть запущена. Слои, общие с другими моделями, остаются."
        case .installedApplications:
            "Программы из /Applications и ~/Applications. Удаляются только в Корзину; запущенную сначала закройте. Данные программы после удаления появятся в «Остатках удалённых программ»."
        case .appLeftovers:
            "Данные, настройки и кэши программ, которых больше нет. Отмечены уверенные остатки — у производителя не осталось ни одной программы; файлы настроек не отмечаются."
        case .simulatorDyldCaches:
            "Общие кэши dyld рантаймов симуляторов. Удаляет simctl — сразу и без Корзины. Меткой «мусор» помечены кэши рантаймов, которые эта macOS не поддерживает: их кэш больше не создаётся. Остальные Xcode создаст заново при следующем запуске — место вернётся ненадолго. Сами не отмечаются."
        case .applicationSupportCaches:
            "Кэши Chromium и Electron внутри данных программ: Slack, Claude, Figma, VS Code и других. Программы создадут их заново. Удаляются только у закрытых программ; данные — переписки, настройки, хранилища — не трогаются. Сами не отмечаются."
        case .downloadedInstallers:
            "Образы дисков и установщики .dmg, .pkg и .xip в папке Загрузки. Если программа уже установлена, они не нужны, но образ диска бывает и вашим — проверьте сами. Мусором не помечаются и сами не отмечаются."
        }
    }

    var systemImage: String {
        switch self {
        case .userCaches: "archivebox"
        case .userLogs: "doc.text"
        case .trash: "trash"
        case .simulatorRuntimes: "externaldrive"
        case .simulators: "macbook.and.iphone"
        case .xcodeDerivedData: "hammer"
        case .xcodeDeviceSupport: "iphone"
        case .xcodeArchives: "tray.full"
        case .swiftUIPreviews: "eye"
        case .documentationCache: "book"
        case .packageCaches: "shippingbox"
        case .xcodeCaches: "internaldrive"
        case .xcodeLogs: "doc.plaintext"
        case .xcodeProducts: "cube"
        case .xcodeApplications: "app.dashed"
        case .androidSDK: "rectangle.stack"
        case .homebrew: "cup.and.saucer"
        case .gradle: "gearshape.2"
        case .toolCaches: "tray.2"
        case .terminalPrograms: "terminal"
        case .backgroundServices: "bolt.horizontal"
        case .languageVersions: "chevron.left.forwardslash.chevron.right"
        case .docker: "shippingbox.circle"
        case .conda: "leaf"
        case .macPorts: "ferry"
        case .ollama: "brain"
        case .installedApplications: "square.grid.2x2"
        case .appLeftovers: "tray.and.arrow.down"
        case .simulatorDyldCaches: "memorychip"
        case .applicationSupportCaches: "folder.badge.gearshape"
        case .downloadedInstallers: "externaldrive.badge.plus"
        }
    }

    var scanMethod: ScanMethod {
        switch self {
        case .xcodeDerivedData: .derivedData
        case .xcodeDeviceSupport: .deviceSupport
        case .xcodeArchives: .archives
        case .simulators: .simulators
        case .simulatorRuntimes: .runtimes
        case .xcodeApplications: .applications
        case .androidSDK: .androidSDK
        case .homebrew: .homebrew
        case .gradle: .gradle
        case .terminalPrograms: .programs
        case .backgroundServices: .services
        case .languageVersions: .languageVersions
        case .docker: .docker
        case .conda: .conda
        case .macPorts: .macPorts
        case .ollama: .ollama
        case .installedApplications: .installedApplications
        case .appLeftovers: .appLeftovers
        case .simulatorDyldCaches: .dyldCaches
        case .applicationSupportCaches: .applicationSupportCaches
        case .downloadedInstallers: .installers
        default: .children
        }
    }

    /// Отмечать ли найденные элементы для удаления сразу после сканирования.
    /// Категории с собственной логикой поиска решают это поэлементно.
    var isSelectedByDefault: Bool {
        switch self {
        case .userCaches, .userLogs, .xcodeDerivedData, .swiftUIPreviews, .documentationCache,
             .packageCaches, .xcodeCaches, .xcodeLogs, .gradle, .toolCaches:
            true
        case .trash, .simulatorRuntimes, .simulators, .xcodeDeviceSupport, .xcodeArchives,
             .xcodeProducts, .xcodeApplications, .androidSDK, .homebrew, .terminalPrograms,
             .backgroundServices, .languageVersions, .docker, .conda, .macPorts, .ollama, .installedApplications, .appLeftovers,
             .simulatorDyldCaches, .applicationSupportCaches, .downloadedInstallers:
            false
        }
    }

    /// Удаляет ли приложение элементы категории. Сейчас — все: файлами по узким правилам стража, через менеджер
    /// или от root; что внутри раздела удалять нельзя, решает элемент (`ScanItem.isDeletable`). Программы и копии
    /// Xcode удаляются в Корзину.
    var isDeletable: Bool {
        // Без `default`: новая категория обязана явно попасть в один из списков.
        switch self {
        case .userCaches, .userLogs, .trash, .xcodeDerivedData, .xcodeDeviceSupport, .xcodeArchives, .swiftUIPreviews,
             .documentationCache, .packageCaches, .xcodeCaches, .xcodeLogs, .xcodeProducts, .gradle, .toolCaches,
             .xcodeApplications, .installedApplications, .appLeftovers, .simulatorRuntimes, .simulators, .homebrew,
             .languageVersions, .androidSDK, .docker, .conda, .ollama, .terminalPrograms, .backgroundServices, .macPorts,
             .simulatorDyldCaches, .applicationSupportCaches, .downloadedInstallers:
            true
        }
    }

    /// Элементы удаляются только командой менеджера: без операции у элемента — встроенный рантайм, явно
    /// поставленный пакет, cask — выбрать его нельзя. Путь элемента тут не корень удаления, а место для подписи.
    var isManagerOnly: Bool {
        switch self {
        case .simulatorRuntimes, .homebrew, .docker, .conda, .ollama, .macPorts, .simulatorDyldCaches: true
        default: false
        }
    }

    /// Отмечать ли явный мусор сам после скана. Где удаление необратимо или нужно ваше решение — нет:
    /// среди «мусорных» рантаймов бывает нужная проекту старая iOS, а активной версии языка решает пользователь.
    var autoSelectsRecommended: Bool {
        switch self {
        case .simulatorRuntimes, .simulators, .homebrew, .languageVersions, .androidSDK, .docker, .conda, .ollama, .terminalPrograms,
             .backgroundServices, .macPorts, .simulatorDyldCaches, .applicationSupportCaches, .downloadedInstallers:
            false
        default: true
        }
    }

    /// Программы удаляются только в Корзину — как в Finder, чтобы их можно было вернуть.
    var isApplicationBundle: Bool {
        self == .installedApplications || self == .xcodeApplications
    }

    /// Элементы категории нельзя переместить в Корзину — только удалить навсегда.
    var alwaysDeletesPermanently: Bool {
        self == .trash
    }

    /// Папки, в которых лежат элементы категории. Все — внутри домашней папки.
    /// Категории, которые ищутся по системным папкам (`/usr/local`, `/Library`, `/Applications`)
    /// или командами, корней вне `~` не имеют: системные папки сканер только читает — `SystemLocations`.
    func roots(home: URL) -> [URL] {
        let library = home.appending(path: "Library", directoryHint: .isDirectory)
        let developer = library.appending(path: "Developer", directoryHint: .isDirectory)
        let xcode = developer.appending(path: "Xcode", directoryHint: .isDirectory)
        let caches = library.appending(path: "Caches", directoryHint: .isDirectory)
        let folder = { (base: URL, path: String) in base.appending(path: path, directoryHint: .isDirectory) }

        return switch self {
        case .userCaches:
            [caches]
        case .userLogs:
            [folder(library, "Logs")]
        case .trash:
            [folder(home, ".Trash")]
        case .languageVersions:
            // Папки версий менеджеров: удаляется версия целиком, как это делают сами менеджеры.
            ToolCatalog.versionManagers.flatMap { $0.versionFolders(home) }
        case .simulatorRuntimes, .xcodeApplications, .homebrew, .installedApplications, .appLeftovers,
             .docker, .conda, .macPorts, .ollama, .simulatorDyldCaches, .applicationSupportCaches, .downloadedInstallers:
            // Кэши dyld — в `/Library`, их удаляет simctl; кэши в Application Support и установщики — узкими
            // правилами стража: ни `Application Support`, ни `Downloads` целиком корнями не становятся.
            []
        case .simulators:
            [folder(developer, "CoreSimulator/Devices")]
        case .xcodeDerivedData:
            [folder(xcode, "DerivedData")]
        case .xcodeDeviceSupport:
            ["iOS", "watchOS", "tvOS", "visionOS", "macOS"].map { folder(xcode, "\($0) DeviceSupport") }
        case .xcodeArchives:
            [folder(xcode, "Archives")]
        case .swiftUIPreviews:
            [folder(xcode, "UserData/Previews")]
        case .documentationCache:
            [folder(xcode, "DocumentationCache")]
        case .packageCaches:
            [folder(caches, "org.swift.swiftpm"), folder(caches, "CocoaPods"), folder(caches, "org.carthage.CarthageKit")]
        case .xcodeCaches:
            [folder(caches, "com.apple.dt.Xcode"), folder(developer, "CoreSimulator/Caches"), folder(developer, "XCTestDevices")]
        case .xcodeLogs:
            [folder(xcode, "iOS Device Logs"), folder(xcode, "DeviceLogs"), folder(library, "Logs/CoreSimulator")]
        case .xcodeProducts:
            [folder(xcode, "Products")]
        case .androidSDK:
            [folder(library, "Android/sdk"), folder(home, ".android/avd")]
        case .gradle:
            ["caches", "wrapper/dists", "daemon"].map { folder(home, ".gradle/\($0)") }
        case .toolCaches:
            ToolCatalog.caches.map { folder(home, $0.path) }
        case .terminalPrograms:
            [folder(home, ".local/bin"), folder(home, ".cargo/bin"), folder(home, "go/bin")]
        case .backgroundServices:
            [folder(library, "LaunchAgents")]
        }
    }

    /// Подпись элемента по папке-корню, в которой он найден, — для категорий из нескольких корней.
    func rootLabel(forRootNamed name: String) -> String? {
        switch (self, name) {
        case (.packageCaches, "org.swift.swiftpm"): "Swift Package Manager"
        case (.packageCaches, "CocoaPods"): "CocoaPods"
        case (.packageCaches, "org.carthage.CarthageKit"): "Carthage"
        case (.xcodeCaches, "com.apple.dt.Xcode"): "Кэш Xcode"
        case (.xcodeCaches, "Caches"): "Кэш симуляторов"
        case (.xcodeCaches, "XCTestDevices"): "Клоны симуляторов для параллельных тестов"
        case (.xcodeLogs, "iOS Device Logs"), (.xcodeLogs, "DeviceLogs"): "Логи устройств"
        case (.xcodeLogs, "CoreSimulator"): "Журналы симуляторов"
        case (.gradle, "caches"): "Кэш зависимостей Gradle"
        case (.gradle, "dists"): "Дистрибутив Gradle"
        case (.gradle, "daemon"): "Логи демона Gradle"
        case (.toolCaches, _): ToolCatalog.cache(forRootNamed: name)?.tool
        default: nil
        }
    }

    /// Предупреждение для корня, где лежит не только кэш: такие элементы показываются, но сами не отмечаются.
    /// Решение пользователя 2026-10-12 по ревью раздела «Терминал»; сами предупреждения — в `ToolCatalog`.
    func rootWarning(forRootNamed name: String) -> String? {
        self == .toolCaches ? ToolCatalog.cache(forRootNamed: name)?.warning : nil
    }

    /// Элементы, которые не показываются и никогда не удаляются.
    func isExcluded(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        // Служебные метки папок: `CACHEDIR.TAG` — стандартная пометка «здесь кэш».
        if name == ".DS_Store" || name == ".localized" || name == "CACHEDIR.TAG" {
            return true
        }
        // Что лежит внутри кэша, но кэшем не является: у Bun это `links` — глобальное хранилище пакетов проектов.
        if self == .toolCaches, ToolCatalog.cache(forRootNamed: url.deletingLastPathComponent().lastPathComponent)?.keeps.contains(name) == true {
            return true
        }
        // Собственный кэш приложения не трогаем.
        if self == .userCaches, let bundleID = Bundle.main.bundleIdentifier, name == bundleID {
            return true
        }
        return false
    }
}
