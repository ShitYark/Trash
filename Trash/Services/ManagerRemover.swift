import Foundation

/// Удаление через менеджер: только фиксированные команды `simctl`, `brew`, `docker`, `conda` и запрос к Ollama,
/// аргумент — только проверенный идентификатор. Перед командой состояние перечитывается: включённый симулятор
/// и рантайм, которым пользуются симуляторы, не удаляются; `brew cleanup` сначала пробуется вхолостую и запускается,
/// только если удалит ровно отмеченное. Это своя защита пути, где файлы удаляет не `Cleaner`, а менеджер.
struct ManagerRemover: Sendable {
    /// Переменные окружения передаются через `/usr/bin/env`: запуск команд передаёт только аргументы.
    static let env = "/usr/bin/env"
    /// `brew uninstall` по умолчанию сам удаляет ставшие ненужными зависимости — без этого удалилось бы неотмеченное.
    static let brewEnvironment = ["HOMEBREW_NO_AUTOREMOVE=1", "HOMEBREW_NO_AUTO_UPDATE=1", "HOMEBREW_NO_ENV_HINTS=1"]

    /// Удаление рантайма и `brew cleanup` бывают долгими — 30 секунд скана тут мало.
    var runner: CommandRunner = .system(timeout: .seconds(300))
    /// `simctl` активного Xcode — тот же, что при скане; запускается напрямую, без `xcrun`.
    var simctl: @Sendable () async -> String? = { await XcodeScanner.simctlPath(runner: .system) }
    var brew: @Sendable () -> String? = { SystemLocations().homebrewPrefix.map { $0.appending(path: "bin/brew").path } }
    /// Кэш загрузок Homebrew: его файлы `brew cleanup` удаляет вместе со старыми версиями — это допустимо.
    var homebrewCache = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Caches/Homebrew", directoryHint: .isDirectory)
    var docker: @Sendable () -> String? = {
        TerminalScanner.dockerCLI(home: FileManager.default.homeDirectoryForCurrentUser, system: SystemLocations())?.path
    }
    var dockerHost = TerminalScanner.dockerHost(home: FileManager.default.homeDirectoryForCurrentUser)
    /// MacPorts: `bin/port` и `var/macports` — по своей ли папке решать, нужен ли пароль.
    var macPortsPrefix = SystemLocations().macPortsPrefix
    /// Запрос к серверу Ollama — через системный `curl`: он есть всегда, а ответ — только код HTTP.
    static let curl = "/usr/bin/curl"
    static let ollamaDeleteURL = "http://127.0.0.1:11434/api/delete"

    /// Симуляторы по свежему `simctl list`; `nil` — список не получен.
    func simulators() async -> [SimulatorDevice]? {
        guard let simctl = await simctl(),
              let data = try? await runner.run(simctl, SimulatorCatalog.listDevicesArguments) else { return nil }
        return try? SimulatorCatalog.devices(from: data)
    }

    /// - Parameter paths: пути всех отмеченных элементов этой операции — `brew cleanup` обязан удалить ровно их.
    func remove(_ removal: ManagerRemoval, paths: [URL]) async throws {
        switch removal {
        case let .simulator(udid):
            guard UUID(uuidString: udid) != nil else { throw ManagerRemovalError.invalidIdentifier }
            let (simctl, devices) = try await simctlWithDevices()
            guard let device = devices.first(where: { $0.udid == udid }) else { throw ManagerRemovalError.simulatorGone }
            // Только выключенный: `Booting` и `Shutting Down` тоже заняты.
            guard device.state == "Shutdown" else { throw ManagerRemovalError.simulatorNotShutdown(device.state) }
            try await run(simctl, ["delete", udid])

        case let .runtime(identifier, runtimeIdentifier):
            guard UUID(uuidString: identifier) != nil, Self.isRuntimeIdentifier(runtimeIdentifier) else {
                throw ManagerRemovalError.invalidIdentifier
            }
            let (simctl, devices) = try await simctlWithDevices()
            guard !devices.contains(where: { $0.runtimeIdentifier == runtimeIdentifier }) else {
                throw ManagerRemovalError.runtimeInUse
            }
            try await run(simctl, ["runtime", "delete", identifier])

        case let .brewUninstall(formula):
            guard Self.isFormulaName(formula) else { throw ManagerRemovalError.invalidIdentifier }
            guard let brew = brew() else { throw ManagerRemovalError.noBrew }
            // С `--force` brew закрепление не проверяет и снимает молча — закрепили после скана, значит, не удаляем.
            // Закрепление — ссылка `<префикс>/var/homebrew/pinned/<формула>`, бывает и битой.
            let pin = URL(filePath: brew).deletingLastPathComponent().deletingLastPathComponent()
                .appending(path: "var/homebrew/pinned").appending(path: formula)
            guard (try? FileManager.default.attributesOfItem(atPath: pin.path)) == nil else { throw ManagerRemovalError.formulaPinned }
            // `--force` — все версии формулы: отмечены они все, отметки связаны.
            try await run(Self.env, Self.brewEnvironment + [brew, "uninstall", "--formula", "--force", formula])

        case let .brewCleanup(formula):
            guard Self.isFormulaName(formula) else { throw ManagerRemovalError.invalidIdentifier }
            guard let brew = brew() else { throw ManagerRemovalError.noBrew }
            let preview = try await output(Self.env, Self.brewEnvironment + [brew, "cleanup", "--dry-run", formula])
            guard Self.cleanupRemovesExactly(Set(paths.map(\.standardizedFileURL.path)), preview: preview,
                                             formula: formula, cache: homebrewCache) else {
                throw ManagerRemovalError.cleanupMismatch(formula: formula)
            }
            try await run(Self.env, Self.brewEnvironment + [brew, "cleanup", formula])

        case let .dockerPrune(target):
            guard let docker = docker() else { throw ManagerRemovalError.noDocker }
            try await run(docker, dockerHost + Self.dockerArguments(target))

        case let .condaRemoveEnvironment(conda, prefix):
            // `--all` по пути: путь обязан быть окружением в `envs`, а не базой и не чем-то ещё.
            guard Self.isCondaExecutable(conda), Self.isCondaEnvironment(prefix) else { throw ManagerRemovalError.invalidIdentifier }
            try await run(conda, ["remove", "-p", prefix, "--all", "-y"])

        case let .condaClean(conda):
            guard Self.isCondaExecutable(conda) else { throw ManagerRemovalError.invalidIdentifier }
            try await run(conda, ["clean", "--all", "-y"])

        case let .ollamaDelete(model):
            guard Self.isOllamaModelName(model) else { throw ManagerRemovalError.invalidIdentifier }
            try await deleteOllamaModel(model)

        case let .dyldCacheRemove(runtimeIdentifier, build):
            guard Self.isRuntimeIdentifier(runtimeIdentifier), Self.isBuild(build) else { throw ManagerRemovalError.invalidIdentifier }
            let (simctl, devices) = try await simctlWithDevices()
            // Кэш запущенного симулятора не трогаем: рантайм им пользуется прямо сейчас.
            guard !devices.contains(where: { $0.runtimeIdentifier == runtimeIdentifier && $0.state != "Shutdown" }) else {
                throw ManagerRemovalError.runtimeBusy
            }
            try await run(simctl, ["runtime", "dyld_shared_cache", "remove", "\(runtimeIdentifier)/\(build)"])

        case let .portUninstall(name, version):
            // Сюда — только своя установка MacPorts; от root её удаляет `AdministratorScript`.
            guard Self.isPortName(name), Self.isPortVersion(version) else { throw ManagerRemovalError.invalidIdentifier }
            try await run(port.path, ["-N", "uninstall", name, "@" + version])
        }
    }

    var port: URL { macPortsPrefix.appending(path: "bin/port") }

    /// MacPorts поставлен без root — в папку, куда можно писать: тогда `port` работает без пароля.
    var isMacPortsOwnedByUser: Bool {
        FileManager.default.isWritableFile(atPath: macPortsPrefix.appending(path: "var/macports").path)
    }

    /// Неактивные версии по свежему `port installed inactive` — без пароля: `имя@версия`. `nil` — `port` не ответил.
    func inactivePorts() async -> Set<String>? {
        guard let data = try? await runner.run(port.path, ["installed", "inactive"]) else { return nil }
        return Set(TerminalScanner.inactivePorts(String(decoding: data, as: UTF8.self)).map { "\($0.name)@\($0.version)" })
    }

    /// Метка `launchd`: `com.example.agent` — буквы, цифры, `._-`, с буквы или цифры.
    static func isServiceLabel(_ value: String) -> Bool {
        isPlainName(value, extra: "._-", maxLength: 256)
    }

    /// Имя порта MacPorts: `libfoo`, `py312-numpy`, `gtk+3`.
    static func isPortName(_ value: String) -> Bool {
        isPlainName(value, extra: "._+-", maxLength: 128)
    }

    /// Версия порта как в `port installed`: `1.0_1`, `2.1.2_1+universal`.
    static func isPortVersion(_ value: String) -> Bool {
        isPlainName(value, extra: "._+-", maxLength: 128)
    }

    private static func isPlainName(_ value: String, extra: String, maxLength: Int) -> Bool {
        guard let first = value.unicodeScalars.first, CharacterSet.alphanumerics.contains(first), value.count <= maxLength,
              !value.contains("..") else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: extra))
        return value.unicodeScalars.allSatisfy { $0.isASCII && allowed.contains($0) }
    }

    /// `-a` у образов и кэша сборки — то, что `docker system df` считает освобождаемым. Тома — никогда.
    static func dockerArguments(_ target: ManagerRemoval.DockerTarget) -> [String] {
        switch target {
        case .containers: ["container", "prune", "-f"]
        case .images: ["image", "prune", "-a", "-f"]
        case .buildCache: ["builder", "prune", "-a", "-f"]
        }
    }

    /// `<база>/bin/conda`, где база — установка conda: в ней есть `conda-meta`.
    static func isCondaExecutable(_ path: String) -> Bool {
        let url = URL(filePath: path).standardizedFileURL
        let base = url.deletingLastPathComponent().deletingLastPathComponent()
        return path.hasPrefix("/") && !path.contains("..") && url.lastPathComponent == "conda"
            && url.deletingLastPathComponent().lastPathComponent == "bin"
            && isDirectory(base.appending(path: "conda-meta")) && FileManager.default.isExecutableFile(atPath: url.path)
    }

    /// Окружение — папка прямо в `envs` с `conda-meta`; база в `envs` не лежит. Не ссылка, не скрытая.
    static func isCondaEnvironment(_ path: String) -> Bool {
        let url = URL(filePath: path)
        let isLink = (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
        return path.hasPrefix("/") && !path.contains("..") && !isLink && !url.lastPathComponent.hasPrefix(".")
            && url.deletingLastPathComponent().lastPathComponent == "envs" && isDirectory(url.appending(path: "conda-meta"))
    }

    /// Имя модели как в `ollama list`: `llama3:8b`, `user/model:q4_K_M`, `host.example/ns/model:tag`.
    static func isOllamaModelName(_ value: String) -> Bool {
        guard let first = value.unicodeScalars.first, CharacterSet.alphanumerics.contains(first), value.count <= 256,
              !value.contains("..") else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._:/-_"))
        return value.unicodeScalars.allSatisfy { $0.isASCII && allowed.contains($0) }
    }

    /// `com.apple.CoreSimulator.SimRuntime.iOS-17-5`.
    static func isRuntimeIdentifier(_ value: String) -> Bool {
        value.hasPrefix("com.apple.CoreSimulator.SimRuntime.") && value.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }
    }

    /// Сборка рантайма: `20A360`, `24A94401` — буквы и цифры.
    static func isBuild(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 32 && value.unicodeScalars.allSatisfy { $0.isASCII && CharacterSet.alphanumerics.contains($0) }
    }

    /// Имя формулы: `node`, `python@3.12`, `libxml++3`. Ни пробелов, ни ключей вроде `--force`, ни путей.
    static func isFormulaName(_ value: String) -> Bool {
        guard let first = value.unicodeScalars.first, CharacterSet.alphanumerics.contains(first) else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "@+._-"))
        return value.unicodeScalars.allSatisfy { $0.isASCII && allowed.contains($0) }
    }

    /// Вывод `brew cleanup --dry-run`: «Would remove: <путь> (<размер>)». Версии формулы в `Cellar` должны совпасть
    /// с отмеченными, остальное — только файлы кэша загрузок.
    static func cleanupRemovesExactly(_ expected: Set<String>, preview: String, formula: String, cache: URL) -> Bool {
        let prefix = "Would remove: "
        let paths = preview.split(separator: "\n").compactMap { line -> String? in
            guard line.hasPrefix(prefix) else { return nil }
            let rest = line.dropFirst(prefix.count)
            let path = rest.range(of: " (", options: .backwards).map { String(rest[..<$0.lowerBound]) } ?? String(rest)
            return URL(filePath: path).standardizedFileURL.path
        }
        let cachePath = cache.standardizedFileURL.path + "/"
        var kegs = Set<String>()
        for path in paths {
            let url = URL(filePath: path)
            if url.deletingLastPathComponent().lastPathComponent == formula,
               url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "Cellar" {
                kegs.insert(path)
            } else if !path.hasPrefix(cachePath) {
                return false
            }
        }
        return !kegs.isEmpty && kegs == expected
    }

    /// `curl` выводит только код ответа: 200 — удалено, 404 — модели уже нет; не соединился — Ollama не запущена.
    private func deleteOllamaModel(_ model: String) async throws {
        let body = String(decoding: (try? JSONSerialization.data(withJSONObject: ["model": model], options: [.withoutEscapingSlashes])) ?? Data(), as: UTF8.self)
        // `-q` первым — без `~/.curlrc`; без прокси — запрос только к этому Mac.
        let arguments = ["-q", "--noproxy", "*", "--silent", "--max-time", "60", "--request", "DELETE", "--header", "Content-Type: application/json",
                         "--data-binary", body, "--output", "/dev/null", "--write-out", "%{http_code}", Self.ollamaDeleteURL]
        let status: String
        do {
            status = String(decoding: try await runner.run(Self.curl, arguments), as: UTF8.self)
        } catch CommandRunner.Failure.exitStatus(7) {
            throw ManagerRemovalError.ollamaNotRunning
        } catch CommandRunner.Failure.timedOut {
            throw ManagerRemovalError.timedOut
        } catch CommandRunner.Failure.exitStatus(let code) {
            throw ManagerRemovalError.failed(tool: "curl", status: code)
        }
        switch status.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "200": return
        case "404": throw ManagerRemovalError.ollamaModelGone
        case let other: throw ManagerRemovalError.ollamaRejected(other)
        }
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func simctlWithDevices() async throws -> (String, [SimulatorDevice]) {
        guard let simctl = await simctl() else { throw ManagerRemovalError.noSimctl }
        guard let data = try? await runner.run(simctl, SimulatorCatalog.listDevicesArguments),
              let devices = try? SimulatorCatalog.devices(from: data) else { throw ManagerRemovalError.simctlFailed }
        return (simctl, devices)
    }

    private func run(_ executable: String, _ arguments: [String]) async throws {
        _ = try await output(executable, arguments)
    }

    private func output(_ executable: String, _ arguments: [String]) async throws -> String {
        // Для сообщения — сам инструмент, а не `env`.
        let tool = URL(filePath: executable == Self.env ? (arguments.first { $0.hasPrefix("/") } ?? executable) : executable).lastPathComponent
        do {
            return String(decoding: try await runner.run(executable, arguments), as: UTF8.self)
        } catch CommandRunner.Failure.timedOut {
            throw ManagerRemovalError.timedOut
        } catch CommandRunner.Failure.exitStatus(let status) {
            throw ManagerRemovalError.failed(tool: tool, status: status)
        }
    }
}

/// Причина отказа или ошибки — строка в отчёте об очистке.
enum ManagerRemovalError: LocalizedError, Equatable {
    case invalidIdentifier
    case noSimctl
    case simctlFailed
    case simulatorGone
    case simulatorNotShutdown(String)
    case runtimeInUse
    case runtimeBusy
    case noBrew
    case formulaPinned
    case cleanupMismatch(formula: String)
    case noDocker
    case ollamaNotRunning
    case ollamaModelGone
    case ollamaRejected(String)
    case timedOut
    case failed(tool: String, status: Int32)

    var errorDescription: String? {
        switch self {
        case .invalidIdentifier: "Неверный идентификатор — удаление отменено"
        case .noSimctl: "Не нашёл simctl активного Xcode"
        case .simctlFailed: "simctl не ответил — повторите позже"
        case .simulatorGone: "Симулятора уже нет"
        case let .simulatorNotShutdown(state): "Симулятор не выключен (\(state)) — остановите его и повторите"
        case .runtimeInUse: "Рантаймом пользуются симуляторы — сначала удалите их"
        case .runtimeBusy: "Симулятор этого рантайма запущен — остановите его и повторите"
        case .noBrew: "Не нашёл Homebrew"
        case .formulaPinned: "Пакет закреплён (brew pin) — не удаляем"
        case let .cleanupMismatch(formula):
            "brew cleanup удалил бы не ровно отмеченное — проверьте вручную: brew cleanup --dry-run \(formula)"
        case .timedOut: "Команда не уложилась в 5 минут — проверьте вручную"
        case .noDocker: "Не нашёл команду docker"
        case .ollamaNotRunning: "Ollama не запущена — запустите её и повторите"
        case .ollamaModelGone: "Этой модели в Ollama уже нет"
        case let .ollamaRejected(status): "Ollama отказала (ответ \(status))"
        case let .failed(tool, status) where tool == "brew":
            "brew завершился с ошибкой (код \(status)) — например, пакет ещё кому-то нужен"
        case let .failed(tool, status) where tool == "docker":
            "docker завершился с ошибкой (код \(status)) — запущен ли Docker Desktop?"
        case let .failed(tool, status) where tool == "conda":
            "conda завершилась с ошибкой (код \(status)) — например, не хватает прав"
        case let .failed(tool, status): "\(tool) завершился с ошибкой (код \(status))"
        }
    }
}
