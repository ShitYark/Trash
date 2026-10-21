import CoreServices
import Foundation

/// Перемещение в Корзину через Finder — для программ, которые принадлежат root, например из App Store.
/// Finder спрашивает пароль администратора, как при перетаскивании в Корзину вручную, и программу можно вернуть.
/// При первом вызове macOS спрашивает, можно ли Trash управлять Finder.
enum FinderTrash {
    /// Сколько ждать, пока пользователь введёт пароль.
    static let timeout: TimeInterval = 600

    @concurrent
    static func delete(_ url: URL) async throws {
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kAECoreSuite),
            eventID: AEEventID(kAEDelete),
            targetDescriptor: NSAppleEventDescriptor(bundleIdentifier: "com.apple.finder"),
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        event.setParam(NSAppleEventDescriptor(fileURL: url), forKeyword: AEKeyword(keyDirectObject))

        let reply: NSAppleEventDescriptor
        do {
            // `canInteract` — без него Finder может не показать запрос пароля и сразу отказать.
            reply = try event.sendEvent(options: [.waitForReply, .canInteract], timeout: timeout)
        } catch {
            throw FinderTrashError(code: (error as NSError).code)
        }
        if let code = reply.paramDescriptor(forKeyword: AEKeyword(keyErrorNumber))?.int32Value, code != 0 {
            throw FinderTrashError(code: Int(code))
        }
    }
}

/// Ошибка Finder — причина в отчёте об очистке.
struct FinderTrashError: LocalizedError {
    /// Пользователь отменил запрос пароля.
    static let cancelled = FinderTrashError(code: -128)

    let code: Int

    var isCancelled: Bool { code == Self.cancelled.code }

    var errorDescription: String? {
        switch code {
        case Self.cancelled.code:
            "Пароль администратора не введён — удаление отменено"
        case -1743:
            "Нет разрешения управлять Finder — включите его для Trash: Системные настройки → Конфиденциальность и безопасность → Автоматизация"
        case -1712:
            "Finder не ответил вовремя — проверьте Корзину и повторите"
        default:
            "Finder не смог переместить программу в Корзину (код \(code))"
        }
    }
}
