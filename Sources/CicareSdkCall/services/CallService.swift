import Foundation
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
        print("Hello \(callObserver) \(call)")
    }
    
    
    static let sharedInstance: CallService = CallService()
    
    var provider : CXProvider?
    var callController : CXCallController?
    var currentCall : UUID?
    let callObserver = CXCallObserver()
    
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
    public func reportIncomingCall(callerName: String, avatarUrl: String, metaData: [String:String]) {
        let incomingUUID = UUID()
        CallState.shared.currentCallUUID = incomingUUID
        
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: callerName)
        update.localizedCallerName = callerName
        update.hasVideo = false
        provider?.reportNewIncomingCall(with: incomingUUID, update: update) { [weak self] error in
            if let error = error {
                print("❌ Incoming call error: \(error)")
                self?.delegate?.callDidFail()
            } else {
                self?.currentCall = incomingUUID
                self?.postCallStatus(.incoming)
                self?.postCallProfile(callerName, avatarUrl, metaData)
            }
        }
    }
    
    // MARK: - Memulai Panggilan Keluar
    public func makeCall(handle: String, calleeName: String, calleeAvatar: String? = "", metaData: [String:String], callData: CallSessionRequest) {
        currentCall = UUID.init()
        if let unwrappedCurrentCall = currentCall {
            CallState.shared.currentCallUUID = currentCall
            print("uuidcall \(unwrappedCurrentCall)")
            let cxHandle = CXHandle(type: CXHandle.HandleType.generic, value: handle)
            let action = CXStartCallAction.init(call: unwrappedCurrentCall, handle: cxHandle)
            action.isVideo = false
            let transaction = CXTransaction.init()
            transaction.addAction(action)
            requestTransaction(transaction: transaction) { success in
                if success {
                    CallState.shared.callProvider = self.provider
                    self.postCallStatus(.connecting)
                    self.postCallProfile(calleeName, calleeAvatar, metaData)
                    NotificationManager.shared.showOutgoingCallNotification(callee: handle)
                    
                    guard let bodyData = try? JSONEncoder().encode(callData) else {
                        print("Failed encoding body!")
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
                                print("Connect to signaling \(String(describing: self.currentCall))")
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
                        case .failure(_):
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
                            self.postNetworkStatus("call_failed_api")
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
        print("End the call")
        self.postCallStatus(.ended)
        NotificationManager.shared.showMissedOrEndedNotification()
        if let uuid = currentCall {
            print("uuidnya \(uuid)")
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
        NotificationManager.shared.showMissedOrEndedNotification()
        if let uuid = currentCall {
            print("uuidnya \(uuid) \(CallState.shared.currentCallUUID)")
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
        NotificationManager.shared.showMissedOrEndedNotification()
        if let uuid = CallState.shared.currentCallUUID,
           let _ = CallState.shared.callProvider {
            let endCallAction = CXEndCallAction(call: uuid)
            let transaction = CXTransaction()
            transaction.addAction(endCallAction)
            requestTransaction(transaction: transaction){ succes in
                
            }
        }
    }
    func busyCall() {
        self.postCallStatus(.busy)
        NotificationManager.shared.showMissedOrEndedNotification()
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
                print("\(String(describing: error?.localizedDescription))")
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
        print("Something else answered")
        self.postCallStatus(.connected)
        action.fulfill()
    }
    
    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        //todo: configure audio session
        //todo: answer network call
        print("currentCall: \(String(describing: currentCall))")
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
        print("Something else muted")
    }
    
    func provider(_ provider: CXProvider, perform action: CXSetGroupCallAction) {
    }
    
    func provider(_ provider: CXProvider, perform action: CXPlayDTMFCallAction) {
    }
    
    // Called when an action was not performed in time and has been inherently failed. Depending on the action, this timeout may also force the call to end. An action that has already timed out should not be fulfilled or failed by the provider delegate
    func provider(_ provider: CXProvider, timedOutPerforming action: CXAction) {
        // React to the action timeout if necessary, such as showing an error UI.
        print("Something else timout")
    }
    
    /// Called when the provider's audio session activation state changes.
    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        print("🔊 Audio session activated")
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
