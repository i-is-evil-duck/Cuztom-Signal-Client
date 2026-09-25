import Foundation
import UserNotifications

/// Local macOS notifications for messages and incoming calls.
///
/// Signal messages arrive through the app's websocket, so these are local
/// notifications rather than APNs notifications. Keeping this in the app
/// target avoids making the core package depend on AppKit/UserNotifications.
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = NotificationManager()

    private let center = UNUserNotificationCenter.current()
    private let defaultsKey = "notificationsEnabled"
    private let previewDefaultsKey = "showNotificationPreviews"

    private override init() {
        super.init()
    }

    var enabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: defaultsKey) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: defaultsKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: defaultsKey)
        }
    }

    /// Lock-screen/message-banner content is opt-in. Keep the default false so
    /// a notification never becomes an accidental plaintext message archive.
    var showMessagePreviews: Bool {
        get { UserDefaults.standard.bool(forKey: previewDefaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: previewDefaultsKey) }
    }

    func configure() {
        center.delegate = self
    }

    @discardableResult
    func requestAuthorization() async -> Bool {
        configure()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied:
            return false
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        @unknown default:
            return false
        }
    }

    func notifyMessage(
        threadID: String,
        conversationTitle: String,
        senderName: String,
        body: String,
        storeTs: Int64?
    ) {
        guard enabled else { return }
        let content = UNMutableNotificationContent()
        if showMessagePreviews {
            let safeSender = senderName.isEmpty || senderName == "Unknown" ? "New message" : senderName
            content.title = conversationTitle.isEmpty ? safeSender : conversationTitle
            if conversationTitle.isEmpty || safeSender != conversationTitle {
                content.subtitle = safeSender
            }
            content.body = body.isEmpty ? "[Attachment]" : String(body.prefix(240))
        } else {
            content.title = "New message"
            content.body = "Open Cuztom Signal to read it"
        }
        content.sound = .default
        content.threadIdentifier = threadID
        content.userInfo = ["thread": threadID]

        let stamp = storeTs.map(String.init) ?? UUID().uuidString
        let request = UNNotificationRequest(
            identifier: "message:\(threadID):\(stamp)",
            content: content,
            trigger: nil
        )
        center.add(request)
    }

    func cancelAll() {
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
    }

    func notifyIncomingCall(callerName: String, conversationTitle: String, identifier: String) {
        guard enabled else { return }
        let content = UNMutableNotificationContent()
        if showMessagePreviews {
            content.title = "Incoming \(conversationTitle.isEmpty ? "call" : conversationTitle)"
            content.body = callerName.isEmpty ? "Incoming voice call" : "Incoming voice call from \(callerName)"
        } else {
            content.title = "Incoming call"
            content.body = "Open Cuztom Signal to view the call"
        }
        content.sound = .default
        content.categoryIdentifier = "INCOMING_CALL"
        center.add(
            UNNotificationRequest(
                identifier: "call:\(identifier)",
                content: content,
                trigger: nil
            )
        )
    }

    func cancelIncomingCall(identifier: String) {
        center.removePendingNotificationRequests(withIdentifiers: ["call:\(identifier)"])
        center.removeDeliveredNotifications(withIdentifiers: ["call:\(identifier)"])
    }

    // Show banners even when the main window is currently active.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
