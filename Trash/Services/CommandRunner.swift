import Foundation

/// Запуск системных утилит (`simctl`, `xcode-select`). В тестах подменяется заготовленными ответами,
/// чтобы тесты не зависели от установленного Xcode и не трогали симуляторы пользователя.
struct CommandRunner: Sendable {
    enum Failure: Error {
        case exitStatus(Int32)
        case timedOut
    }

    /// Возвращает стандартный вывод команды; ненулевой код выхода или таймаут — ошибка.
    let run: @Sendable (_ executable: String, _ arguments: [String]) async throws -> Data

    static let system = system(timeout: .seconds(30))

    /// Зависшая команда завершается по таймауту, иначе скан никогда не закончится и кнопки останутся неактивными.
    /// - Parameter answersWithAnyStatus: вывод вместе с ошибками и при любом коде выхода — для `lsof`, который
    ///   выходит с 1 и тогда, когда нашёл файлы. Тайм-аут и сбой запуска — по-прежнему ошибка.
    static func system(timeout: Duration, answersWithAnyStatus: Bool = false) -> CommandRunner {
        CommandRunner { executable, arguments in
            try await runProcess(executable, arguments, timeout: timeout, answersWithAnyStatus: answersWithAnyStatus)
        }
    }

    @concurrent
    private static func runProcess(_ executable: String, _ arguments: [String], timeout: Duration, answersWithAnyStatus: Bool) async throws -> Data {
        try Task.checkCancellation()
        let process = RunningProcess(executable: executable, arguments: arguments, answersWithAnyStatus: answersWithAnyStatus)
        let output = try process.start()

        let watchdog = Task.detached {
            guard (try? await Task.sleep(for: timeout)) != nil else { return }
            process.terminate(timedOut: true)
        }
        defer { watchdog.cancel() }

        // Читаем до конца до ожидания выхода: иначе большой вывод заполнит буфер канала и процесс зависнет.
        let data = await withTaskCancellationHandler {
            output.readDataToEndOfFile()
        } onCancel: {
            process.terminate(timedOut: false)
        }
        try process.waitForSuccess()
        return data
    }
}

/// `Process` для сторожа таймаута и обработчика отмены: оба вызывают `terminate` из других потоков.
/// Состояние защищено замком, `Process.terminate()` потокобезопасен.
private final class RunningProcess: @unchecked Sendable {
    private let process = Process()
    private let lock = NSLock()
    private let answersWithAnyStatus: Bool
    private var didTimeOut = false

    init(executable: String, arguments: [String], answersWithAnyStatus: Bool) {
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        self.answersWithAnyStatus = answersWithAnyStatus
    }

    func start() throws -> FileHandle {
        let output = Pipe()
        process.standardOutput = output
        process.standardError = answersWithAnyStatus ? output : FileHandle.nullDevice
        try process.run()
        return output.fileHandleForReading
    }

    func terminate(timedOut: Bool) {
        lock.withLock {
            didTimeOut = didTimeOut || timedOut
            if process.isRunning {
                process.terminate()
            }
        }
    }

    func waitForSuccess() throws {
        process.waitUntilExit()
        if lock.withLock({ didTimeOut }) {
            throw CommandRunner.Failure.timedOut
        }
        guard answersWithAnyStatus || process.terminationStatus == 0 else {
            throw CommandRunner.Failure.exitStatus(process.terminationStatus)
        }
    }
}
