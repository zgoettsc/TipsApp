import SwiftUI
import FirebaseCore
import UserNotifications

@main
struct TIPsApp: App {
    @StateObject private var appData = AppData()
    
    init() {
        FirebaseApp.configure()
        setupNotifications()
        print("TIPsApp init called at \(Date())")
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView(appData: appData)
                .onAppear {
                    print("App relaunched at \(Date()), resetting AppData")
                    appData.reloadCachedData()
                }
        }
    }
    
    func setupNotifications() {
        UNUserNotificationCenter.current().delegate = NotificationDelegate.shared
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error = error {
                print("Error requesting notification permission: \(error)")
            } else {
                print("Notification permission \(granted ? "granted" : "denied")")
            }
        }
        
        let dismissAction = UNNotificationAction(identifier: "DISMISS", title: "Dismiss", options: [])
        let treatmentCategory = UNNotificationCategory(
            identifier: "TREATMENT_TIMER",
            actions: [dismissAction],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )
        let reminderCategory = UNNotificationCategory(
            identifier: "REMINDER_CATEGORY",
            actions: [dismissAction],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )
        UNUserNotificationCenter.current().setNotificationCategories([treatmentCategory, reminderCategory])
    }
}

class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationDelegate()
    
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.actionIdentifier == "DISMISS" {
            print("User dismissed notification: \(response.notification.request.identifier)")
        }
        print("User tapped notification: \(response.notification.request.identifier)")
        completionHandler()
    }
    
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        print("Notification will present in foreground: \(notification.request.identifier)")
        completionHandler([.banner, .sound, .badge])
    }
}
