import Foundation
import Testing
@testable import Trash

/// Скрипт шагов от root исполняется обычным `sh` во временной папке: проверяются кавычки и перепроверки
/// под root. `port` подменён записывающим скриптом — настоящий не запускается.
struct AdministratorScriptTests {
    let base: URL

    init() throws {
        let temporary = FileManager.default.temporaryDirectory
            .appending(path: "TrashAdministratorScriptTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        // Физический путь, как его видит `pwd -P`: `/var` → `/private/var`.
        base = URL(filePath: try #require(Cleaner.physicalPath(temporary)), directoryHint: .isDirectory)
    }

    @Test func brokenLinkIsRemovedOnlyWhileStillBroken() async throws {
        defer { cleanUp() }
        let name = "it's a \"link\" $HOME"
        let file = base.appending(path: "file")
        try FileManager.default.createSymbolicLink(atPath: base.appending(path: name).path, withDestinationPath: "/nonexistent/program")
        try Data().write(to: file)
        // Ссылка ожила после скана: цель снова есть — не трогаем ни её, ни цель.
        try FileManager.default.createSymbolicLink(atPath: base.appending(path: "alive").path, withDestinationPath: file.path)

        let outcomes = try await run([name, "alive", "file"].map { .removeBrokenLink(folder: base.path, name: $0) })

        #expect(outcomes == [.done, .changed, .changed])
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: base.appending(path: name).path)) == nil, "битая ссылка удалена")
        #expect(FileManager.default.fileExists(atPath: base.appending(path: "alive").path) && FileManager.default.fileExists(atPath: file.path))
    }

    /// Папку подменили ссылкой на другую после проверки стража — root туда не идёт.
    @Test func swappedFolderIsNotFollowed() async throws {
        defer { cleanUp() }
        let checked = base.appending(path: "bin")
        let other = base.appending(path: "other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: other.appending(path: "gone").path, withDestinationPath: "/nonexistent/x")
        try FileManager.default.createSymbolicLink(atPath: checked.path, withDestinationPath: other.path)

        let outcomes = try await run([.removeBrokenLink(folder: checked.path, name: "gone")])

        #expect(outcomes == [.changed])
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: other.appending(path: "gone").path)) != nil)
    }

    @Test func serviceIsRemovedOnlyWithSameLabelAndNoProgram() async throws {
        defer { cleanUp() }
        let program = base.appending(path: "program")
        try Data().write(to: program)
        try writePlist(["Label": "com.example.gone"], to: base.appending(path: "gone.plist"))
        try writePlist(["Label": "com.example.other"], to: base.appending(path: "renamed.plist"))
        try writePlist(["Label": "com.example.back"], to: base.appending(path: "back.plist"))
        try FileManager.default.createSymbolicLink(atPath: base.appending(path: "link.plist").path, withDestinationPath: base.appending(path: "gone.plist").path)

        let service = { (name: String, label: String, program: String) in
            AdministratorScript.Step.removeService(folder: base.path, name: name, label: label, program: program)
        }
        let outcomes = try await run([
            service("link.plist", "com.example.gone", "/nonexistent/gone"),
            service("renamed.plist", "com.example.renamed", "/nonexistent/gone"),
            // Программу поставили снова, пока открыт запрос пароля.
            service("back.plist", "com.example.back", program.path),
            service("gone.plist", "com.example.gone", "/nonexistent/gone"),
        ])

        #expect(outcomes == [.changed, .changed, .changed, .done], "ссылка, чужая метка и программа на месте — не тронуты")
        #expect(!FileManager.default.fileExists(atPath: base.appending(path: "gone.plist").path))
        #expect(FileManager.default.fileExists(atPath: base.appending(path: "renamed.plist").path)
                && FileManager.default.fileExists(atPath: base.appending(path: "back.plist").path))
    }

    @Test func portUninstallReportsItsStatus() async throws {
        defer { cleanUp() }
        let log = base.appending(path: "port.log")
        let good = try recorder(named: "port", log: log, status: 0)
        let bad = try recorder(named: "port-failing", log: log, status: 3)

        let outcomes = try await run([
            .uninstallPort(port: good.path, name: "libfoo", version: "1.0_0+universal"),
            .uninstallPort(port: bad.path, name: "libbar", version: "2.0_1"),
        ])

        #expect(outcomes == [.done, .failed(3)])
        #expect(try String(contentsOf: log, encoding: .utf8) == "-N uninstall libfoo @1.0_0+universal\n-N uninstall libbar @2.0_1\n")
    }

    @Test func statusAndErrorsAreParsed() async throws {
        let outcomes = AdministratorScript.outcomes(from: "noise\n1 done\n7 done\n0 failed 2", count: 3)
        #expect(outcomes == [.failed(2), .done, nil])
        #expect(AdministratorScript.appleScriptLiteral(#"a "b" \c"#) == #""a \"b\" \\c""#)

        // `osascript` подменён: ошибку AppleScript скрипт возвращает строкой.
        let answer = { (text: String) in CommandRunner { _, _ in Data(text.utf8) } }
        await #expect(throws: AdministratorScriptError.cancelled) { try await AdministratorScript.run("true", runner: answer("trash-administrator-error -128\n")) }
        await #expect(throws: AdministratorScriptError.cancelled) { try await AdministratorScript.run("true", runner: answer("trash-administrator-error -60006\n")) }
        await #expect(throws: AdministratorScriptError.failed(code: 5)) { try await AdministratorScript.run("true", runner: answer("trash-administrator-error 5\n")) }
        #expect(try await AdministratorScript.run("true", runner: answer("0 done\n")) == "0 done\n")
    }

    // MARK: - Helpers

    /// Исполнение скрипта, как сделал бы `do shell script`, но без пароля и без root.
    private func run(_ steps: [AdministratorScript.Step]) async throws -> [AdministratorScript.Outcome?] {
        let output = try await CommandRunner.system.run("/bin/sh", ["-c", AdministratorScript.script(for: steps)])
        return AdministratorScript.outcomes(from: String(decoding: output, as: UTF8.self), count: steps.count)
    }

    /// Скрипт, который дописывает свои аргументы в журнал и выходит с заданным кодом.
    private func recorder(named name: String, log: URL, status: Int32) throws -> URL {
        let url = base.appending(path: name)
        try Data("#!/bin/sh\necho \"$*\" >> \(AdministratorScript.quoted(log.path))\nexit \(status)\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func writePlist(_ values: [String: Any], to url: URL) throws {
        try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0).write(to: url)
    }

    private func cleanUp() {
        try? FileManager.default.removeItem(at: base)
    }
}
