import Foundation
import UserNotifications

final class NotificationManager: NSObject, ObservableObject, UNUserNotificationCenterDelegate {

    override init() {
        super.init()
        // Must set delegate before requestAuthorization, so foreground
        // notifications are shown while the app is active.
        UNUserNotificationCenter.current().delegate = self
    }

    // Show banner + play sound even when the app is in the foreground
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .badge])
    }

    func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error { dlog("Notification auth error: \(error)") }
            if !granted { dlog("⚠️ Notification permission denied — check Settings > SecurityCam > Notifications") }
        }
    }

    func sendMotionAlert() {
        let content = UNMutableNotificationContent()
        content.title = "Motion Detected"
        content.body = "Your security camera detected movement."
        content.sound = .defaultCritical
        content.interruptionLevel = .timeSensitive

        let request = UNNotificationRequest(
            identifier: "motion-\(UUID().uuidString)",
            content: content,
            trigger: nil   // deliver immediately
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error { dlog("Notification delivery error: \(error)") }
        }
    }
}
