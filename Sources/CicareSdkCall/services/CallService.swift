import Foundation
import UIKit
import CallKit
import AVFoundation
import PushKit

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
    func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
    }
    
    private var callerName: String?
    private var callerAvatar: String?
    private var metaData: [String:String]?
    private var server: String = ""
    private var token: String = ""
    private var isFromPhone: Bool = false
    
    private var audioSession: AVAudioSession?
    
    static let sharedInstance: CallService = CallService()
    
    private var onMessageClicked : (() -> Void)?
    
    var provider : CXProvider?
    var callController : CXCallController?
    var currentCall : UUID?
    let callObserver = CXCallObserver()
    
    var callStatus : CallStatus = .connecting
    
    //private var voipRegistry: PKPushRegistry?
    
    weak var delegate : CallManagerDelegate?
    
    private override init() {
        super.init()
        providerAndControllerSetup()
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
        NotificationCenter.default.post(name: .callStatusChanged, object: nil, userInfo: ["status" : status.rawValue])
    }
    
    public func postNetworkStatus(_ status: String) {
        print("status \(status)")
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
        server: String,
        tokenCall: String,
        isFromPhone: Bool,
        onMessageClicked: (() -> Void)? = nil
    ) {
        
        self.onMessageClicked = onMessageClicked
        self.callerName = callerName
        self.callerAvatar = avatarUrl
        self.metaData = metaData
        self.server = server
        self.token = tokenCall
        self.isFromPhone = isFromPhone
        if let url = URL(string: server) {
            SocketManagerSignaling.shared.connect(wssUrl: url, token: token) { status in
                if status == .connected {
                    SocketManagerSignaling.shared.ringingCall()
                } else {
                    self.endCall()
                }
            }
        }
    }
    
    public func ringing() {
        let incomingUUID = UUID()
        CallState.shared.currentCallUUID = incomingUUID
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: self.callerName ?? "")
        update.localizedCallerName = callerName
        update.hasVideo = false
        provider?.reportNewIncomingCall(with: incomingUUID, update: update) { [weak self] error in
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
    public func makeCall(handle: String, calleeName: String, calleeAvatar: String? = "", metaData: [String:String], callData: CallSessionRequest) {
        currentCall = UUID.init()
        if let unwrappedCurrentCall = currentCall {
            CallState.shared.currentCallUUID = currentCall
            let cxHandle = CXHandle(type: CXHandle.HandleType.generic, value: handle)
            let action = CXStartCallAction.init(call: unwrappedCurrentCall, handle: cxHandle)
            action.isVideo = false
            let transaction = CXTransaction.init()
            transaction.addAction(action)
            requestTransaction(transaction: transaction) { success in
                if success {
                    self.postCallStatus(.connecting)
                    self.postCallProfile(calleeName, calleeAvatar, metaData)
                    NotificationManager.shared.showOutgoingCallNotification(callee: handle)
                    
                    guard let bodyData = try? JSONEncoder().encode(callData) else {
                        return
                    }
                    
                    APIService.shared.request(
                        path: "api/sdk-call/one2one",
                        method: "POST",
                        body: bodyData,
                        headers: ["Content-Type": "application/json"],
                        completion: { (result: Result<CallSession, APIError>) in
                        switch result {
                        case .success(let callSession):
                            if let wssUrl = URL(string: callSession.server) {
                                self.postCallStatus(.calling)
                                SocketManagerSignaling.shared.connect(wssUrl: wssUrl, token: callSession.token) { status in
                                    if status == .connected {
                                        SocketManagerSignaling.shared.initCall()
                                    }
                                }
                                /*self.signaling.connect(wssUrl: wssUrl, token: callSession.token) { status in
                                    if status == .connected {
                                        self.webRTCManager.createOffer() { sdp in
                                            print("init call")
                                            self.signaling.send(event: "INIT_CALL", data: [
                                                "is_caller": true,
                                                "sdp": sdp
                                            ])
                                        }
                                    } else {
                                        print(status)
                                    }
                                }*/
                                //SocketConnection.default.connect(url: callSession.server, token: callSession.token)
                                
                            }
                            break
                        case .failure(let error):
                            switch error {
                            case .badRequest(let data):
                                self.postNetworkStatus(data.message)
                            default:
                                print(error)
                                self.postNetworkStatus("call_failed_api")
                            }
                            /*switch error {
                            case .badURL:
                                self.postNetworkStatus("Failed make a call due to bad URL")
                            case .invalidResponse:
                                self.postNetworkStatus("Failed make a call due to invalid response")
                            case .decodingFailed(let decodeError):
                                print("⚠️ JSON decoding failed: \(decodeError)")
                            case .requestFailed(let underlyingError):
                                if let urlError = underlyingError as? URLError {
                                    switch urlError.code {
                                    case .timedOut:
                                        self.postNetworkStatus("Failed make a call due to timeout")
                                    case .notConnectedToInternet:
                                        self.postNetworkStatus("Failed make a call due to no internet connection")
                                    case .cannotConnectToHost:
                                        self.postNetworkStatus("Failed make a call due to server is down or blocked")
                                    case .cannotFindHost:
                                        print("❓ Host not found (DNS issue)")
                                    default:
                                        print("🌐 Network error: \(urlError.code)")
                                    }
                                } else {
                                    print("❌ Other request error: \(underlyingError)")
                                }
                            }*/
                            //self.endCall()
                        }
                    })
                }
            }
        }
        
        /*callController?.request(transaction) { error in
            if let error = error {
                print("❌ Outgoing call error: \(error)")
            } else {
                self.postCallStatus(.outgoing)
                self.postCallProfile(calleeName, calleeAvatar)
                NotificationManager.shared.showOutgoingCallNotification(callee: handle)
            }
        }*/
    }
    
    func endCall() {
        SocketManagerSignaling.shared.send(event: "REQUEST_HANGUP", data: [:])
        self.postCallStatus(.ended)
        if let uuid = currentCall {
            let endCallAction = CXEndCallAction.init(call:uuid)
            let transaction = CXTransaction.init()
            transaction.addAction(endCallAction)
            requestTransaction(transaction: transaction) { success in
                if success {
                    CallState.shared.currentCallUUID = nil
                }
            }
        }
    }
    
    func cancelCall() {
        SocketManagerSignaling.shared.send(event: "CANCEL", data: [:])
        self.postCallStatus(CallStatus.cancel)
        if let uuid = currentCall {
            let endCallAction = CXEndCallAction.init(call:uuid)
            let transaction = CXTransaction.init()
            transaction.addAction(endCallAction)
            requestTransaction(transaction: transaction) { success in
                if success {
                    CallState.shared.currentCallUUID = nil
                }
            }
        }
    }
    
    func declineCall() {
        SocketManagerSignaling.shared.send(event: "REJECT", data: [:])
        if let uuid = currentCall {
            let endCallAction = CXEndCallAction(call: uuid)
            let transaction = CXTransaction()
            transaction.addAction(endCallAction)
            requestTransaction(transaction: transaction){ succes in
                self.postCallStatus(.ended)
            }
        }
    }
    func busyCall() {
        self.postCallStatus(.busy)
        SocketManagerSignaling.shared.send(event: "BUSY", data: [:])
        NotificationManager.shared.showMissedOrEndedNotification(caller: self.callerName ?? "")
        if let uuid = currentCall {
            let endCallAction = CXEndCallAction.init(call:uuid)
            let transaction = CXTransaction.init()
            transaction.addAction(endCallAction)
            requestTransaction(transaction: transaction) { success in
                if success {
                    CallState.shared.currentCallUUID = nil
                }
            }
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
    public func answerCall(id: UUID) {
        let action = CXAnswerCallAction(call: id)
        let transaction = CXTransaction(action: action)
        requestTransaction(transaction: transaction) { success in
            if success {
                self.delegate?.callDidConnected()
            }
        }
    }
    
    // MARK: - CXProviderDelegate
    
    func providerDidReset(_ provider: CXProvider) {
        print("🔄 Provider reset")
        self.postCallStatus(.ended)
        CallState.shared.currentCallUUID = nil
    }
    
    // If provider:executeTransaction:error: returned NO, each perform*CallAction method is called sequentially for each action in the transaction
    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        //todo: configure audio session
        //todo: start network call
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
            if (!self.isForeground()) {
                self.showCallScreen(callStatus: "connecting")
            }
        }
        SocketManagerSignaling.shared.send(event: "ANSWER_CALL", data: [:])
        callStatus = .connected
        self.postCallStatus(.connected)
        action.fulfill()
    }
    
    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        self.audioSession = nil
        
        if (callStatus == .incoming) {
            SocketManagerSignaling.shared.send(event: "REJECT", data: [:])
            NotificationManager.shared.showMissedOrEndedNotification(caller: self.callerName ?? "")
        } else if (callStatus == .connecting || callStatus == .calling) {
            SocketManagerSignaling.shared.send(event: "CANCEL", data: [:])
        }
        currentCall = nil
        SocketManagerSignaling.shared.disconnect()
        delegate?.callDidEnd()
        action.fulfill()
    }
    
    func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) {
        print("Something else held")
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
        print("Something else timout")
        action.fulfill()
    }
    
    /// Called when the provider's audio session activation state changes.
    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        print("🔊 Audio session activated")
        self.audioSession = audioSession
        do {
            try audioSession.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth])
            try audioSession.setActive(true)
            
        } catch {
            print("❌ Audio session error: \(error)")
        }
    }
    
    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        /*
         Restart any non-call related audio now that the app's audio session has been
         de-activated after having its priority restored to normal.
         */
        print("🔇 Audio session deactivated")
    }
    
    private func topViewController() -> UIViewController? {
        if #available(iOS 13.0, *) {
            // iOS 13 ke atas pakai connectedScenes
            let scenes = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
            for scene in scenes {
                if let rootVC = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController {
                    return rootVC
                }
            }
        } else {
            // iOS 12 ke bawah pakai keyWindow
            return UIApplication.shared.keyWindow?.rootViewController
        }
        return nil
    }

    private func showCallScreen(callStatus: String) {
        DispatchQueue.main.async {
            let callVC = CallScreenViewController(onMessageClicked: self.onMessageClicked)
            callVC.modalPresentationStyle = .fullScreen
            callVC.callStatus = callStatus
            callVC.calleeName = self.callerName ?? ""
            callVC.avatarUrl = self.callerAvatar ?? ""

            if let rootVC = self.topViewController() {
                if let nav = rootVC as? UINavigationController {
                    nav.pushViewController(callVC, animated: true)
                } else {
                    rootVC.present(callVC, animated: true, completion: nil)
                }
            } else {
                print("⚠️ RootViewController not ready yet")
            }
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
