import Foundation

/// Эмуляторы Android (AVD): какие образы им нужны и запущены ли они. Общее для скана и для перепроверки
/// перед удалением. Эмулятор — папка `<имя>.avd` в `~/.android/avd` или папка из `path=` в `<имя>.ini` рядом.
enum AndroidEmulators {
    struct AVD {
        let url: URL
        let name: String
        /// `system-images/android-36/google_apis/arm64-v8a` — без завершающего `/`.
        let imagePath: String?
        /// Какой образ нужен эмулятору, известно: `config.ini` прочитан и в нём есть `image.sysdir.1` с `system-images/`.
        let isImageKnown: Bool
    }

    /// `nil` — папка эмуляторов есть, но не читается — нет прав, битая ссылка, не папка: использование образов неизвестно.
    /// Пустой список — только когда папки нет вовсе.
    static func read(in directory: URL, accessDenied: inout Bool) -> [AVD]? {
        switch CleanupScanner.list(directory, accessDenied: &accessDenied) {
        case .missing:
            var info = stat()
            return lstat(directory.path, &info) != 0 && errno == ENOENT ? [] : nil
        case .denied:
            return nil
        case let .children(entries):
            // Папки эмуляторов: свои `.avd` и те, на что указывает `path=` в `<имя>.ini`, — они бывают и вне папки.
            var folders = entries.filter { $0.pathExtension == "avd" }
            var known = Set(folders.map(\.canonicalFileURL.path))
            for config in entries where config.pathExtension == "ini" {
                guard let path = values(in: config)["path"] else { continue }
                let folder = URL(filePath: path, directoryHint: .isDirectory)
                if known.insert(folder.canonicalFileURL.path).inserted {
                    folders.append(folder)
                }
            }
            return folders.map { avd in
                let config = try? String(contentsOf: avd.appending(path: "config.ini"), encoding: .utf8)
                let settings = config.map(parse) ?? [:]
                let imagePath = settings["image.sysdir.1"].flatMap(systemImagePath)
                return AVD(url: avd, name: settings["avd.ini.displayname"] ?? avd.deletingPathExtension().lastPathComponent,
                           imagePath: imagePath, isImageKnown: imagePath != nil)
            }
        }
    }

    /// Образы, нужные эмуляторам, по свежему чтению. `nil` — папку эмуляторов или образ хоть одного из них
    /// не определить: тогда образ не удаляется.
    static func usedImages(in directory: URL) -> Set<String>? {
        var isDenied = false
        guard let avds = read(in: directory, accessDenied: &isDenied), !isDenied, avds.allSatisfy(\.isImageKnown) else { return nil }
        return Set(avds.compactMap(\.imagePath))
    }

    /// Путь образа как в `image.sysdir.1`: `system-images/<api>/<tag>/<abi>`; не образ — `nil`.
    static func imagePath(of url: URL) -> String? {
        let components = url.standardizedFileURL.pathComponents
        guard components.count >= 5, components[components.count - 4] == "system-images" else { return nil }
        return components.suffix(4).joined(separator: "/")
    }

    /// Запущен ли эмулятор. Пока он работает, в папке `.avd` лежит `hardware-qemu.ini.lock` — запасной
    /// `userdata-qemu.img.lock` — с его PID, а `multiinstance.lock` занят `flock`: ядро снимает блокировку
    /// вместе с процессом. Лок, который не прочитать, — считаем запущенным.
    static func isRunning(_ avd: URL) -> Bool {
        for name in ["hardware-qemu.ini.lock", "userdata-qemu.img.lock"] {
            let lock = avd.appending(path: name)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: lock.path, isDirectory: &isDirectory) else { continue }
            guard !isDirectory.boolValue, let text = try? String(contentsOf: lock, encoding: .utf8),
                  let pid = Int32(text.trimmingCharacters(in: CharacterSet.decimalDigits.inverted)), pid > 0 else { return true }
            // Лок после сбоя остаётся — живой ли процесс, проверяет ядро.
            if kill(pid, 0) == 0 || errno == EPERM {
                return true
            }
        }
        return isLocked(avd.appending(path: "multiinstance.lock"))
    }

    /// Файл занят `flock` другим открытием — разделяемой или исключительной блокировкой: проба исключительной
    /// без ожидания, сразу отпускается.
    private static func isLocked(_ file: URL) -> Bool {
        let descriptor = open(file.path, O_RDONLY)
        guard descriptor >= 0 else { return errno != ENOENT }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { return true }
        flock(descriptor, LOCK_UN)
        return false
    }

    /// `ключ=значение` по строкам.
    private static func parse(_ text: String) -> [String: String] {
        Dictionary(text.split(whereSeparator: \.isNewline).compactMap { line -> (String, String)? in
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            return parts.count == 2 ? (parts[0], parts[1]) : nil
        }, uniquingKeysWith: { first, _ in first })
    }

    private static func values(in file: URL) -> [String: String] {
        (try? String(contentsOf: file, encoding: .utf8)).map(parse) ?? [:]
    }

    /// `system-images/android-36/google_apis/arm64-v8a/` или абсолютный путь с ним → без `/` в конце.
    private static func systemImagePath(_ value: String) -> String? {
        guard let start = value.range(of: "system-images/") else { return nil }
        let path = value[start.lowerBound...]
        return String(path.hasSuffix("/") ? path.dropLast() : path)
    }
}
