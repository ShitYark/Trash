import Foundation

/// Симулятор из `simctl list devices -j`.
struct SimulatorDevice: Sendable, Equatable {
    let udid: String
    let name: String
    let runtimeIdentifier: String
    let state: String
    let isAvailable: Bool
    let lastUsedAt: Date?

    var isBooted: Bool { state == "Booted" }
}

/// Рантайм из `simctl runtime list -j`.
struct SimulatorRuntime: Sendable, Equatable {
    let identifier: String
    let runtimeIdentifier: String
    let version: String
    let build: String?
    let sizeBytes: Int64
    let isDeletable: Bool
    let lastUsedAt: Date?
    let mountPath: String?
    /// Путь к `.simruntime`; у рантаймов «Legacy Download» нет `mountPath`, но есть он.
    let bundlePath: String?
}

/// Разбор JSON-вывода `simctl`. Только чтение — ничего не запускает и не удаляет.
enum SimulatorCatalog {
    static let listDevicesArguments = ["list", "devices", "-j"]
    static let listRuntimesArguments = ["runtime", "list", "-j"]
    /// `simctl list runtimes -j`: какие рантаймы эта macOS поддерживает — `isAvailable` и сборка.
    static let listRuntimeAvailabilityArguments = ["list", "runtimes", "-j"]

    /// Доступность рантайма и причина недоступности от `simctl`.
    struct Availability: Equatable, Sendable {
        let isAvailable: Bool
        let error: String?
    }

    /// Доступность рантаймов по ключу `<runtimeIdentifier>.<сборка>` — так названы папки их кэшей dyld.
    static func availability(from data: Data) throws -> [String: Availability] {
        let list = try JSONDecoder().decode(AvailabilityList.self, from: data)
        return Dictionary(list.runtimes.compactMap { runtime in
            runtime.buildversion.map {
                ("\(runtime.identifier).\($0)", Availability(isAvailable: runtime.isAvailable ?? false, error: runtime.availabilityError))
            }
        }, uniquingKeysWith: { first, _ in first })
    }

    static func devices(from data: Data) throws -> [SimulatorDevice] {
        let list = try JSONDecoder().decode(DeviceList.self, from: data)
        return list.devices.flatMap { runtimeIdentifier, devices in
            devices.map { device in
                SimulatorDevice(
                    udid: device.udid,
                    name: device.name,
                    runtimeIdentifier: runtimeIdentifier,
                    state: device.state,
                    isAvailable: device.isAvailable ?? true,
                    lastUsedAt: device.lastUsedAt.flatMap(date)
                )
            }
        }
    }

    static func runtimes(from data: Data) throws -> [SimulatorRuntime] {
        let list = try JSONDecoder().decode([String: RuntimeEntry].self, from: data)
        return list.map { key, entry in
            SimulatorRuntime(
                identifier: entry.identifier ?? key,
                runtimeIdentifier: entry.runtimeIdentifier ?? "",
                version: entry.version ?? "",
                build: entry.build,
                sizeBytes: entry.sizeBytes ?? 0,
                isDeletable: entry.deletable ?? false,
                lastUsedAt: entry.lastUsedAt.flatMap(date),
                mountPath: entry.mountPath,
                bundlePath: entry.runtimeBundlePath ?? entry.path
            )
        }
    }

    /// `com.apple.CoreSimulator.SimRuntime.iOS-27-0` → `iOS 27.0`.
    static func displayName(ofRuntime runtimeIdentifier: String) -> String {
        let name = runtimeIdentifier.split(separator: ".").last.map(String.init) ?? runtimeIdentifier
        var parts = name.split(separator: "-").map(String.init)
        guard let platform = parts.first else { return runtimeIdentifier }
        parts.removeFirst()
        let displayPlatform = platform == "xrOS" ? "visionOS" : platform
        return parts.isEmpty ? displayPlatform : "\(displayPlatform) \(parts.joined(separator: "."))"
    }

    /// Платформа рантайма: `com.apple.CoreSimulator.SimRuntime.iOS-27-0` → `iOS`.
    static func platform(ofRuntime runtimeIdentifier: String) -> String {
        displayName(ofRuntime: runtimeIdentifier).split(separator: " ").first.map(String.init) ?? ""
    }

    private static func date(_ string: String) -> Date? {
        (try? Date(string, strategy: .iso8601))
            ?? (try? Date(string, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
    }
}

private struct DeviceList: Decodable {
    struct Device: Decodable {
        let udid: String
        let name: String
        let state: String
        let isAvailable: Bool?
        let lastUsedAt: String?
    }

    let devices: [String: [Device]]
}

private struct AvailabilityList: Decodable {
    struct Runtime: Decodable {
        let identifier: String
        let buildversion: String?
        let isAvailable: Bool?
        let availabilityError: String?
    }

    let runtimes: [Runtime]
}

private struct RuntimeEntry: Decodable {
    let identifier: String?
    let runtimeIdentifier: String?
    let version: String?
    let build: String?
    let sizeBytes: Int64?
    let deletable: Bool?
    let lastUsedAt: String?
    let mountPath: String?
    let runtimeBundlePath: String?
    let path: String?
}
