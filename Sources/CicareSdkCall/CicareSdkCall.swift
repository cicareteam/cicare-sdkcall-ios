// The Swift Programming Language
// https://docs.swift.org/swift-book
import Foundation
import SwiftUI

public class CicareSdkCall {
    
    private var metaData: [String: String] = [
        "call_title": "Free Call",
        "call_busy": "The customer is busy and cannot be reached",
        "call_calling": "Calling...",
        "call_initializing": "Initializing...",
        "call_connecting": "Connecting...",
        "call_ringing": "Ringing...",
        "call_refused": "Decline",
        "call_end": "End Call",
        "call_incoming": "Incoming",
        "call_temporarily_unavailable": "Currently unreachable",
        "call_lost_connection": "Connection lost",
        "call_weak_signal": "Weak Signal",
        "call_btn_message": "Send Message",
        "call_btn_mute": "Mute",
        "call_btn_speaker": "Speaker",
        "call_failed_api": "Call failed due to system error",
        "call_failed_no_connection": "No internet connection",
        "call_feedback_bad": "Bad experience",
        "call_feedback_bad_driver_cannot_hear": "Driver couldn't hear me",
        "call_feedback_bad_lost_connection": "Call was disconnected",
        "call_feedback_bad_noisy": "Too much background noise",
        "call_feedback_bad_unstable_connection": "Unstable connection",
        "call_feedback_btn_submit": "Submit Feedback",
        "call_feedback_desc_content": "Help us improve by sharing your experience",
        "call_feedback_desc_title": "Tell us about your call experience",
        "call_feedback_good": "Good experience",
        "call_feedback_good_connection": "Good connection",
        "call_feedback_good_no_delay": "No audio delay",
        "call_feedback_good_sound": "Clear sound quality",
        "call_feedback_okay": "Okay",
        "call_feedback_okay_delay": "Audio was delayed",
        "call_feedback_okay_flickering_sound": "Audio was flickering",
        "call_feedback_okay_small_sound": "Sound was too low",
        "call_feedback_skip": "Skip feedback",
        "call_feedback_title": "Call Feedback",
        "call_option_btn_free_call": "Free Call",
        "call_option_title": "Call Options",
        "call_permission_btn_allow": "Allow",
        "call_permission_btn_deny": "Deny",
        "call_permission_btn_setting": "Go to Settings",
        "call_permission_btn_skip": "Skip",
        "call_permission_microphone_content": "We need access to your microphone to make calls",
        "call_permission_microphone_demied_content": "Please enable microphone access in your phone’s Settings",
        "call_permission_microphone_demied_title": "Microphone access is required to make a call",
        "call_permission_microphone_title": "Microphone Permission",
        "call_status_call_customer": "Calling customer",
        "call_status_call_customer_no_answer": "Customer did not answer",
        "call_status_call_customer_refused": "Customer refused the call",
        "call_status_call_driver": "Calling driver",
        "call_status_call_driver_cancelled": "Driver cancelled the call",
        "call_status_call_driver_no_answer": "Driver did not answer",
        "call_status_call_driver_refused": "Driver refused the call",
        "call_status_call_from_customer": "Incoming call from customer",
        "call_status_call_from_customer_miss": "Missed call from customer",
        "call_status_call_from_driver": "Incoming call from driver",
        "call_status_call_from_driver_miss": "Missed call from driver",
        "call_status_call_guide_again": "Please try calling again",
        "call_status_call_guide_back": "Please return to the app to continue the call",
        "call_suggestion_btn_dial": "Dial",
        "call_suggestion_btn_free_call": "Call for Free",
        "call_suggestion_btn_message": "Send a Message",
        "call_suggestion_desc_travelling": "The user might be traveling",
        "call_suggestion_desc_try_again": "Try calling again in a moment"
    ]
    
            
    public init() {
        _ = NotificationManager.shared
    }
    
    public func setAPI(baseUrl: String, token: String) {
        APIService.shared.baseURL = baseUrl
        APIService.shared.apiKey = token
    }
    
    public func incoming(
        callerId: String,
        callerName: String,
        callerAvatar: String,
        calleeId: String,
        calleeName: String,
        calleeAvatar: String,
        checkSum: String,
        server: String,
        token: String,
        isFormPhone: Bool,
        metaData: [String: String]?,
        onMessageClicked: (() -> Void)? = nil
    ) {
        let merged = self.metaData.merging(metaData ?? self.metaData) { _, new in new }
                CallService.sharedInstance.reportIncomingCall(
                    callerName: callerName,
                    avatarUrl: callerAvatar,
                    metaData: merged,
                    server: server,
                    tokenCall: token,
                    isFromPhone: isFormPhone
                )
        //self.showCallScreen(calleeName: callerName, callStatus: CallStatus.incoming.rawValue, avatarUrl: callerAvatar, metaData: merged)
    }

    public func outgoing(
        callerId: String,
        callerName: String,
        callerAvatar: String,
        calleeId: String,
        calleeName: String,
        calleeAvatar: String,
        checkSum: String,
        metaData: [String: String]?
    ) {
        let merged = self.metaData.merging(metaData ?? self.metaData) { _, new in new }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            CallService.sharedInstance.makeCall(handle: "Annas", calleeName: "CalleeName", metaData: merged, callData: CallSessionRequest(
                callerId: callerId,
                callerName: callerName,
                callerAvatar: callerAvatar,
                calleeId: calleeId,
                calleeName: calleeName,
                calleeAvatar: calleeAvatar,
                checkSum: checkSum
            ))
        }
        self.showCallScreen(
            calleeName: calleeName,
            callStatus: CallStatus.connecting.rawValue,
            avatarUrl: calleeAvatar,
            metaData: merged
        )
    }

    private func getKeyWindowRootViewController() -> UIViewController? {
        if #available(iOS 13.0, *) {
            return UIApplication.shared
                .connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap { $0.windows }
                .first(where: { $0.isKeyWindow })?
                .rootViewController
        } else {
            return UIApplication.shared.keyWindow?.rootViewController
        }
    }
    private func showCallScreen(calleeName: String, callStatus: String, avatarUrl: String? = nil, metaData: [String: String] = [:]) {
        DispatchQueue.main.async {
            guard let topVC = self.getKeyWindowRootViewController() else {
                print("❌ Failed to find top view controller")
                return
            }
            
            if #available(iOS 13.0, *) {
                let vc = UIHostingController(rootView: CallScreenWrapper(
                    calleeName: calleeName,
                    callStatus: callStatus,
                    avatarUrl: avatarUrl,
                    metaData: metaData
                ))
                vc.modalPresentationStyle = .fullScreen
                topVC.present(vc, animated: true)
            } else {
                let vc = CallScreenViewController()
                vc.calleeName = calleeName
                vc.callStatus = callStatus
                vc.avatarUrl = avatarUrl
                vc.metaData = metaData
                vc.modalPresentationStyle = .fullScreen
                topVC.present(vc, animated: true)
            }
        }
    }


    
}

struct CallScreenWrapper: UIViewControllerRepresentable {
    var calleeName: String
    var callStatus: String
    var avatarUrl: String?
    var metaData: [String: String]

    func makeUIViewController(context: Context) -> CallScreenViewController {
        let vc = CallScreenViewController()
        vc.calleeName = calleeName
        vc.callStatus = callStatus
        vc.avatarUrl = avatarUrl
        vc.metaData = metaData
        return vc
    }

    func updateUIViewController(_ uiViewController: CallScreenViewController, context: Context) {
        // Update if needed
    }
}
