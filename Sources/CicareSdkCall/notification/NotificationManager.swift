import Foundation
import UserNotifications
import CallKit

final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()
    
    private override init() {
        super.init()
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        // Request permission for notifications
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error = error {
                print("Notification permission error: \(error)")
            } else if !granted {
                print("Notification permission denied")
            } else {
                print("Notification permission granted")
            }
        }
        configureNotificationCategories()
    }
    
    // Setup categories and actions if needed (e.g. Accept/Reject call)
    private func configureNotificationCategories() {
        let acceptAction = UNNotificationAction(identifier: "ACCEPT_CALL", title: "Accept", options: [.foreground])
        let rejectAction = UNNotificationAction(identifier: "REJECT_CALL", title: "Reject", options: [.destructive])
        let incomingCategory = UNNotificationCategory(identifier: "incoming", actions: [acceptAction, rejectAction], intentIdentifiers: [], options: [])
        
        UNUserNotificationCenter.current().setNotificationCategories([incomingCategory])
    }
    
    private func post(title: String, body: String, id: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        
        // Critical alert requires special entitlement, fallback to normal alert
        if id == "incoming" {
            print(CallState.shared.currentCallUUID!)
            content.sound = UNNotificationSound.defaultCritical
        } else {
            content.sound = UNNotificationSound.default
        }
        
        content.categoryIdentifier = id
        
        // Immediate notification (no trigger)
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("Failed to add notification: \(error)")
            }
        }
        print("Notification posted \(title) id \(id) body \(body)")
    }
    
    func showIncomingCallNotification(caller: String, uuid: UUID) {
        post(title: "Incoming call", body: "Call from \(caller)", id: "incoming")
    }
    
    func showOutgoingCallNotification(callee: String) {
        post(title: "Calling", body: "Calling \(callee)...", id: "outgoing")
    }
    
    func showOngoingCallNotification(callee: String) {
        post(title: "Ongoing call", body: "In call with \(callee)", id: "ongoing")
    }
    
    func showMissedOrEndedNotification() {
        post(title: "Call Ended", body: "", id: "ended")
    }
    
    // Optional: Handle user actions on notifications
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        switch response.actionIdentifier {
        case "ACCEPT_CALL":
            print("User accepted call")
            if let uuid = CallState.shared.currentCallUUID {
                CallService.sharedInstance.answerCall(id: uuid)
            }
            // Trigger your accept call logic here
        case "REJECT_CALL":
            print("User rejected call")
            if CallState.shared.currentCallUUID != nil {
                CallService.sharedInstance.endCall()
            }
            // Trigger your reject call logic here
        default:
            break
        }
        completionHandler()
    }
}
