import Foundation
import UIKit
import CallKit
import AVFoundation
import PushKit
import SwiftUI

protocol CallManagerDelegate : AnyObject {
    
    func callDidAnswer()
    func callDidConnected()
    func callDidEnd()
    func callDidHold(isOnHold : Bool)
    func callDidFail()
}

struct CallSession: Decodable {
    let server: String
    let token: String
    let isFromPhone: Bool?
}
struct CallSessionRequest: Codable {
    let callerId: String
    let callerName: String
    let callerAvatar: String
    let calleeId: String
    let calleeName: String
    let calleeAvatar: String
    let checkSum: String
}

final class CallService: NSObject, CXCallObserverDelegate, CXProviderDelegate {
    
    private var isOutgoing: Bool = false
    
    func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
        isOutgoing = call.isOutgoing
        if call.hasEnded {
        } else if call.isOutgoing && !call.hasConnected {
        } else if call.isOutgoing && call.hasConnected {
        } else if !call.isOutgoing && !call.hasConnected && !call.hasEnded {
        } else if !call.isOutgoing && call.hasConnected {
        }
    }

    private let callObserver = CXCallObserver()
    
    private var callerName: String?
    private var callerAvatar: String?
    private var metaData: [String:String]?
    private var server: String = ""
    private var token: String = ""
    private var isFromPhone: Bool = false
    private var screenIsShown: Bool = false
    public var isSignalingReady: Bool = false
    weak var callEventDelegate: CallEventListener?
    private var pendingAnswerAction: CXAnswerCallAction?
    
    private var callWindow: UIWindow?
    
    private var audioSession: AVAudioSession?
    
    static let sharedInstance: CallService = CallService()
    
    var answeredButNotReady: Bool = false
    
    private var onMessageClicked : (() -> Void)?
    
    var provider : CXProvider?
    var callController : CXCallController?
    var currentCall : UUID?
    var callVC: UIViewController?
    
    var callStatus : CallStatus = .connecting
    
    //private var voipRegistry: PKPushRegistry?
    
    weak var delegate : CallManagerDelegate?
    
    private override init() {
        super.init()
        providerAndControllerSetup()
        callObserver.setDelegate(self, queue: nil)
    }
    
    private func checkMicrophonePermission() -> Bool {
        let status = AVAudioSession.sharedInstance().recordPermission
        
        switch status {
        case .granted:
            print("✅ Microphone permission granted")
            return true
        case .denied:
            print("❌ Microphone permission denied")
            return false
        case .undetermined:
            print("🤔 Microphone permission not requested yet")
            return false
        @unknown default:
            return false
        }
    }
    
    func isAnyCallActive() -> Bool {
        return callObserver.calls.contains(where: { !$0.hasEnded })
    }
    
    /*private func setupPushKit() {
        voipRegistry = PKPushRegistry(queue: DispatchQueue.main)
        voipRegistry?.delegate = self
        voipRegistry?.desiredPushTypes = [.voIP]
    }*/
    
    //MARK: - Setup
        
    func providerAndControllerSetup() {
        
        let configuration = CXProviderConfiguration.init(localizedName: "CallKit")
        configuration.supportsVideo = true
        configuration.maximumCallsPerCallGroup = 1;
        configuration.supportedHandleTypes = [CXHandle.HandleType.generic]
        provider = CXProvider.init(configuration: configuration)
        provider?.setDelegate(self, queue: nil)
        callObserver.setDelegate(self, queue: nil)
        
        callController = CXCallController.init()
    }
    
    // MARK: - CallKit Event Posting
    public func postCallStatus(_ status: CallStatus) {
        callStatus = status
        NotificationCenter.default.post(name: .callStatusChanged, object: nil, userInfo: ["status" : status.rawValue])
    }
    
    public func postNetworkStatus(_ status: String) {
        NotificationCenter.default.post(name: .callNetworkChanged, object: nil, userInfo: ["error" : status])
    }
    
    private func postCallProfile(_ name: String,_ avatarUrl: String? = "",_ metaData: [String:String]) {
        NotificationCenter.default.post(name: .callProfileSet, object: nil, userInfo: ["name" : name, "avatar": avatarUrl ?? "", "meta": metaData])
    }
    
    // MARK: - Laporan Panggilan Masuk
    public func reportIncomingCall(
        callerName: String,
        avatarUrl: String,
        metaData: [String:String],
        onMessageClicked: (() -> Void)? = nil
    ) {
        
        self.onMessageClicked = onMessageClicked
        self.callerName = callerName
        self.callerAvatar = avatarUrl
        self.metaData = metaData
        
        self.callEventDelegate?.onCallStateChanged(.incoming)
        self.answeredButNotReady = false
        
        if var base64String = self.metaData?["alert_data"] as? String {
            if let range = base64String.range(of: "base64,") {
                base64String = String(base64String[range.upperBound...])
            }
            base64String = base64String.trimmingCharacters(in: .whitespacesAndNewlines)
            let remainder = base64String.count % 4
            if remainder > 0 {
                base64String += String(repeating: "=", count: 4 - remainder)
            }
            if let decodedData = Data(base64Encoded: base64String, options: .ignoreUnknownCharacters) {
                do {
                    if let jsonObject = try JSONSerialization.jsonObject(with: decodedData, options: []) as? [String: Any] {
                        self.server = jsonObject["server"] as! String
                        self.token = jsonObject["token"] as! String
                        self.isFromPhone = (jsonObject["isFromPhone"] != nil)
                    }
                } catch {
                    print("Failed to decode JSON: \(error)")
                }
            }
        }
        
        self.ringing()
        self.isSignalingReady = false
        //DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
        if let url = URL(string: self.server) {
            SocketManagerSignaling.shared.connect(wssUrl: url, token: self.token) { status in
                if status == .connected {
                    SocketManagerSignaling.shared.ringingCall()
                } else {
                    self.endCall()
                    self.callEventDelegate?.onCallStateChanged(.call_error)
                }
            }
        } else {
            self.endCall()
        }
        //}
    }
    
    public func ringing() {
        let incomingUUID = UUID()
        //CallState.shared.currentCallUUID = incomingUUID
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: self.callerName ?? "")
        update.localizedCallerName = callerName
        update.hasVideo = false
        provider?.reportNewIncomingCall(with: incomingUUID, update: update) { [weak self] error in
            if let self = self {
                if (self.isAnyCallActive()) {
                    self.provider?.reportCall(with: incomingUUID, endedAt: Date(), reason: .failed)
                    self.callEventDelegate?.onCallStateChanged(.busy)
                    SocketManagerSignaling.shared.callState = .busy
                }
            }
            if let error = error {
                print("❌ Incoming call error: \(error)")
                self?.delegate?.callDidFail()
            } else {
                if ((self?.isForeground()) != nil) {
                    self?.showCallScreen(callStatus: "incoming")
                }
                self?.currentCall = incomingUUID
                self?.postCallStatus(.incoming)
                self?.callStatus = .incoming
                
            }
        }
    }
    
    public func missed() {
        NotificationManager.shared.showMissedOrEndedNotification(caller: self.callerName ?? "")
    }
    
    private func isForeground() -> Bool {
        if #available(iOS 13.0, *) {
            if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                if scene.activationState == .foregroundActive {
                    return true
                }
            }
        } else {
            if UIApplication.shared.applicationState == .active {
                return true
            }
        }
        return false
    }
    
    // MARK: - Memulai Panggilan Keluar
    public func makeCall(handle: String, calleeName: String, calleeAvatar: String? = "", metaData: [String:String], callData: CallSessionRequest, completion: @escaping (Result<Void, CallError>) -> Void) {
        
        self.answeredButNotReady = false
        self.callerName = calleeName
        self.callerAvatar = calleeAvatar
        self.metaData = metaData
        if (!self.checkMicrophonePermission()) {
            completion(.failure(CallError.microphonePermissionDenied))
        } else {
            showCallScreen(callStatus: "connecting")
            currentCall = UUID.init()
            
            self.postCallProfile(calleeName, calleeAvatar, metaData)
            NotificationManager.shared.showOutgoingCallNotification(callee: handle)
            
            guard let bodyData = try? JSONEncoder().encode(callData) else {
                return
            }
            
            self.postCallStatus(.connecting)
            self.callEventDelegate?.onCallStateChanged(.connecting)
            APIService.shared.request(
                path: "api/sdk-call/one2one",
                method: "POST",
                body: bodyData,
                headers: ["Content-Type": "application/json"],
                completion: { (result: Result<CallSession, APIError>) in
                    switch result {
                    case .success(let callSession):
                        if let wssUrl = URL(string: callSession.server) {
                            
                            if let unwrappedCurrentCall = self.currentCall {
                                //CallState.shared.currentCallUUID = currentCall
                                let cxHandle = CXHandle(type: CXHandle.HandleType.generic, value: handle)
                                let action = CXStartCallAction.init(call: unwrappedCurrentCall, handle: cxHandle)
                                action.isVideo = false
                                let transaction = CXTransaction.init()
                                transaction.addAction(action)
                                self.requestTransaction(transaction: transaction) { success in
                                    if success {
                                        completion(.success(()))
                                        self.postCallStatus(.calling)
                                        self.callEventDelegate?.onCallStateChanged(.calling)
                                        SocketManagerSignaling.shared.connect(wssUrl: wssUrl, token: callSession.token) { status in
                                            if status == .connected {
                                                SocketManagerSignaling.shared.initCall()
                                            }
                                        }
                                    }
                                }
                            }
                        } else {
                            self.callEventDelegate?.onCallStateChanged(.call_error)
                            completion(.failure(CallError.internalServerError(code: 505, message: "Server not found")))
                            self.postNetworkStatus("server_not_found")
                        }
                        break
                    case .failure(let error):
                        self.currentCall = nil
                        self.callEventDelegate?.onCallStateChanged(.call_error)
                        switch error {
                        case .unauthorized:
                            completion(.failure(CallError.apiUnauthorized))
                            self.postNetworkStatus("call_failed_api")
                        case .badRequest(let data):
                            completion(.failure(CallError.internalServerError(code: data.code ?? 400, message: data.message)))
                            self.postNetworkStatus(data.message)
                        default:
                            completion(.failure(CallError.internalServerError(code: 500, message: "Internal server error")))
                            self.postNetworkStatus("call_failed_api")
                        }
                    }
                })
            }
        }
    
    public func connected() {
        if self.answeredButNotReady {
            //print("answered");
            self.callStatus = .connected
            self.postCallStatus(.connected)
            SocketManagerSignaling.shared.send(event: "ANSWER_CALL", data: [:])
            self.answeredButNotReady = false
            self.pendingAnswerAction = nil
            configureAudioSession()
            SocketManagerSignaling.shared.initOffer()
        }
    }
    
    func endCall() {
        self.screenIsShown = false
        self.isSignalingReady = false
        SocketManagerSignaling.shared.send(event: "REQUEST_HANGUP", data: [:])
        if (callStatus != .ended) {
            callStatus = .ended
            CallService.sharedInstance.postCallStatus(.ended)
            //callEventDelegate?.onCallStateChanged(.ended)
        }
        if let uuid = currentCall {
            let endCallAction = CXEndCallAction.init(call:uuid)
            let transaction = CXTransaction.init()
            transaction.addAction(endCallAction)
            requestTransaction(transaction: transaction) { success in
                if success {
                    self.currentCall = nil
                    //CallState.shared.currentCallUUID = nil
                }
            }
        }
        //provider?.reportCall(with: currentCall, endedAt: Date(), reason: .remoteEnded)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.dismissCallScreen()
        }
    }
    
    func closedCall() {
        self.screenIsShown = false
        self.isSignalingReady = false
        if let uuid = currentCall {
            let endCallAction = CXEndCallAction.init(call:uuid)
            let transaction = CXTransaction.init()
            transaction.addAction(endCallAction)
            requestTransaction(transaction: transaction) { success in
                if success {
                    //CallState.shared.currentCallUUID = nil
                    //SocketManagerSignaling.shared.disconnect()
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.dismissCallScreen()
        }
    }
    
    func cancelCall() {
        self.screenIsShown = false
        self.isSignalingReady = false
        SocketManagerSignaling.shared.send(event: "CANCEL", data: [:])
        SocketManagerSignaling.shared.callState = .cancel
        self.postCallStatus(CallStatus.cancel)
        if let uuid = currentCall {
            let endCallAction = CXEndCallAction.init(call:uuid)
            let transaction = CXTransaction.init()
            transaction.addAction(endCallAction)
            requestTransaction(transaction: transaction) { success in
                if success {
                    //CallState.shared.currentCallUUID = nil
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.dismissCallScreen()
        }
    }
    
    func declineCall() {
        if (self.isSignalingReady) {
            //print("decline")
            SocketManagerSignaling.shared.send(event: "REJECT", data: [:])
            //SocketManagerSignaling.shared.disconnect()
        } else {
            SocketManagerSignaling.shared.callState = .refused
        }
        if let uuid = currentCall {
            let endCallAction = CXEndCallAction(call: uuid)
            let transaction = CXTransaction()
            transaction.addAction(endCallAction)
            requestTransaction(transaction: transaction){ succes in
                self.postCallStatus(.ended)
                self.screenIsShown = false
                self.isSignalingReady = false
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.dismissCallScreen()
        }
    }
    func busyCall() {
        self.postCallStatus(.busy)
        self.screenIsShown = false
        self.isSignalingReady = false
        SocketManagerSignaling.shared.send(event: "BUSY", data: [:])
        NotificationManager.shared.showMissedOrEndedNotification(caller: self.callerName ?? "")
        if let uuid = currentCall {
            let endCallAction = CXEndCallAction.init(call:uuid)
            let transaction = CXTransaction.init()
            transaction.addAction(endCallAction)
            requestTransaction(transaction: transaction) { success in
                if success {
                    //CallState.shared.currentCallUUID = nil
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.dismissCallScreen()
        }
    }
    
    func holdCall(hold : Bool) {
        
        if let unwrappedCurrentCall = currentCall {
            
            let holdCallAction = CXSetHeldCallAction.init(call: unwrappedCurrentCall, onHold: hold)
            let transaction = CXTransaction.init()
            transaction.addAction(holdCallAction)
            requestTransaction(transaction: transaction) { success in
                if success {
                    
                }
            }
        }
    }
    
    func requestTransaction(transaction : CXTransaction, completion: @escaping (Bool) -> Void) {
        
        weak var weakSelf = self
        callController?.request(transaction, completion: { (error : Error?) in
            
            if error != nil {
                weakSelf?.delegate?.callDidFail()
                completion(false)
            } else {
                completion(true)
            }
        })
    }
    
    // MARK: - Menjawab Panggilan
    public func answerCall() {
        if let uuid = currentCall {
            let action = CXAnswerCallAction(call: uuid)
            let transaction = CXTransaction(action: action)
            requestTransaction(transaction: transaction) { success in
                if success {
                    self.delegate?.callDidConnected()
                }
            }
        }
    }
    
    // MARK: - CXProviderDelegate
    
    func providerDidReset(_ provider: CXProvider) {
        print("🔄 Provider reset")
        self.postCallStatus(.ended)
        //CallState.shared.currentCallUUID = nil
    }
    
    // If provider:executeTransaction:error: returned NO, each perform*CallAction method is called sequentially for each action in the transaction
    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        //todo: configure audio session
        //todo: start network call
        configureAudioSession()
        callStatus = .connected
        provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: nil)
        provider.reportOutgoingCall(with: action.callUUID, connectedAt: nil)
        delegate?.callDidAnswer()
        action.fulfill()
    }
    
    func providerDidBegin(_ provider: CXProvider) {
        print("Something else happened \(String(describing: (self.provider)))")
    }
    
    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        
        //todo: configure audio session
        //todo: answer network call
        delegate?.callDidAnswer()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if (!self.screenIsShown) {
                self.showCallScreen(callStatus: "connecting")
                //
            } else {
                //SocketManagerSignaling.shared.send(event: "ANSWER_CALL", data: [:])
            }
        }
        
        //let state = UIApplication.shared.applicationState
        //if state == .inactive {
            configureAudioSession()
            //AVAudioSession.sharedInstance().setActive(true)
        //}
        
        callStatus = .connecting
        self.postCallStatus(.connecting)
        self.callEventDelegate?.onCallStateChanged(.connecting)
        if (self.isSignalingReady) {
            SocketManagerSignaling.shared.send(event: "ANSWER_CALL", data: [:])
            self.answeredButNotReady = false
            self.pendingAnswerAction = nil
            //SocketManagerSignaling.shared.send(event: "ANSWER_CALL", data: [:])
            //self.callStatus = .connected
            //self.postCallStatus(.connected)
            action.fulfill()
        } else {
            self.answeredButNotReady = true
            self.postCallStatus(.connecting)
            //self.pendingAnswerAction = action
            action.fulfill()
        }
        
    }

    func configureAudioSession() {
        let audioSession = AVAudioSession.sharedInstance()
        do {
            if audioSession.category != .playAndRecord {
                try audioSession.setCategory(AVAudioSession.Category.playAndRecord,
                                             options: AVAudioSession.CategoryOptions.allowBluetooth)
            }
            if audioSession.mode != .voiceChat {
                try audioSession.setMode(.voiceChat)
            }
        } catch {
            //logger.error(msg: "Error configuring AVAudioSession: \(error.localizedDescription)")
        }
    }
    
    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        self.audioSession = nil
        self.screenIsShown = false
        self.pendingAnswerAction = nil
        if (!isOutgoing && callStatus != .connecting && callStatus != .connected && callStatus != .ended) {
            if (self.isSignalingReady) {
                SocketManagerSignaling.shared.send(event: "REJECT", data: [:])
                //SocketManagerSignaling.shared.disconnect()
            } else {
                SocketManagerSignaling.shared.callState = .refused
            }
            NotificationManager.shared.showMissedOrEndedNotification(caller: self.callerName ?? "")
        } else if (isOutgoing && (callStatus == .calling || callStatus == .connecting || callStatus == .ringing)) {
            SocketManagerSignaling.shared.send(event: "CANCEL", data: [:])
            //print("cancel")
            callStatus = .cancel
            self.callEventDelegate?.onCallStateChanged(.cancel)
            SocketManagerSignaling.shared.callState = .cancel
        }
        if (callStatus != .ended && callStatus != .refused && callStatus != .busy && callStatus != .cancel) {
            callStatus = .ended
            self.postCallStatus(.ended)
            //self.callEventDelegate?.onCallStateChanged(.ended)
        }
        currentCall = nil
        
        self.isSignalingReady = false
        delegate?.callDidEnd()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            SocketManagerSignaling.shared.callState = nil
            self.dismissCallScreen()
        }
        action.fulfill()
    }
    
    func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) {
        //print("Something else held")
        if action.isOnHold {
            //todo: stop audio
        } else {
            //todo: start audio
        }
        
        delegate?.callDidHold(isOnHold: action.isOnHold)
        action.fulfill()
    }
    
    func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        SocketManagerSignaling.shared.muteCall(action.isMuted)
        // Jangan lupa panggil complete agar CallKit tahu aksinya berhasil
        action.fulfill()
    }
    
    func provider(_ provider: CXProvider, perform action: CXSetGroupCallAction) {
    }
    
    func provider(_ provider: CXProvider, perform action: CXPlayDTMFCallAction) {
    }
    
    // Called when an action was not performed in time and has been inherently failed. Depending on the action, this timeout may also force the call to end. An action that has already timed out should not be fulfilled or failed by the provider delegate
    func provider(_ provider: CXProvider, timedOutPerforming action: CXAction) {
        // React to the action timeout if necessary, such as showing an error UI.
        //print("Something else timout")
        action.fulfill()
    }
    
    /// Called when the provider's audio session activation state changes.
    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        print("🔊 Audio session activated")
        self.audioSession = audioSession
        SocketManagerSignaling.shared.initOffer()
    }
    
    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        /*
         Restart any non-call related audio now that the app's audio session has been
         de-activated after having its priority restored to normal.
         */
        print("🔇 Audio session deactivated")
        SocketManagerSignaling.shared.releaseWebrtc()
    }
    
    private func topViewController() -> UIViewController? {
        if #available(iOS 13.0, *) {
            // iOS 13 ke atas pakai connectedScenes
            return UIApplication.shared
                .connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap { $0.windows }
                .first(where: { $0.isKeyWindow })?
                .rootViewController
        } else {
            // iOS 12 ke bawah pakai keyWindow
            return UIApplication.shared.keyWindow?.rootViewController
        }
    }

    private func showCallScreen(callStatus: String) {
        DispatchQueue.main.async {
            self.screenIsShown = true
            // Tutup window lama jika ada
            self.callWindow?.isHidden = true
            self.callWindow = nil

            let vc: UIViewController
            if #available(iOS 13.0, *) {
                vc = UIHostingController(rootView: CallScreenWrapper(
                    calleeName: self.callerName ?? "",
                    callStatus: callStatus,
                    avatarUrl: self.callerAvatar,
                    metaData: self.metaData ?? [:]
                ))
            } else {
                let screen = CallScreenViewController(onMessageClicked: self.onMessageClicked)
                screen.callStatus = callStatus
                screen.calleeName = self.callerName ?? ""
                screen.avatarUrl = self.callerAvatar ?? ""
                screen.metaData = self.metaData ?? [:]
                vc = screen
            }

            let newWindow: UIWindow
            if #available(iOS 13.0, *) {
                let scene = UIApplication.shared.connectedScenes
                    .compactMap { $0 as? UIWindowScene }
                    .first { $0.activationState == .foregroundActive }
                    ?? UIApplication.shared.connectedScenes
                        .compactMap { $0 as? UIWindowScene }
                        .first

                if let windowScene = scene {
                    newWindow = UIWindow(windowScene: windowScene)
                } else {
                    newWindow = UIWindow(frame: UIScreen.main.bounds)
                }
            } else {
                newWindow = UIWindow(frame: UIScreen.main.bounds)
            }

            newWindow.frame = UIScreen.main.bounds
            newWindow.rootViewController = vc
            newWindow.windowLevel = .alert + 1
            newWindow.makeKeyAndVisible()

            self.callWindow = newWindow
            self.callVC = vc
        }
    }

    public func dismissCallScreen() {
        DispatchQueue.main.async {
            self.callWindow?.isHidden = true
            self.callWindow = nil
            self.screenIsShown = false
            self.currentCall = nil
        }
    }
    
}

/*extension CallService: PKPushRegistryDelegate {
    
    func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
        // Kirim token ke server untuk notifikasi VoIP
        let token = pushCredentials.token.map { String(format: "%02x", $0) }.joined()
        print("✅ VoIP token: \(token)")
    }
    
    func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload, for type: PKPushType) {
        print("📲 Received VoIP push")
        let callerName = payload.dictionaryPayload["callerName"] as? String ?? "Unknown"
        reportIncomingCall(handle: callerName, callerName: callerName)
    }
    
    func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload, for type: PKPushType, completion: @escaping () -> Void) {
        // iOS 13+ requires this method
        self.pushRegistry(registry, didReceiveIncomingPushWith: payload, for: type)
        completion()
    }
}*/
