import AppKit

/// Перемещение программы в Корзину. В приложении — `NSWorkspace.recycle`, а программу, которую macOS не дал
/// переместить по правам, — через Finder: он спрашивает пароль администратора, как при перетаскивании вручную.
/// В тестах подменяется, чтобы не трогать настоящую Корзину.
struct Recycler: Sendable {
    let recycle: @Sendable (URL) async throws -> Void
    /// Запасной путь при отказе по правам. Тоже только в Корзину; `nil` — запасного пути нет.
    var recycleWithPassword: (@Sendable (URL) async throws -> Void)?

    static let workspace = Recycler(
        recycle: { url in try await recycleOnMainActor(url) },
        recycleWithPassword: { url in try await FinderTrash.delete(url) }
    )

    /// В Корзину; при отказе по правам — запасным путём. Удалить навсегда этот путь не может.
    /// - Parameter asksPassword: `false` — пароль в этой очистке уже отменили, повторно не спрашиваем.
    func moveToTrash(_ url: URL, asksPassword: Bool = true) async throws {
        do {
            try await recycle(url)
        } catch {
            guard Self.isPermissionDenied(error), let recycleWithPassword else { throw error }
            // Ссылку Finder с правами администратора мог бы раскрыть и переложить то, на что она указывает.
            guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true else { throw error }
            guard asksPassword else { throw FinderTrashError.cancelled }
            try await recycleWithPassword(url)
        }
    }

    /// Отказ по правам: программа принадлежит root, например поставлена из App Store.
    static func isPermissionDenied(_ error: any Error) -> Bool {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain, error.code == NSFileWriteNoPermissionError {
            return true
        }
        if error.domain == NSPOSIXErrorDomain, error.code == Int(EACCES) || error.code == Int(EPERM) {
            return true
        }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? any Error {
            return isPermissionDenied(underlying)
        }
        return false
    }

    @MainActor
    private static func recycleOnMainActor(_ url: URL) async throws {
        _ = try await NSWorkspace.shared.recycle([url])
    }
}

/// Удаляет найденные элементы. Каждый путь перед удалением проверяется через `SafetyGuard`;
/// программы и остатки удалённых программ — ещё и свежей перепроверкой состояния программ.
struct Cleaner: Sendable {
    let safetyGuard: SafetyGuard
    /// Свежий каталог программ — перед удалением остатков: вдруг программу поставили после скана.
    var catalog: @Sendable () -> ApplicationCatalog = {
        ApplicationCatalog.scan(system: SystemLocations(), home: FileManager.default.homeDirectoryForCurrentUser, environment: .live)
    }
    var isRunning: @Sendable (URL) -> Bool = ApplicationEnvironment.live.isRunning
    var recycler: Recycler = .workspace
    /// Рантаймы, симуляторы и Homebrew — через их менеджер.
    var remover = ManagerRemover()
    /// Шаги от root — одним скриптом с паролем администратора; в тестах — обычный `sh` во временной папке.
    var administrator: @Sendable (String) async throws -> String = { script in try await AdministratorScript.run(script) }
    var administratorTools = AdministratorScript.Tools()
    /// Системные папки — какие из них требуют пароля администратора.
    var system = SystemLocations()
    /// Держит ли какой-то процесс открытыми файлы в папке: `true` — программа запущена, `nil` — не понять.
    /// Кэш Chromium удаляется только у закрытой программы: иначе она пишет в удалённые файлы и место не вернётся.
    var hasOpenFiles: @Sendable (URL) async -> Bool? = { folder in
        // `lsof` выходит с 1 и когда открытых файлов нет, и когда нашёл их, но часть папки не прочитал: решаем
        // по выводу. `-t` глушит предупреждения, поэтому любой вывод — PID или ошибка — значит «не трогать».
        // Запуск напрямую: тайм-аут останавливает сам `lsof`; по папке на десятки тысяч файлов он идёт секунды.
        guard FileManager.default.isExecutableFile(atPath: Self.lsof),
              let output = try? await CommandRunner.system(timeout: .seconds(60), answersWithAnyStatus: true)
                  .run(Self.lsof, ["-t", "+D", folder.path])
        else { return nil }
        return !output.isEmpty
    }
    static let lsof = "/usr/sbin/lsof"
    /// Активна ли версия языка — свежая проверка перед удалением, по тем же правилам, что отметка при скане.
    var versionActivity: @Sendable (URL) -> ToolCatalog.VersionActivity = {
        ToolCatalog.activity(ofVersionAt: $0, home: FileManager.default.homeDirectoryForCurrentUser)
    }

    /// - Parameter permanently: `false` — переместить в Корзину, `true` — удалить навсегда.
    ///   Элементы категорий с `alwaysDeletesPermanently` всегда удаляются навсегда, программы — всегда в Корзину,
    ///   элементы с операцией менеджера — командой менеджера, сразу и без Корзины.
    @concurrent
    func clean(_ items: [ScanItem], permanently: Bool) async -> CleanupReport {
        var report = CleanupReport()
        // Один свежий каталог на всю очистку и только если есть остатки.
        let freshCatalog = items.contains { $0.category == .appLeftovers } ? catalog() : nil
        // Папки без симулятора — по свежему списку `simctl`: симулятор, созданный после скана, «сиротой» не станет.
        let knownSimulators: Set<String>? = if items.contains(where: { $0.category == .simulators && $0.removal == nil }) {
            await remover.simulators().map { Set($0.map(\.udid)) }
        } else {
            nil
        }
        // Версии MacPorts — по свежему списку неактивных: активированную после скана не удаляем.
        let inactivePorts: Set<String>? = if items.contains(where: { if case .portUninstall = $0.removal { true } else { false } }) {
            await remover.inactivePorts()
        } else {
            nil
        }
        // Кэши в данных программ — только у закрытых программ: папка программы проверяется прямо перед её первым
        // кэшем — перед ним могли идти долгие команды менеджеров — и один раз на очистку.
        var busyPrograms: [String: Bool?] = [:]
        // Отменили пароль у одной программы — остальные программы root этой очистки пароль не спрашивают.
        var isPasswordDeclined = false
        // Одна команда менеджера на группу элементов; её итог — для всех элементов группы.
        var outcomes: [ManagerRemoval: Result<Void, any Error>] = [:]

        // Шаги от root копятся и выполняются одним скриптом в конце: пароль спрашивается один раз.
        var administratorSteps: [(item: ScanItem, step: AdministratorScript.Step)] = []

        for item in Self.ordered(items) {
            if item.category == .applicationSupportCaches, let applicationSupport = safetyGuard.applicationSupport,
               let program = OtherDataScanner.programFolder(of: SafetyGuard.normalized(item.url), applicationSupport: applicationSupport),
               busyPrograms[program.path] == nil {
                busyPrograms[program.path] = .some(await hasOpenFiles(program))
            }
            if let refusal = refusal(for: item, catalog: freshCatalog, knownSimulators: knownSimulators, inactivePorts: inactivePorts)
                ?? programRefusal(for: item, busyPrograms: busyPrograms) {
                report.failures.append(.init(url: item.url, title: item.title, reason: refusal))
                continue
            }
            if let step = administratorStep(for: item) {
                administratorSteps.append((item, step))
                continue
            }

            do {
                if let removal = item.removal {
                    let outcome: Result<Void, any Error>
                    if let previous = outcomes[removal] {
                        outcome = previous
                    } else {
                        do {
                            let paths = items.filter { $0.removal == removal }.map(\.url)
                            try await remover.remove(removal, paths: paths)
                            outcome = .success(())
                        } catch {
                            outcome = .failure(error)
                        }
                        outcomes[removal] = outcome
                    }
                    try outcome.get()
                    // `brew` удаляет файлы по путям элементов: что осталось на месте, то не удалено.
                    if removal.isCheckedByPath, FileManager.default.fileExists(atPath: item.url.path) {
                        throw CleanerError.leftInPlace
                    }
                    report.removedByManagers += 1
                } else if item.category.isApplicationBundle {
                    do {
                        try await recycler.moveToTrash(item.url, asksPassword: !isPasswordDeclined)
                    } catch let error as FinderTrashError where error.isCancelled {
                        isPasswordDeclined = true
                        throw error
                    }
                    report.movedToTrash += 1
                } else {
                    let isPermanent = permanently || item.category.alwaysDeletesPermanently
                    // Эмулятор — `<имя>.ini` и папка: ini первым — при сбое на папке Android Studio не покажет
                    // сломанный эмулятор, а папка найдётся при следующем скане.
                    for url in Self.companions(of: item) + [item.url] {
                        if isPermanent {
                            try FileManager.default.removeItem(at: url)
                        } else {
                            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                        }
                    }
                    if isPermanent {
                        report.deletedPermanently += 1
                    } else {
                        report.movedToTrash += 1
                    }
                }
                report.removed.append(item.url)
                report.freedBytes += item.size
            } catch {
                report.failures.append(.init(url: item.url, title: item.title, reason: error.localizedDescription))
            }
        }

        if !administratorSteps.isEmpty {
            await runAsAdministrator(administratorSteps, into: &report)
        }
        return report
    }

    /// Шаг от root — только для системных папок, куда нельзя писать: `/usr/local/bin`, `/Library/LaunchDaemons`,
    /// MacPorts от root. Решается в момент удаления. Папка — физический путь: скрипт сверит его с `pwd -P`.
    private func administratorStep(for item: ScanItem) -> AdministratorScript.Step? {
        guard AdministratorScript.isNeeded(for: item, system: administratorLocations) else { return nil }
        let folder = Self.physicalPath(item.url.deletingLastPathComponent())
        let name = item.url.lastPathComponent
        switch item.category {
        case .terminalPrograms:
            return folder.map { .removeBrokenLink(folder: $0, name: name) }
        case .backgroundServices:
            // Метку и программу проверил `refusal`; под root они проверятся ещё раз.
            let service = TerminalScanner.service(at: item.url)
            guard let folder, let label = service.label, let program = service.program else { return nil }
            return .removeService(folder: folder, name: name, label: label, program: program)
        case .macPorts:
            // Подделанное имя или версия — не в скрипт: путь без root откажет с «неверным идентификатором».
            guard case let .portUninstall(portName, version) = item.removal,
                  ManagerRemover.isPortName(portName), ManagerRemover.isPortVersion(version) else { return nil }
            return .uninstallPort(port: remover.port.path, name: portName, version: version)
        default:
            return nil
        }
    }

    /// Кэш программы, которая запущена или про которую не понять, запущена ли она.
    private func programRefusal(for item: ScanItem, busyPrograms: [String: Bool?]) -> String? {
        guard item.category == .applicationSupportCaches else { return nil }
        guard let applicationSupport = safetyGuard.applicationSupport,
              let program = OtherDataScanner.programFolder(of: SafetyGuard.normalized(item.url), applicationSupport: applicationSupport),
              let isBusy = busyPrograms[program.path] ?? nil else {
            return "Не понять, запущена ли программа, — кэш не трогаем"
        }
        return isBusy ? "Программа запущена — закройте её и повторите" : nil
    }

    /// Системные папки, а MacPorts — тот, с которым работает `remover`.
    private var administratorLocations: SystemLocations {
        var locations = system
        locations.macPortsPrefix = remover.macPortsPrefix
        return locations
    }

    /// Реальный путь без ссылок — как `pwd -P`: `/var` → `/private/var`.
    static func physicalPath(_ url: URL) -> String? {
        guard let resolved = realpath(url.path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Один скрипт на все шаги. Отменили пароль или скрипт не запустился — все шаги в отказах с причиной;
    /// отмена пароля Finder на эти шаги не влияет, и наоборот.
    private func runAsAdministrator(_ steps: [(item: ScanItem, step: AdministratorScript.Step)], into report: inout CleanupReport) async {
        let outcomes: [AdministratorScript.Outcome?]
        do {
            let output = try await administrator(AdministratorScript.script(for: steps.map(\.step), tools: administratorTools))
            outcomes = AdministratorScript.outcomes(from: output, count: steps.count)
        } catch AdministratorScriptError.cancelled {
            report.failures += steps.map { .init(url: $0.item.url, title: $0.item.title, reason: AdministratorScriptError.cancelled.localizedDescription) }
            return
        } catch {
            // Скрипт прервали — часть шагов могла выполниться: ссылки и plist, которых больше нет, — удалены.
            outcomes = steps.map { item, step in
                if case .uninstallPort = step { return nil }
                var info = stat()
                return lstat(item.url.path, &info) != 0 && errno == ENOENT ? .done : nil
            }
            for ((item, _), outcome) in zip(steps, outcomes) where outcome == nil {
                report.failures.append(.init(url: item.url, title: item.title, reason: error.localizedDescription))
            }
            record(zip(steps, outcomes).filter { $0.1 != nil }, into: &report)
            return
        }
        record(Array(zip(steps, outcomes)), into: &report)
    }

    private func record(_ results: [((item: ScanItem, step: AdministratorScript.Step), AdministratorScript.Outcome?)], into report: inout CleanupReport) {
        for ((item, step), outcome) in results {
            switch outcome {
            case .done:
                report.removed.append(item.url)
                report.freedBytes += item.size
                if case .uninstallPort = step {
                    report.removedByManagers += 1
                } else {
                    report.deletedPermanently += 1
                }
            case .changed:
                report.failures.append(.init(url: item.url, title: item.title, reason: "Изменилось после скана — не тронуто, пересканируйте"))
            case let .failed(code):
                report.failures.append(.init(url: item.url, title: item.title, reason: "Не удалось удалить с правами администратора (код \(code))"))
            case nil:
                report.failures.append(.init(url: item.url, title: item.title, reason: "Нет ответа о результате — проверьте вручную"))
            }
        }
    }

    /// Симуляторы раньше рантаймов, эмуляторы Android раньше образов: рантайм и образ нельзя удалить, пока ими
    /// пользуется симулятор или эмулятор из этой же очистки; контейнеры Docker — последними. Остальной порядок сохраняется.
    static func ordered(_ items: [ScanItem]) -> [ScanItem] {
        func rank(_ item: ScanItem) -> Int {
            if item.category == .androidSDK {
                return item.url.pathExtension == "avd" ? 0 : 1
            }
            // Образы Docker раньше контейнеров: иначе `image prune -a` снёс бы и образы только что удалённых
            // контейнеров, которых не было в оценке строки.
            return switch item.removal {
            case .simulator: 0
            case .runtime, .dockerPrune(.containers): 2
            default: 1
            }
        }
        return items.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
    }

    /// Файлы, которые удаляются вместе с элементом: `<имя>.ini` эмулятора Android — рядом с папкой `.avd`.
    /// Что это обычный файл, проверил страж в `refusal`.
    private static func companions(of item: ScanItem) -> [URL] {
        guard item.category == .androidSDK, item.url.pathExtension == "avd" else { return [] }
        let config = item.url.deletingPathExtension().appendingPathExtension("ini")
        return FileManager.default.fileExists(atPath: config.path) ? [config] : []
    }

    /// Причина не удалять элемент или `nil`, если удалять можно.
    private func refusal(for item: ScanItem, catalog: ApplicationCatalog?, knownSimulators: Set<String>?, inactivePorts: Set<String>?) -> String? {
        guard item.category.isDeletable else {
            return "Удаление этой категории пока не поддерживается"
        }
        guard item.isDeletable else {
            return "Этот элемент приложение не удаляет — например, встроенный рантайм или явно поставленный пакет"
        }
        guard !item.url.pathComponents.contains("..") else {
            return "Путь вне разрешённых папок"
        }
        // Удаляет менеджер, а не файлы: вместо корней — операция своего раздела, а идентификатор
        // и свежее состояние проверяет `ManagerRemover`.
        if let removal = item.removal {
            guard removal.category == item.category else { return "Операция не своего раздела — удаление отменено" }
            // Удаляется то, чья это папка: операция не может указывать на чужой симулятор или окружение.
            if case let .simulator(udid) = removal, item.url.lastPathComponent != udid {
                return "Операция не совпадает с элементом — удаление отменено"
            }
            if case let .condaRemoveEnvironment(_, prefix) = removal, item.url.standardizedFileURL.path != URL(filePath: prefix).standardizedFileURL.path {
                return "Операция не совпадает с элементом — удаление отменено"
            }
            if case let .dyldCacheRemove(runtimeIdentifier, build) = removal, item.url.lastPathComponent != "\(runtimeIdentifier).\(build)" {
                return "Операция не совпадает с элементом — удаление отменено"
            }
            if case let .portUninstall(name, version) = removal {
                guard let inactivePorts else { return "port не ответил — версии не трогаем" }
                if !inactivePorts.contains("\(name)@\(version)") {
                    return "Версия снова активна или уже удалена — не трогаем"
                }
                // От root запускается `port`: если его может переписать пользователь, root выполнил бы чужое.
                let port = remover.port
                if AdministratorScript.isNeeded(for: item, system: administratorLocations),
                   FileManager.default.isWritableFile(atPath: port.path) || FileManager.default.isWritableFile(atPath: port.deletingLastPathComponent().path) {
                    return "Права MacPorts смешаны — удалите вручную: sudo port uninstall"
                }
            }
            return nil
        }
        if item.category == .terminalPrograms, !TerminalScanner.isBrokenLink(item.url) {
            return "Ссылка снова ведёт на программу или это не ссылка — не трогаем"
        }
        // Своя папка без права записи — не root: её права мог поменять кто угодно, root шёл бы по подменённому пути.
        if item.category == .terminalPrograms || item.category == .backgroundServices,
           !FileManager.default.isWritableFile(atPath: item.url.deletingLastPathComponent().path),
           !AdministratorScript.isNeeded(for: item, system: administratorLocations) {
            return "Нет права записи в папку — удалите вручную"
        }
        // Страж проверяет нормализованный путь, а удаляется `item.url` — пути с `..` отсечены выше.
        guard safetyGuard.canDelete(item.url, as: item.category) else {
            return "Путь вне разрешённых папок"
        }
        if item.category.isApplicationBundle, isRunning(item.url) {
            return "Программа запущена — закройте её и повторите"
        }
        if item.category == .appLeftovers {
            guard let catalog, let kind = safetyGuard.leftoverKind(of: item.url), let owner = LeftoverPolicy.owner(ofEntryNamed: item.url.lastPathComponent, kind: kind) else {
                return "Не удалось определить, чья это программа"
            }
            if LeftoverPolicy.status(of: owner, in: catalog) == .installed {
                return "Программа снова установлена — её данные не трогаем"
            }
        }
        if item.category == .simulators {
            guard let knownSimulators else {
                return "simctl не ответил — папку без симулятора не трогаем"
            }
            if knownSimulators.contains(item.url.lastPathComponent) {
                return "simctl теперь знает этот симулятор — пересканируйте"
            }
        }
        if item.category == .androidSDK {
            if item.url.pathExtension == "avd" {
                if AndroidEmulators.isRunning(item.url) {
                    return "Эмулятор запущен — закройте его и повторите"
                }
                let config = item.url.deletingPathExtension().appendingPathExtension("ini")
                // Есть что-то на месте ini — даже битая ссылка, — и это не обычный файл: не трогаем ничего.
                if (try? FileManager.default.attributesOfItem(atPath: config.path)) != nil, !safetyGuard.canDeleteEmulatorConfig(config) {
                    return "Рядом с эмулятором не обычный файл \(config.lastPathComponent) — удалите вручную"
                }
            } else if let image = AndroidEmulators.imagePath(of: item.url) {
                guard let avds = safetyGuard.androidAVDs, let used = AndroidEmulators.usedImages(in: avds) else {
                    return "Не прочитать эмуляторы — какой образ им нужен, неизвестно"
                }
                if used.contains(image) {
                    return "Образ нужен эмулятору — сначала удалите эмулятор"
                }
            }
        }
        if item.category == .backgroundServices {
            let service = TerminalScanner.service(at: item.url)
            guard let label = service.label, ManagerRemover.isServiceLabel(label) else {
                return "Не понять имя службы — не трогаем"
            }
            if !service.isProgramMissing {
                return "Программа службы снова на месте — службу не трогаем"
            }
        }
        if item.category == .languageVersions {
            switch versionActivity(item.url) {
            case .active: return "Это активная версия — сначала переключитесь на другую"
            case .unknown: return "Активную версию не определить — удалите через менеджер"
            case .inactive: break
            }
        }
        return nil
    }
}

/// Ошибки `Cleaner`, которые не пришли из системы.
enum CleanerError: LocalizedError {
    case leftInPlace

    var errorDescription: String? {
        switch self {
        case .leftInPlace: "Менеджер оставил это на месте"
        }
    }
}
