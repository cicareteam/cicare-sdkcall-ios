//
//  CallManager.swift
//  CicareSdkCall
//
//  Created by Mohammad Annas Al Hariri on 27/10/25.
//


import Foundation
import AVFoundation
import CallKit
import UIKit
import SwiftUI
import CommonCrypto

final class CallManager: NSObject, CallServiceDelegate, CXCallObserverDelegate, CXProviderDelegate {
    
    static let sharedInstance: CallManager = CallManager()
    
    public var isOutgoing: Bool = false
    private var screenIsShown: Bool = false
    private var metaData: [String: String] = [:]
    var callVC: UIViewController?
    var delegate: CallEventListener?
    
    private var callWindow: UIWindow?

    private var provider: CXProvider?
    private var callController: CXCallController?
    
    private let callObserver = CXCallObserver()
    
    private var calls: [UUID: CallInfo] = [:]
    private var currentCall: UUID?
    private var isInCall: Bool = false
    private var defaultVolume: Float = 1.0
    
    private var incomingCallTimers: [UUID: Timer] = [:]
    private let incomingCallTimeout: TimeInterval = 60.0
    
    private var cancelledCalls: Set<UUID> = []
    private var callStatus: CallStatus?
    
    private override init() {
        super.init()
    }
    
    public func setupCallKit() {
        let configuration = CXProviderConfiguration.init(localizedName: "CallKit")
        configuration.supportsVideo = false
        configuration.maximumCallsPerCallGroup = 1;
        configuration.supportedHandleTypes = [CXHandle.HandleType.generic]
        callObserver.setDelegate(self, queue: nil)
        provider = CXProvider.init(configuration: configuration)
        provider?.setDelegate(self, queue: nil)
        
        callController = CXCallController.init()
        
        NotificationCenter.default.addObserver(self,
                                             selector: #selector(handleAudioInterruption),
                                             name: AVAudioSession.interruptionNotification,
                                             object: AVAudioSession.sharedInstance())
        
        // ✅ Handle audio route changes (WiFi ↔ 4G, Bluetooth connections, etc.)
        NotificationCenter.default.addObserver(self,
                                             selector: #selector(handleRouteChange),
                                             name: AVAudioSession.routeChangeNotification,
                                             object: AVAudioSession.sharedInstance())
    }
    
    public func deactiveCallKit() {
        provider?.invalidate()
        provider = nil
        provider = nil
        callController = nil
        NotificationCenter.default.removeObserver(self, name: AVAudioSession.interruptionNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: AVAudioSession.routeChangeNotification, object: nil)
    }
    
    private func requestTransaction(transaction : CXTransaction, completion: @escaping (Bool) -> Void) {
        
        callController?.request(transaction, completion: { (error : Error?) in
            
            if error != nil {
                completion(false)
            } else {
                completion(true)
            }
        })
    }
    
    private func extractServerData(
        callerId: String,
        alertData: String,
        completion: @escaping (Result<(server: String, token: String, isFromPhone: Bool), Error>) -> Void
    ) {
        
        CryptoKeyManager.shared.getKey { result in
            switch result {
            case .success(let key):
                guard
                    let decryptedString = decrypt(
                        cipher: alertData,
                        encryptionKey: key
                    ),
                    let data = decryptedString.data(using: .utf8)
                else {
                    completion(.failure(
                        NSError(
                            domain: "DecryptError",
                            code: -1,
                            userInfo: [NSLocalizedDescriptionKey: "Failed to decrypt data"]
                        )
                    ))
                    return
                }
                
                do {
                    if let jsonObject = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] {
                        guard
                            let server = jsonObject["server"] as? String,
                            let token = jsonObject["token"] as? String
                        else {
                            throw NSError(domain: "JSONError", code: -2, userInfo: [NSLocalizedDescriptionKey: "Missing required fields"])
                        }

                        let isFromPhone = (jsonObject["isFromPhone"] as? Bool) ?? false
                        completion(.success((server: server, token: token, isFromPhone: isFromPhone)))
                    } else {
                        throw NSError(domain: "JSONError", code: -3, userInfo: [NSLocalizedDescriptionKey: "Invalid JSON format"])
                    }
                } catch {
                    completion(.failure(error))
                }
            case .failure(let error):
                completion(.failure(error))
            }
        }

    }
    
    private func requestMicrophonePermission(completion: @escaping (Bool) -> Void) {
        switch AVAudioSession.sharedInstance().recordPermission {
        case .granted:
            completion(true)
            
        case .denied:
            completion(false)
            
        case .undetermined:
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                DispatchQueue.main.async {
                    completion(granted)
                }
            }
            
        @unknown default:
            completion(false)
        }
    }
    
    func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
        isOutgoing = call.isOutgoing
        if call.hasEnded {
            isInCall = false
            //delegate?.callDidEnd()
        } else if !call.hasEnded {
            isInCall = true
            //delegate?.callInprogress()
        } else if call.hasConnected {
            //delegate?.callDidConnected()
        //} else if !call.isOutgoing && !call.hasConnected && !call.hasEnded {
        //} else if !call.isOutgoing && call.hasConnected {
        //    delegate?.callDidConnected()
        }
    }
    
    func providerDidReset(_ provider: CXProvider) {
        for (uuid, _) in calls {
            endCall(uuid: uuid)
        }
    }
    
    func outgoingCall(handle: String, calleeId: String, calleeName: String, calleeAvatar: String? = "", metaData: [String:String], callData: CallSessionRequest, completion: @escaping (Result<Void, CallError>) -> Void) {
        
        if (self.provider == nil) {
            return
        }
        
        if (self.currentCall != nil) {
            return completion(.failure(CallError.alreadyIncall))
        }
        self.currentCall = UUID.init()
        requestMicrophonePermission { granted in
            if (granted) {
                if let unwrappedCurrentCall = self.currentCall {
                    self.calls[unwrappedCurrentCall] = CallInfo (
                        callId: calleeId,
                        hasVideo: false,
                        callName: calleeName,
                        callAvatar: calleeAvatar ?? "",
                        callType: .OUTGOING,
                        callStatus: .connecting
                    )
                    let cxHandle = CXHandle(type: CXHandle.HandleType.generic, value: handle)
                    let action = CXStartCallAction.init(call: unwrappedCurrentCall, handle: cxHandle)
                    action.isVideo = false
                    let transaction = CXTransaction.init()
                    transaction.addAction(action)
                    self.requestTransaction(transaction: transaction) { success in
                        if success {
                            
                            guard !self.cancelledCalls.contains(unwrappedCurrentCall) else {
                                return
                            }
                            
                            DispatchQueue.main.async {
                                self.showCallScreen(uuid: unwrappedCurrentCall, callStatus: "connecting")
                            }
                            
                            guard let bodyData = try? JSONEncoder().encode(callData) else {
                                return
                            }
                            self.calls[unwrappedCurrentCall]?.callStatus = .connecting
                            SocketSignaling.shared.setCallState(.connecting)
                            self.postCallStatus(.connecting)
                            
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
                                            SocketSignaling.shared.connect(wssUrl: wssUrl, token: callSession.token, uuid: unwrappedCurrentCall) { status in
                                                
                                                guard !self.cancelledCalls.contains(unwrappedCurrentCall) else {
                                                    print("send signal cancel call")
                                                    SocketSignaling.shared.send(event: "CANCEL", data: [:])
                                                    return
                                                }
                                                
                                                if status == .connected {
                                                    SocketSignaling.shared.initCall()
                                                }
                                            }
                                            completion(.success(()))
                                        } else {
                                            completion(.failure(CallError.internalServerError(code: 505, message: "Server not found")))
                                            self.postNetworkStatus("server_not_found")
                                        }
                                        break
                                    case .failure(let error):
                                        switch error {
                                        case .unauthorized:
                                            completion(.failure(CallError.apiUnauthorized))
                                            self.postNetworkStatus("call_failed_api")
                                        case .badRequest(let data):
                                            completion(.failure(CallError.internalServerError(code: data.code ?? 400, message: data.message)))
                                            self.postNetworkStatus(data.message)
                                        default:
                                            completion(.failure(CallError.internalServerError(code: 500, message: error.localizedDescription)))
                                            self.postNetworkStatus("call_failed_api")
                                        }
                                    }
                                })
                        }
                    }
                }
            } else {
                completion(.failure(CallError.microphonePermissionDenied))
            }
        }
    }
    
    func reportIncomingCall(
        callerId: String,
        callerName: String,
        avatarUrl: String,
        metaData: [String:String],
        onMessageClicked: (() -> Void)? = nil,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        
        if (self.provider == nil) {
            return
        }
        
        let inUUID = UUID()
        self.startIncomingCallTimer(for: inUUID)
        self.metaData = metaData
        if let alertData = metaData["alert_data"] {
            
            let update = CXCallUpdate()
            update.remoteHandle = CXHandle(type: .generic, value: callerName)
            update.localizedCallerName = callerName
            update.hasVideo = false
            if (self.currentCall != nil && self.isInCall) {
                self.extractServerData(callerId: callerId, alertData: alertData) { result in
                    switch result {
                    case .success(let data):
                        SocketSignaling.shared.sendBusyCall(token: data.token)
                        self.provider?.reportCall(with: inUUID, endedAt: Date(), reason: .unanswered)
                    case .failure(let error):
                        print(error)
                    }
                }
            } else {
                self.provider?.reportNewIncomingCall(with: inUUID, update: update) { error in
                    if let error = error {
                        completion(.failure(error))
                    } else {
                        print("Incoming report executed from sdk")
                        self.extractServerData(callerId: callerId, alertData: alertData) { result in
                            switch result {
                            case .success(let data):
                                if let wssUrl = URL(string: data.server) {
                                    SocketSignaling.shared.connect(wssUrl: wssUrl, token: data.token, uuid: inUUID) {_ in
                                        
                                    }
                                    self.currentCall = inUUID
                                    self.postCallStatus(.incoming)
                                    self.calls[inUUID] = CallInfo(
                                        callId: callerId,
                                        hasVideo: false,
                                        callName: callerName,
                                        callAvatar: avatarUrl,
                                        callType: .INCOMING,
                                        callStatus: .incoming
                                    )
                                    SocketSignaling.shared.emit("RINGING_CALL", [:])
                                    
                                    completion(.success(()))
                                } else {
                                    self.provider?.reportCall(with: inUUID, endedAt: Date(), reason: .failed)
                                    let error = NSError(
                                        domain: "CallManager",
                                        code: -1,
                                        userInfo: [NSLocalizedDescriptionKey: "Invalid server URL"]
                                    )
                                    completion(.failure(error))
                                }
                            case .failure(let error):
                                print("Failed to extract server data: \(error)")
                                self.provider?.reportCall(with: inUUID, endedAt: Date(), reason: .failed)
                                completion(.failure(error))
                            }
                        }
                    }
                }
            }
        }
    }
    
    func muteCall(isMuted: Bool) -> Bool {
        let success = SocketSignaling.shared.muteCall(isMuted)
        return success
    }
    
    func missedCall() {
        for (uuid, _) in calls {
            let endCallAction = CXEndCallAction.init(call:uuid)
            let transaction = CXTransaction.init()
            transaction.addAction(endCallAction)
            requestTransaction(transaction: transaction) { success in
                SocketSignaling.shared.setCallState(.missed)
                self.postCallStatus(.ended)
                SocketSignaling.shared.releaseWebrtc()
                self.dismissCallScreen()
                self.currentCall = nil
                self.calls.removeValue(forKey: uuid)
                self.cancelIncomingCallTimer(for: uuid)
            }
        }
    }
    
    private func startIncomingCallTimer(for uuid: UUID) {
        cancelIncomingCallTimer(for: uuid)
        let timer = Timer.scheduledTimer(withTimeInterval: incomingCallTimeout, repeats: false) { [weak self] _ in
            guard let self = self else { return }
           if let callInfo = self.calls[uuid],
               callInfo.callType == .INCOMING,
               callInfo.callStatus == .incoming {
               self.provider?.reportCall(with: uuid, endedAt: Date(), reason: .unanswered)
                SocketSignaling.shared.setCallState(.missed)
                self.postCallStatus(.missed)
               self.calls.removeValue(forKey: uuid)
                if self.currentCall == uuid {
                    self.currentCall = nil
                }
                SocketSignaling.shared.releaseWebrtc()
                self.dismissCallScreen()
            }
           self.incomingCallTimers.removeValue(forKey: uuid)
        }
       incomingCallTimers[uuid] = timer
    }
    
    private func cancelIncomingCallTimer(for uuid: UUID) {
        if let timer = incomingCallTimers[uuid] {
            timer.invalidate()
            incomingCallTimers.removeValue(forKey: uuid)
        }
    }
    
    func cleanUpAndEnd(uuid: UUID, state: CallStatus) {
        
    }
    
    func endActiveCall() {
        for (uuid, call) in calls {
            if (call.callType == .OUTGOING && (call.callStatus == .connecting || call.callStatus == .calling)) {
                cancelCall(uuid: uuid)
            } else {
                print("end call")
                endCall(uuid: uuid)
            }
        }
    }
    
    func callAccepted() {
        self.postCallStatus(.accepted)
    }
    
    func callConnected() {
        self.postCallStatus(.connected)
    }
    
    func callRejected() {
        if let uuid = currentCall {
            let endCallAction = CXEndCallAction.init(call:uuid)
            let transaction = CXTransaction.init()
            transaction.addAction(endCallAction)
            requestTransaction(transaction: transaction) { success in
                self.postCallStatus(.refused)
                self.calls.removeValue(forKey: uuid)
                if (self.currentCall == uuid) {
                    self.dismissCallScreen()
                    self.currentCall = nil
                }
            }
        }
    }
    
    func callBusy() {
        if let uuid = currentCall {
            let endCallAction = CXEndCallAction.init(call:uuid)
            let transaction = CXTransaction.init()
            transaction.addAction(endCallAction)
            requestTransaction(transaction: transaction) { success in
                self.postCallStatus(.busy)
                self.calls.removeValue(forKey: uuid)
                if (self.currentCall == uuid) {
                    self.dismissCallScreen()
                    self.currentCall = nil
                }
            }
        }
    }
    
    func callRinging() {
        postCallStatus(.ringing)
    }
    
    func rejectCall() {
        let incomingCalls = calls.filter { $0.value.callType == .INCOMING && $0.value.callStatus == .incoming }
        for (uuid, _) in incomingCalls {
            rejectCall(uuid: uuid)
        }
    }
    
    func rejectCall(uuid: UUID) {
        self.cancelIncomingCallTimer(for: uuid)
        let endCallAction = CXEndCallAction.init(call:uuid)
        let transaction = CXTransaction.init()
        transaction.addAction(endCallAction)
        requestTransaction(transaction: transaction) { success in
            SocketSignaling.shared.rejectCall()
            self.postCallStatus(.ended)
            self.calls.removeValue(forKey: uuid)
        }
    }
    
    func cancelCall(uuid: UUID) {
        // ✅ Mark IMMEDIATELY (before any async operation)
        print("🚫 Marking call as cancelled: \(uuid)")
        cancelledCalls.insert(uuid)
        
        let endCallAction = CXEndCallAction.init(call:uuid)
        let transaction = CXTransaction.init()
        transaction.addAction(endCallAction)
        print("cancel call")
        requestTransaction(transaction: transaction) { success in
            SocketSignaling.shared.setCallState(.cancel)
            self.delegate?.onCallStateChanged(.cancel)
            self.postCallStatus(.ended)
            if (self.currentCall == uuid) {
                SocketSignaling.shared.releaseWebrtc()
                self.dismissCallScreen()
                self.currentCall = nil
            }
            self.calls.removeValue(forKey: uuid)
            
            // ✅ Clean up after 2 seconds (handle late callbacks)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                self.cancelledCalls.remove(uuid)
                print("🧹 Cleaned up cancelled call: \(uuid)")
            }
        }
    }
    
    func endCallOnDeniedMic() {
        if let uuid = self.currentCall {
            let endCallAction = CXEndCallAction.init(call:uuid)
            let transaction = CXTransaction.init()
            transaction.addAction(endCallAction)
            requestTransaction(transaction: transaction) { success in
                SocketSignaling.shared.setCallState(.ended)
                self.postCallStatus(.ended)
                SocketSignaling.shared.releaseWebrtc()
                self.calls.removeValue(forKey: uuid)
                self.currentCall = nil
            }
        }
    }
    
    func endCall(uuid: UUID) {
        self.cancelIncomingCallTimer(for: uuid)
        let endCallAction = CXEndCallAction.init(call:uuid)
        let transaction = CXTransaction.init()
        transaction.addAction(endCallAction)
        requestTransaction(transaction: transaction) { success in
            SocketSignaling.shared.setCallState(.ended)
            self.postCallStatus(.ended)
            if (self.currentCall == uuid) {
                SocketSignaling.shared.releaseWebrtc()
                self.dismissCallScreen()
                self.currentCall = nil
            }
            self.calls.removeValue(forKey: uuid)
        }
    }
    
    func endedCall(uuid: UUID, callState: CallStatus) {
        self.cancelIncomingCallTimer(for: uuid)
        let endCallAction = CXEndCallAction.init(call:uuid)
        let transaction = CXTransaction.init()
        transaction.addAction(endCallAction)
        requestTransaction(transaction: transaction) { success in
            self.postCallStatus(callState)
            if (self.currentCall == uuid) {
                SocketSignaling.shared.releaseWebrtc()
                self.dismissCallScreen()
                self.currentCall = nil
            }
            self.calls.removeValue(forKey: uuid)
            
        }
    }
    
    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        //configureAudioSession()
        provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: nil)
        provider.reportOutgoingCall(with: action.callUUID, connectedAt: nil)
        action.fulfill()
    }
    
    public func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        cancelIncomingCallTimer(for: action.callUUID)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if (!self.screenIsShown) {
                self.showCallScreen(uuid: action.callUUID ,callStatus: "connecting")
            }
        }
        
        self.postCallStatus(.connecting)
        self.calls[action.callUUID]?.callStatus = .connecting
        
        for (uuid, _) in self.calls {
            if (uuid != action.callUUID) {
                self.endCall(uuid: uuid)
            } else {
                //self.currentCall = action.callUUID
                SocketSignaling.shared.answerCall() {
                    self.calls[action.callUUID]?.callStatus = .connected
                    SocketSignaling.shared.initOffer()
                }
            }
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
        
        //delegate?.callDidHold(isOnHold: action.isOnHold)
        action.fulfill()
    }
    
    func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        let success = SocketSignaling.shared.muteCall(action.isMuted)
        print("mute \(success)")
        let session = AVAudioSession.sharedInstance()
        defaultVolume = session.inputGain
        /*if session.isInputGainSettable {
            try? session.setInputGain(action.isMuted ? 0.0 : defaultVolume)
        }*/
        action.fulfill()
    }
    
    func provider(_ provider: CXProvider, perform action: CXSetGroupCallAction) {
    }
    
    func provider(_ provider: CXProvider, perform action: CXPlayDTMFCallAction) {
    }
    
    func provider(_ provider: CXProvider, timedOutPerforming action: CXAction) {
        action.fulfill()
    }
    
    /// Called when the provider's audio session activation state changes.
    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        print("🔊 Audio session activated")
        self.configureAudioSession()
        if let _ = currentCall {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                SocketSignaling.shared.initOffer()
            }
        }
    }
    
    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        print("Audio session deactivated")
        if let _ = currentCall {
            SocketSignaling.shared.releaseWebrtc()
        }
    }
    
    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        if (calls[action.callUUID]?.callStatus == .incoming) {
            rejectCall()
        }
        cancelledCalls.removeAll()
        action.fulfill()
    }
    
    func postCallStatus(_ status: CallStatus) {
        delegate?.onCallStateChanged(status)
        callStatus = status
        NotificationCenter.default.post(name: .callStatusChanged, object: nil, userInfo: ["status" : status.rawValue])
        if (status == .reconnected) {
            //SocketSignaling.shared.initOffer()
        } else if (status == .reconnecting) {
            NotificationCenter.default.post(name: .callNetworkChanged, object: nil, userInfo: ["signalStrength" : status.rawValue])
        }
    }
    
    private func postNetworkStatus(_ status: String) {
        NotificationCenter.default.post(name: .callNetworkChanged, object: nil, userInfo: ["error" : status])
    }
    
    private func configureAudioSession() {
        let audioSession = AVAudioSession.sharedInstance()
        do {
            if audioSession.category != .playAndRecord {
                try audioSession.setCategory(AVAudioSession.Category.playAndRecord,
                                             options: [.allowBluetoothHFP, .allowBluetoothA2DP, .defaultToSpeaker, .mixWithOthers])
            }
            if audioSession.mode != .voiceChat {
                try audioSession.setMode(.voiceChat)
            }
            try audioSession.setActive(true)
        } catch {
            print("Error configuring AVAudioSession: \(error.localizedDescription)")
        }
    }
    
    @objc func handleAudioInterruption(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }
        
        switch type {
        case .began:
            print("🔊 Audio interruption began")
            // Audio has effectively stopped
            
        case .ended:
            print("🔊 Audio interruption ended")
            guard let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt else { return }
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            
            if options.contains(.shouldResume) {
                print("🔊 Resuming audio session...")
                configureAudioSession()
                
                // Re-initialize WebRTC audio if we are in a call
                if let _ = self.currentCall {
                     DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                         SocketSignaling.shared.initOffer()
                     }
                }
            }
            
        @unknown default:
            break
        }
    }
    
    @objc func handleRouteChange(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else {
            return
        }
        
        switch reason {
        case .newDeviceAvailable:
            if let _ = self.currentCall {
                configureAudioSession()
            }
            
        case .oldDeviceUnavailable:
            if let _ = self.currentCall {
                configureAudioSession()
            }
            
        case .categoryChange:
            if let _ = self.currentCall {
                configureAudioSession()
                print("🔊 Audio category changed")
            }
            
        case .override:
            print("🔊 Audio route override")
            
        case .wakeFromSleep:
            print("🔊 Device woke from sleep")
            // Reinitialize audio if in call
            if let _ = self.currentCall {
                configureAudioSession()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    SocketSignaling.shared.initOffer()
                }
            }
            
        case .noSuitableRouteForCategory:
            print("🔊 No suitable audio route")
            
        case .routeConfigurationChange:
            print("🔊 Audio route configuration changed")
            
        case .unknown:
            print("🔊 Audio unknown change")
            break
        }
    }
    
    private func showCallScreen(uuid: UUID, callStatus: String) {
        guard self.calls[uuid] != nil else { return }
        self.screenIsShown = true
        // Tutup window lama jika ada
        self.callWindow?.isHidden = true
        self.callWindow = nil

        let vc: UIViewController
        if #available(iOS 13.0, *) {
            vc = UIHostingController(rootView: CallScreenWrapper(
                calleeName: self.calls[uuid]!.callName,
                callStatus: callStatus,
                avatarUrl: self.calls[uuid]!.callAvatar,
                metaData: self.metaData
            ))
        } else {
            let screen = CallScreenViewController()
            screen.callStatus = callStatus
            screen.calleeName = self.calls[uuid]!.callName
            screen.avatarUrl = self.calls[uuid]!.callAvatar
            screen.metaData = self.metaData
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

    func dismissCallScreen() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.callWindow?.isHidden = true
            if #available(iOS 13.0, *) {
                self.callWindow?.windowScene = nil
            }
            self.callWindow = nil
            self.callVC = nil
            self.screenIsShown = false
        }
    }
    
}

enum CallType: String {
    case OUTGOING
    case INCOMING
}

struct CallInfo {
    var callId: String
    var hasVideo: Bool
    var callName: String
    var callAvatar: String
    var callType: CallType
    var callStatus: CallStatus?
    var alertData: String?
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

struct CallSession: Decodable {
    let server: String
    let token: String
    let isFromPhone: Bool?
}


protocol CallServiceDelegate: AnyObject {
    func endCall(uuid: UUID)
    func endedCall(uuid: UUID, callState: CallStatus)
    func callAccepted()
    func callConnected()
    func callRinging()
    func callRejected()
    func callBusy()
}

func decrypt(cipher: String, encryptionKey: String) -> String? {
    // Pisahkan iv dan ciphertext berdasarkan tanda ":"
    let components = cipher.split(separator: ":")
    guard components.count == 2 else { return nil }
    
    let ivHex = String(components[0])
    let encryptedHex = String(components[1])
    
    // Konversi hex ke Data
    guard let iv = Data(hex: ivHex),
          let encryptedData = Data(hex: encryptedHex),
          let keyData = encryptionKey.data(using: .utf8) else {
        return nil
    }
    
    let keyLength = kCCKeySizeAES256
    guard keyData.count == keyLength else {
        return nil
    }
    
    // Siapkan buffer sementara untuk hasil dekripsi
    let bufferSize = encryptedData.count + kCCBlockSizeAES128
    var buffer = Data(count: bufferSize)
    var numBytesDecrypted: size_t = 0
    
    let cryptStatus = buffer.withUnsafeMutableBytes { bufferBytes in
        encryptedData.withUnsafeBytes { encryptedBytes in
            iv.withUnsafeBytes { ivBytes in
                keyData.withUnsafeBytes { keyBytes in
                    CCCrypt(
                        CCOperation(kCCDecrypt),
                        CCAlgorithm(kCCAlgorithmAES128),
                        CCOptions(kCCOptionPKCS7Padding),
                        keyBytes.baseAddress,
                        keyLength,
                        ivBytes.baseAddress,
                        encryptedBytes.baseAddress,
                        encryptedData.count,
                        bufferBytes.baseAddress,
                        bufferSize,
                        &numBytesDecrypted
                    )
                }
            }
        }
    }
    
    if cryptStatus == kCCSuccess {
        let decryptedData = buffer.prefix(numBytesDecrypted)
        return String(data: decryptedData, encoding: .utf8)
    } else {
        print("❌ Dekripsi gagal dengan status \(cryptStatus)")
        return nil
    }
}

extension Data {
    init?(hex: String) {
        let len = hex.count / 2
        var data = Data(capacity: len)
        var index = hex.startIndex
        for _ in 0..<len {
            let nextIndex = hex.index(index, offsetBy: 2)
            if nextIndex > hex.endIndex { return nil }
            let bytes = hex[index..<nextIndex]
            if var num = UInt8(bytes, radix: 16) {
                data.append(&num, count: 1)
            } else {
                return nil
            }
            index = nextIndex
        }
        self = data
    }
}
