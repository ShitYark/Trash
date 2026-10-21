import Foundation

/// Шаги очистки от root — одним `sh`-скриптом на всю очистку: macOS спрашивает пароль один раз, кэш авторизации
/// действует только для того же скрипта (TN2065). Каждый шаг под root заново проверяет, что удаляет то самое,
/// и печатает строку статуса `<номер> done|changed|failed [код]`. Вывод команд в статус не попадает.
enum AdministratorScript {
    enum Step: Equatable, Sendable {
        /// `rm` самой ссылки `<папка>/<имя>`, только если она всё ещё битая.
        case removeBrokenLink(folder: String, name: String)
        /// `rm` plist `<папка>/<имя>`, только если это всё ещё обычный файл с той же меткой, а программы службы нет.
        /// Службу не выгружаем: по метке можно снять другую, живую службу; без программы эта и так не запустится.
        case removeService(folder: String, name: String, label: String, program: String)
        /// `port -N uninstall <порт> @<версия>`.
        case uninstallPort(port: String, name: String, version: String)
    }

    enum Outcome: Equatable, Sendable {
        case done
        /// Под root оказалось не то, что проверяли: ссылка ожила, plist подменили, программа на месте — не тронуто.
        case changed
        case failed(Int32)
    }

    /// Утилиты по абсолютным путям: окружение процесса от root не подтверждено. В тестах подменяются.
    struct Tools: Sendable {
        var plutil = "/usr/bin/plutil"
    }

    /// Пароль ввести и шаги выполнить — не дольше 10 минут: зависший `port` не должен держать очистку вечно.
    static let timeout = Duration.seconds(600)
    static let osascript = "/usr/bin/osascript"

    /// Нужен ли root: элемент в системной папке, куда нельзя писать, — `/usr/local/bin`, `/Library/LaunchAgents`,
    /// `/Library/LaunchDaemons`, MacPorts от root. Своя папка без права записи — не root: её права мог поменять
    /// и не администратор, а root работал бы по подменённому пути. Общее для окна очистки и `Cleaner`.
    static func isNeeded(for item: ScanItem, system: SystemLocations) -> Bool {
        let folder = item.url.deletingLastPathComponent()
        let isLocked = !FileManager.default.isWritableFile(atPath: folder.path)
        let isFolder = { (candidate: URL) in folder.canonicalFileURL.path == candidate.canonicalFileURL.path }
        switch item.category {
        case .terminalPrograms:
            return isLocked && isFolder(system.usrLocal.appending(path: "bin"))
        case .backgroundServices:
            return isLocked && ["LaunchAgents", "LaunchDaemons"].contains { isFolder(system.library.appending(path: $0)) }
        case .macPorts:
            return item.removal != nil
                && !FileManager.default.isWritableFile(atPath: system.macPortsPrefix.appending(path: "var/macports").path)
        default:
            return false
        }
    }

    static func script(for steps: [Step], tools: Tools = Tools()) -> String {
        var lines = ["PATH=/usr/bin:/bin:/usr/sbin:/sbin; export PATH"]
        for (index, step) in steps.enumerated() {
            switch step {
            case let .removeBrokenLink(folder, name):
                // В подоболочке: `cd -P` и сверка реального пути — папку не подменить ссылкой после проверки стража.
                lines.append("(" + enter(folder, index) + " n=\(quoted(name)); "
                    + "if [ -L \"./$n\" ] && [ ! -e \"./$n\" ]; then \(remove(index)); else echo \"\(index) changed\"; fi)")
            case let .removeService(folder, name, label, program):
                lines.append("(" + enter(folder, index) + " n=\(quoted(name)); l=\(quoted(label)); g=\(quoted(program)); "
                    + "if [ -f \"./$n\" ] && [ ! -L \"./$n\" ] && [ ! -e \"$g\" ] && [ ! -L \"$g\" ] "
                    + "&& [ \"$(\(quoted(tools.plutil)) -extract Label raw -o - \"./$n\" 2>/dev/null)\" = \"$l\" ]; "
                    + "then \(remove(index)); else echo \"\(index) changed\"; fi)")
            case let .uninstallPort(port, name, version):
                lines.append("if \(quoted(port)) -N uninstall \(quoted(name)) \(quoted("@" + version)) >/dev/null 2>&1; "
                    + "then echo \"\(index) done\"; else echo \"\(index) failed $?\"; fi")
            }
        }
        // Статус каждого шага — в выводе; ненулевой код скрипта `do shell script` превратил бы в ошибку без вывода.
        lines.append("exit 0")
        return lines.joined(separator: "\n")
    }

    /// Итог каждого шага по строкам статуса; шаг без строки — `nil`.
    static func outcomes(from output: String, count: Int) -> [Outcome?] {
        var result = [Outcome?](repeating: nil, count: count)
        for line in output.split(whereSeparator: \.isNewline) {
            let words = line.split(separator: " ")
            guard words.count >= 2, let index = Int(words[0]), result.indices.contains(index) else { continue }
            switch words[1] {
            case "done": result[index] = .done
            case "changed": result[index] = .changed
            case "failed": result[index] = .failed(words.count > 2 ? Int32(words[2]) ?? -1 : -1)
            default: continue
            }
        }
        return result
    }

    /// Строка для `sh` в одинарных кавычках — как `quoted form of` в AppleScript: `'` → `'\''`.
    static func quoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Строковый литерал AppleScript: `\` → `\\`, `"` → `\"`.
    static func appleScriptLiteral(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// AppleScript с `do shell script … with administrator privileges`. Ошибку — отмену пароля, отказ —
    /// AppleScript сам возвращает строкой: `osascript` пишет её в stderr, а его запуск stderr не читает.
    static func appleScript(for script: String) -> String {
        """
        try
            return do shell script \(appleScriptLiteral(script)) with administrator privileges without altering line endings
        on error errorMessage number errorNumber
            return "\(errorPrefix)" & errorNumber
        end try
        """
    }

    /// Запуск через `osascript` в фоне: окно не замирает, зависший скрипт прерывается по тайм-ауту.
    static func run(_ script: String, runner: CommandRunner = .system(timeout: timeout)) async throws -> String {
        let output: String
        do {
            output = String(decoding: try await runner.run(osascript, ["-e", appleScript(for: script)]), as: UTF8.self)
        } catch CommandRunner.Failure.timedOut {
            throw AdministratorScriptError.timedOut
        } catch CommandRunner.Failure.exitStatus(let status) {
            throw AdministratorScriptError.failed(code: Int(status))
        }
        let trimmed = output.trimmingCharacters(in: .newlines)
        if trimmed.hasPrefix(errorPrefix) {
            let code = Int(trimmed.dropFirst(errorPrefix.count)) ?? 0
            // Отмену разные версии macOS сообщают как -128 или -60006 (`errAuthorizationCanceled`).
            throw code == -128 || code == -60006 ? AdministratorScriptError.cancelled : AdministratorScriptError.failed(code: code)
        }
        return output
    }

    private static let errorPrefix = "trash-administrator-error "

    private static func enter(_ folder: String, _ index: Int) -> String {
        "cd -P -- \(quoted(folder)) 2>/dev/null && [ \"$(pwd -P)\" = \(quoted(folder)) ] || { echo \"\(index) changed\"; exit 0; };"
    }

    private static func remove(_ index: Int) -> String {
        "if /bin/rm -f -- \"./$n\"; then echo \"\(index) done\"; else echo \"\(index) failed $?\"; fi"
    }
}

enum AdministratorScriptError: LocalizedError, Equatable {
    case cancelled
    case timedOut
    case failed(code: Int)

    var errorDescription: String? {
        switch self {
        case .cancelled: "Пароль администратора не введён — удаление отменено"
        case .timedOut: "Удаление с паролем администратора не уложилось в 10 минут — проверьте вручную"
        case let .failed(code): "Не удалось выполнить с правами администратора (код \(code))"
        }
    }
}
