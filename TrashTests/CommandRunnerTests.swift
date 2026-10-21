import Foundation
import Testing
@testable import Trash

/// Настоящий запуск безвредных утилит `/bin/echo` и `/bin/sleep`: проверяется сам механизм процессов.
struct CommandRunnerTests {
    @Test func returnsStandardOutput() async throws {
        let output = try await CommandRunner.system.run("/bin/echo", ["hello"])

        #expect(String(decoding: output, as: UTF8.self) == "hello\n")
    }

    @Test func nonZeroExitIsAnError() async {
        await #expect(throws: CommandRunner.Failure.self) {
            try await CommandRunner.system.run("/bin/sh", ["-c", "exit 3"])
        }
    }

    /// Для `lsof`: вывод вместе с ошибками и при любом коде выхода.
    @Test func answersWithAnyStatusKeepsOutputAndErrors() async throws {
        let runner = CommandRunner.system(timeout: .seconds(30), answersWithAnyStatus: true)
        let output = try await runner.run("/bin/sh", ["-c", "echo found; echo broken >&2; exit 1"])

        #expect(String(decoding: output, as: UTF8.self) == "found\nbroken\n")
    }

    @Test func hungCommandIsTerminatedByTimeout() async {
        let clock = ContinuousClock()
        let started = clock.now

        await #expect(throws: CommandRunner.Failure.self) {
            try await CommandRunner.system(timeout: .milliseconds(300)).run("/bin/sleep", ["10"])
        }
        #expect(clock.now - started < .seconds(5), "скан не должен ждать зависшую команду")
    }
}
