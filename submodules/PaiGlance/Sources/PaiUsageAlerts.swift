import Foundation
import UserNotifications

/// Local alerts when a usage window crosses 50/80/100%. The app, the widget and the box's push share the
/// identifier, so whichever sees a crossing first alerts and the others replace it silently.
public enum PaiUsageAlerts {
    public static func post(_ crossings: [PaiGlanceStore.Crossing]) {
        guard !crossings.isEmpty else { return }
        // The box's push for the same crossing may already be showing: it carries `paiUsage`.
        UNUserNotificationCenter.current().getDeliveredNotifications { delivered in
            let told = delivered.compactMap { $0.request.content.userInfo["paiUsage"] as? [String: Any] }
            add(crossings.filter { crossing in
                !told.contains { ($0["window"] as? String) == crossing.window && ($0["threshold"] as? Int ?? 0) >= crossing.threshold }
            })
        }
    }

    private static func add(_ crossings: [PaiGlanceStore.Crossing]) {
        for crossing in crossings {
            let content = UNMutableNotificationContent()
            content.title = crossing.title
            content.body = crossing.body
            if crossing.threshold >= 100 {
                content.sound = .default
            }
            content.threadIdentifier = "pai.usage"
            content.userInfo = ["url": PaiGlanceLink.usage.absoluteString]
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: crossing.identifier, content: content, trigger: nil))
        }
    }
}
