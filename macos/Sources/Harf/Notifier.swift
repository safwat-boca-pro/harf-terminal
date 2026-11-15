import AppKit
import UserNotifications

/// Desktop notifications a program asks for (OSC 9, OSC 777). The core has already stripped control characters and bidi
/// overrides from the text and cut it to length. Shown only when the user is not already looking at the terminal.
@MainActor
enum Notifier {
    static func post(title: String, body: String, focused: Bool) {
        switch Settings.shared.notifications {
        case 2: return                                                     // off
        case 1: break                                                      // always
        default: if focused { return }                                      // unfocused: the user is already looking at that terminal
        }
        guard Bundle.main.bundleIdentifier != nil else { return }   // not running as an app bundle: no notification center
        let heading = title.isEmpty ? "Harf" : title
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { @Sendable granted, error in   // asks once; later calls just answer. Called on a UserNotifications queue, so it must not be main-actor isolated (it crashed the app once, docs/logging.md)
            guard granted else { Log.info("notification not shown: not authorized\(error.map { " (\($0.localizedDescription))" } ?? "")"); return }
            let content = UNMutableNotificationContent()
            content.title = heading
            content.body = body
            if heading != "Harf" { content.subtitle = "Harf" }   // text from a program must say which terminal it came from
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) { error in
                if let error { Log.warn("notification: \(error.localizedDescription)") }
            }
        }
    }
}
