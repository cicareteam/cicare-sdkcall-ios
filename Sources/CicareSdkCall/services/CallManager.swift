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
import Network

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
    
    private let callsQueue = DispatchQueue(label: "com.cicare.sdkcall.calls.queue")
    private var _calls: [UUID: CallInfo] = [:]
    private var _currentCall: UUID?
    private var _cancelledCalls: Set<UUID> = []
    private var _appInitiatedEnds: Set<UUID> = []
    private var _isInCall: Bool = false
    private var defaultVolume: Float = 1.0

    private var incomingCallTimers: [UUID: Timer] = [:]
    private let incomingCallTimeout: TimeInterval = 60.0

    private var callStatus: CallStatus?

    // MARK: - Atomic state accessors
    // All mutations of _calls, _currentCall, _cancelledCalls, _isInCall must go through these
    // helpers; the previous computed-property setters performed non-atomic get-modify-set on
    // dictionary subscripts.

    private var calls: [UUID: CallInfo] {
        callsQueue.sync { _calls }
    }

    private var currentCall: UUID? {
        callsQueue.sync { _currentCall }
    }

    private var cancelledCalls: Set<UUID> {
        callsQueue.sync { _cancelledCalls }
    }

    private var isInCall: Bool {
        get { callsQueue.sync { _isInCall } }
        set { callsQueue.sync { _isInCall = newValue } }
    }

    private func setCall(_ info: CallInfo, for uuid: UUID) {
        callsQueue.sync { _calls[uuid] = info }
    }

    private func updateCall(uuid: UUID, _ transform: (inout CallInfo) -> Void) {
        callsQueue.sync {
            if var info = _calls[uuid] {
                transform(&info)
                _calls[uuid] = info
            }
        }
    }

    @discardableResult
    private func removeCall(_ uuid: UUID) -> CallInfo? {
        callsQueue.sync { _calls.removeValue(forKey: uuid) }
    }

    private func getCall(_ uuid: UUID) -> CallInfo? {
        callsQueue.sync { _calls[uuid] }
    }

    /// Atomically reserves a UUID as the current outgoing call. Returns nil if a call is
    /// already active, preventing a check-then-set race between concurrent callers.
    private func reserveCurrentCall() -> UUID? {
        callsQueue.sync {
            guard _currentCall == nil else { return nil }
            let new = UUID()
            _currentCall = new
            return new
        }
    }

    private func setCurrentCall(_ uuid: UUID?) {
        callsQueue.sync { _currentCall = uuid }
    }

    private func clearCurrentCallIfMatches(_ uuid: UUID) {
        callsQueue.sync {
            if _currentCall == uuid { _currentCall = nil }
        }
    }

    private func insertCancelled(_ uuid: UUID) {
        callsQueue.sync { _ = _cancelledCalls.insert(uuid) }
    }

    private func removeCancelled(_ uuid: UUID) {
        callsQueue.sync { _ = _cancelledCalls.remove(uuid) }
    }

    private func removeAllCancelled() {
        callsQueue.sync { _cancelledCalls.removeAll() }
    }

    private func isCancelled(_ uuid: UUID) -> Bool {
        callsQueue.sync { _cancelledCalls.contains(uuid) }
    }

    /// Marks a UUID as being ended by app code, so the CXEndCallAction handler (which fires
    /// for both app-initiated transactions and system-initiated user actions) knows whether
    /// to perform the cleanup itself.
    private func markAppInitiatedEnd(_ uuid: UUID) {
        callsQueue.sync { _ = _appInitiatedEnds.insert(uuid) }
    }

    /// Returns true if this end was app-initiated (and the marker is consumed). False means
    /// the user ended the call from CallKit's system UI and we are the cleanup site.
    private func consumeAppInitiatedEnd(_ uuid: UUID) -> Bool {
        callsQueue.sync {
            if _appInitiatedEnds.contains(uuid) {
                _appInitiatedEnds.remove(uuid)
                return true
            }
            return false
        }
    }
    
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
        
        // Handle audio route changes (WiFi ↔ 4G, Bluetooth connections, etc.)
        NotificationCenter.default.addObserver(self,
                                             selector: #selector(handleRouteChange),
                                             name: AVAudioSession.routeChangeNotification,
                                             object: AVAudioSession.sharedInstance())
    }
    
    public func deactiveCallKit() {
        provider?.invalidate()
        provider = nil
        callController = nil
        NotificationCenter.default.removeObserver(self, name: AVAudioSession.interruptionNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: AVAudioSession.routeChangeNotification, object: nil)
    }

    private func sendMicPermissionNotification() {
        let content = UNMutableNotificationContent()
        content.title = self.metaData["call_mic_permission_title"] ?? "Microphone Access Required"
        content.body = self.metaData["call_mic_permission_message"] ?? "Please enable microphone access in Settings to allow the call audio to work."
        content.sound = .default
        
        let request = UNNotificationRequest(identifier: "MicPermissionDenied", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
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
        } else if call.hasConnected {
            isInCall = true
        } else {
            // Call in progress (ringing, connecting, etc.)
            isInCall = true
        }
    }
    
    func providerDidReset(_ provider: CXProvider) {
        let snapshot = calls
        for (uuid, _) in snapshot {
            endCall(uuid: uuid)
        }
    }
    
    func outgoingCall(handle: String, calleeId: String, calleeName: String, calleeAvatar: String? = "", metaData: [String:String], callData: CallSessionRequest, completion: @escaping (Result<Void, CallError>) -> Void) {
        self.metaData = metaData
        if (self.provider == nil) {
            completion(.failure(CallError.internalServerError(code: 500, message: "CallKit provider not initialized")))
            return
        }

        guard let unwrappedCurrentCall = self.reserveCurrentCall() else {
            return completion(.failure(CallError.alreadyIncall))
        }
        requestMicrophonePermission { granted in
            guard granted else {
                self.clearCurrentCallIfMatches(unwrappedCurrentCall)
                completion(.failure(CallError.microphonePermissionDenied))
                return
            }
            self.setCall(
                CallInfo(
                    callId: calleeId,
                    hasVideo: false,
                    callName: calleeName,
                    callAvatar: calleeAvatar ?? "",
                    callType: .OUTGOING,
                    callStatus: .connecting
                ),
                for: unwrappedCurrentCall
            )
            let cxHandle = CXHandle(type: CXHandle.HandleType.generic, value: handle)
            let action = CXStartCallAction.init(call: unwrappedCurrentCall, handle: cxHandle)
            action.isVideo = false
            let transaction = CXTransaction.init()
            transaction.addAction(action)

            // Helper used by every failure path below to release the slot we reserved at the
            // top of this function. Without this, an early error (no internet, bad API
            // response, invalid URL, etc.) would leave _currentCall pointing at a UUID with
            // no actual call, and every subsequent outgoing/incoming would be blocked.
            let releaseSlotOnFailure: () -> Void = {
                self.removeCall(unwrappedCurrentCall)
                self.clearCurrentCallIfMatches(unwrappedCurrentCall)
            }

            self.requestTransaction(transaction: transaction) { success in
                guard success else {
                    releaseSlotOnFailure()
                    completion(.failure(CallError.internalServerError(code: 500, message: "Failed to start CallKit transaction")))
                    return
                }

                guard !self.isCancelled(unwrappedCurrentCall) else {
                    releaseSlotOnFailure()
                    return
                }

                DispatchQueue.main.async {
                    self.showCallScreen(uuid: unwrappedCurrentCall, callStatus: "connecting")
                }

                guard let bodyData = try? JSONEncoder().encode(callData) else {
                    releaseSlotOnFailure()
                    completion(.failure(CallError.internalServerError(code: 500, message: "Failed to encode call request")))
                    return
                }
                self.updateCall(uuid: unwrappedCurrentCall) { $0.callStatus = .connecting }
                SocketSignaling.shared.setCallState(.connecting)
                self.postCallStatus(.connecting)

                self.isInternetAvailable { available in
                    if available == false {
                        releaseSlotOnFailure()
                        DispatchQueue.main.async {
                            self.postNetworkStatus("call_failed_no_connection", internetType: true)
                        }
                        completion(.failure(CallError.internalServerError(code: 500, message: "No internet connection")))
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
                                guard let wssUrl = URL(string: callSession.server) else {
                                    releaseSlotOnFailure()
                                    completion(.failure(CallError.internalServerError(code: 505, message: "Server not found")))
                                    self.postNetworkStatus("server_not_found")
                                    return
                                }
                                self.postCallStatus(.calling)
                                SocketSignaling.shared.connect(wssUrl: wssUrl, token: callSession.token, uuid: unwrappedCurrentCall) { status in

                                    guard !self.isCancelled(unwrappedCurrentCall) else {
                                        print("send signal cancel call")
                                        SocketSignaling.shared.send(event: "CANCEL", data: [:])
                                        return
                                    }

                                    if status == .connected {
                                        SocketSignaling.shared.initCall()
                                    }
                                }
                                completion(.success(()))
                            case .failure(let error):
                                releaseSlotOnFailure()
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
            self.setupCallKit()
        }
        self.configureAudioSession(false)
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: callerName)
        update.localizedCallerName = callerName
        update.hasVideo = false

        // No alert_data — cannot extract server config, fail fast.
        guard let alertData = metaData["alert_data"] else {
            self.failedIncomingCall(with: UUID(), update: update, reason: .failed) { result in
                completion(result)
            }
            return
        }

        guard let inUUID = self.reserveCurrentCall() else {
            print("Auto-declining incoming call: SDK is already busy")
            self.extractServerData(callerId: callerId, alertData: alertData) { result in
                if case .success(let data) = result {
                    SocketSignaling.shared.sendBusyCall(token: data.token)
                }
                self.failedIncomingCall(with: UUID(), update: update, reason: .declinedElsewhere) { result in
                    completion(result)
                }
            }
            return
        }

        self.setCall(
            CallInfo(
                callId: callerId,
                hasVideo: false,
                callName: callerName,
                callAvatar: avatarUrl,
                callType: .INCOMING,
                callStatus: .incoming
            ),
            for: inUUID
        )

        self.metaData = metaData
        self.startIncomingCallTimer(for: inUUID)

        self.provider?.reportNewIncomingCall(with: inUUID, update: update) { error in
            if let error = error {
                self.cancelIncomingCallTimer(for: inUUID)
                self.clearCurrentCallIfMatches(inUUID)
                completion(.failure(error))
                return
            }
            print("Incoming report executed from sdk")
            self.extractServerData(callerId: callerId, alertData: alertData) { result in
                switch result {
                case .success(let data):
                    guard let wssUrl = URL(string: data.server) else {
                        self.cancelIncomingCallTimer(for: inUUID)
                        self.clearCurrentCallIfMatches(inUUID)
                        self.provider?.reportCall(with: inUUID, endedAt: Date(), reason: .failed)
                        let error = NSError(
                            domain: "CallManager",
                            code: -1,
                            userInfo: [NSLocalizedDescriptionKey: "Invalid server URL"]
                        )
                        completion(.failure(error))
                        return
                    }
                    SocketSignaling.shared.connect(wssUrl: wssUrl, token: data.token, uuid: inUUID) {_ in
                        print("connected from incoming report")
                    }
                    self.postCallStatus(.incoming)
                    
                    SocketSignaling.shared.emit("RINGING_CALL", [:])
                    completion(.success(()))
                case .failure(let error):
                    print("Failed to extract server data: \(error)")
                    self.cancelIncomingCallTimer(for: inUUID)
                    self.clearCurrentCallIfMatches(inUUID)
                    self.provider?.reportCall(with: inUUID, endedAt: Date(), reason: .failed)
                    completion(.failure(error))
                }
            }
        }
    }

    func failedIncomingCall(with uuid: UUID, update: CXCallUpdate, reason: CXCallEndedReason, completion: @escaping (Result<Void, Error>) -> Void) {
        self.provider?.reportNewIncomingCall(with: uuid, update: update) { error in
            if let error = error {
                completion(.failure(error))
            } else {
                self.provider?.reportCall(with: uuid, endedAt: Date(), reason: reason)
                completion(.success(()))
            }
        }
    }
    
    func muteCall(isMuted: Bool) -> Bool {
        let success = SocketSignaling.shared.muteCall(isMuted)
        return success
    }
    
    func missedCall() {
        let snapshot = calls
        for (uuid, _) in snapshot {
            markAppInitiatedEnd(uuid)
            let endCallAction = CXEndCallAction.init(call:uuid)
            let transaction = CXTransaction.init()
            transaction.addAction(endCallAction)
            requestTransaction(transaction: transaction) { success in
                SocketSignaling.shared.setCallState(.missed)
                self.postCallStatus(.ended)
                SocketSignaling.shared.releaseWebrtc()
                self.dismissCallScreen()
                self.clearCurrentCallIfMatches(uuid)
                self.removeCall(uuid)
                self.cancelIncomingCallTimer(for: uuid)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    SocketSignaling.shared.close()
                }
            }
        }
    }

    private func startIncomingCallTimer(for uuid: UUID) {
        cancelIncomingCallTimer(for: uuid)
        let timer = Timer.scheduledTimer(withTimeInterval: incomingCallTimeout, repeats: false) { [weak self] _ in
            guard let self = self else { return }
           if let callInfo = self.getCall(uuid),
               callInfo.callType == .INCOMING,
               callInfo.callStatus == .incoming {
               self.provider?.reportCall(with: uuid, endedAt: Date(), reason: .unanswered)
                SocketSignaling.shared.setCallState(.missed)
                self.postCallStatus(.missed)
               self.removeCall(uuid)
               self.clearCurrentCallIfMatches(uuid)
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
        let snapshot = calls
        if snapshot.isEmpty, let uuid = currentCall {
            endCall(uuid: uuid)
            return
        }
        for (uuid, call) in snapshot {
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
            markAppInitiatedEnd(uuid)
            let endCallAction = CXEndCallAction.init(call:uuid)
            let transaction = CXTransaction.init()
            transaction.addAction(endCallAction)
            requestTransaction(transaction: transaction) { success in
                self.postCallStatus(.refused)
                self.removeCall(uuid)
                if self.currentCall == uuid {
                    self.dismissCallScreen()
                    self.clearCurrentCallIfMatches(uuid)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    SocketSignaling.shared.close()
                }
            }
        }
    }

    func callBusy() {
        if let uuid = currentCall {
            markAppInitiatedEnd(uuid)
            let endCallAction = CXEndCallAction.init(call:uuid)
            let transaction = CXTransaction.init()
            transaction.addAction(endCallAction)
            requestTransaction(transaction: transaction) { success in
                self.postCallStatus(.busy)
                self.removeCall(uuid)
                if self.currentCall == uuid {
                    self.dismissCallScreen()
                    self.clearCurrentCallIfMatches(uuid)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    SocketSignaling.shared.close()
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
        markAppInitiatedEnd(uuid)
        let endCallAction = CXEndCallAction.init(call:uuid)
        let transaction = CXTransaction.init()
        transaction.addAction(endCallAction)
        requestTransaction(transaction: transaction) { success in
            SocketSignaling.shared.rejectCall()
            self.postCallStatus(.ended)
            self.removeCall(uuid)
            self.clearCurrentCallIfMatches(uuid)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                SocketSignaling.shared.close()
            }
        }
    }

    func cancelCall(uuid: UUID) {
        // Mark IMMEDIATELY (before any async operation)
        print("Marking call as cancelled: \(uuid)")
        insertCancelled(uuid)
        markAppInitiatedEnd(uuid)

        let endCallAction = CXEndCallAction.init(call:uuid)
        let transaction = CXTransaction.init()
        transaction.addAction(endCallAction)
        print("cancel call")
        requestTransaction(transaction: transaction) { success in
            SocketSignaling.shared.setCallState(.cancel)
            self.delegate?.onCallStateChanged(.cancel)
            self.postCallStatus(.ended)
            if self.currentCall == uuid {
                SocketSignaling.shared.releaseWebrtc()
                self.dismissCallScreen()
                self.clearCurrentCallIfMatches(uuid)
            }
            self.removeCall(uuid)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                SocketSignaling.shared.close()
            }

            // Clean up after 2 seconds (handle late callbacks)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                self.removeCancelled(uuid)
                print("Cleaned up cancelled call: \(uuid)")
            }
        }
    }

    func endCallOnDeniedMic() {
        if let uuid = self.currentCall {
            markAppInitiatedEnd(uuid)
            let endCallAction = CXEndCallAction.init(call:uuid)
            let transaction = CXTransaction.init()
            transaction.addAction(endCallAction)
            requestTransaction(transaction: transaction) { success in
                SocketSignaling.shared.setCallState(.ended)
                self.postCallStatus(.ended)
                SocketSignaling.shared.releaseWebrtc()
                self.removeCall(uuid)
                self.clearCurrentCallIfMatches(uuid)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    SocketSignaling.shared.close()
                }
            }
        }
    }

    func endCall(uuid: UUID?) {
        guard let uuid = uuid else {
            return
        }
        self.cancelIncomingCallTimer(for: uuid)
        markAppInitiatedEnd(uuid)
        let endCallAction = CXEndCallAction.init(call:uuid)
        let transaction = CXTransaction.init()
        transaction.addAction(endCallAction)
        requestTransaction(transaction: transaction) { success in
            SocketSignaling.shared.setCallState(.ended)
            self.postCallStatus(.ended)
            if self.currentCall == uuid {
                SocketSignaling.shared.releaseWebrtc()
                self.dismissCallScreen()
                self.clearCurrentCallIfMatches(uuid)
            }
            self.removeCall(uuid)
            // Tear down the signaling socket so its ping/pong + reconnect timers stop.
            // Delay 0.5s lets the REQUEST_HANGUP emit flush before the socket goes away.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                SocketSignaling.shared.close()
            }
        }
    }

    func endedCall(uuid: UUID?, callState: CallStatus) {
        guard let uuid = uuid else {
            return
        }
        self.cancelIncomingCallTimer(for: uuid)
        markAppInitiatedEnd(uuid)
        let endCallAction = CXEndCallAction.init(call:uuid)
        let transaction = CXTransaction.init()
        transaction.addAction(endCallAction)
        requestTransaction(transaction: transaction) { success in
            self.postCallStatus(callState)
            if self.currentCall == uuid {
                SocketSignaling.shared.releaseWebrtc()
                self.dismissCallScreen()
                self.clearCurrentCallIfMatches(uuid)
            }
            self.removeCall(uuid)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                SocketSignaling.shared.close()
            }
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

        self.postCallStatus(.connecting)
        self.updateCall(uuid: action.callUUID) { $0.callStatus = .connecting }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if (!self.screenIsShown) {
                self.showCallScreen(uuid: action.callUUID ,callStatus: "connecting")
            }
        }

        self.requestMicrophonePermission { granted in
            if !granted {
                self.sendMicPermissionNotification()
            }
        }

        let snapshot = self.calls
        for (uuid, _) in snapshot {
            if (uuid != action.callUUID) {
                self.endCall(uuid: uuid)
            } else {
                SocketSignaling.shared.answerCall() {
                    self.updateCall(uuid: action.callUUID) { $0.callStatus = .connected }
                    self.postCallStatus(.connected)
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
        print("Audio session activated")
        self.configureAudioSession()
        if let _ = currentCall {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                SocketSignaling.shared.initOffer()
            }
        }
    }
    
    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        print("Audio session deactivated")
        // WebRTC cleanup is handled by endCall/endedCall flows instead.
    }
    
    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        let uuid = action.callUUID
        defer { action.fulfill() }

        if consumeAppInitiatedEnd(uuid) {
            return
        }

        print("System-initiated end for \(uuid) — performing cleanup")
        self.cancelIncomingCallTimer(for: uuid)

        let info = self.getCall(uuid)
        let wasRingingIncoming = info?.callType == .INCOMING && info?.callStatus == .incoming

        if wasRingingIncoming {
            SocketSignaling.shared.rejectCall()
            self.postCallStatus(.refused)
        } else if info != nil {
            SocketSignaling.shared.setCallState(.ended)
            self.postCallStatus(.ended)
        }

        if self.currentCall == uuid {
            SocketSignaling.shared.releaseWebrtc()
            DispatchQueue.main.async { self.dismissCallScreen() }
            self.clearCurrentCallIfMatches(uuid)
        }
        self.removeCall(uuid)
        self.removeCancelled(uuid)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            SocketSignaling.shared.close()
        }
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
    
    private func postNetworkStatus(_ status: String, internetType: Bool = false) {
        NotificationCenter.default.post(name: .callNetworkChanged, object: nil, userInfo: ["error" : status, "internet": internetType])
    }
    
    private func configureAudioSession(_ isActivation: Bool = true) {
        let audioSession = AVAudioSession.sharedInstance()
        do {
            if audioSession.category != .playAndRecord {
                try audioSession.setCategory(AVAudioSession.Category.playAndRecord,
                                             options: [.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker, .mixWithOthers])
            }
            if audioSession.mode != .voiceChat {
                try audioSession.setMode(.voiceChat)
            }
            if (isActivation) {
                try audioSession.setActive(true)
            }
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
            print("Audio interruption began")
            // Audio has effectively stopped
            
        case .ended:
            print("Audio interruption ended")
            guard let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt else { return }
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            
            if options.contains(.shouldResume) {
                print("Resuming audio session...")
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
                print("Audio category changed")
            }
            
        case .override:
            print("Audio route override")
            
        case .wakeFromSleep:
            print("Device woke from sleep")
            // Reinitialize audio if in call
            if let _ = self.currentCall {
                configureAudioSession()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    SocketSignaling.shared.initOffer()
                }
            }
            
        case .noSuitableRouteForCategory:
            print("No suitable audio route")
            
        case .routeConfigurationChange:
            print("Audio route configuration changed")
            
        case .unknown:
            print("Audio unknown change")
            break
        @unknown default:
            break
        }
    }
    
    private func showCallScreen(uuid: UUID, callStatus: String) {
        guard let callInfo = self.getCall(uuid) else { return }
        self.screenIsShown = true
        // Tutup window lama jika ada
        self.callWindow?.isHidden = true
        self.callWindow = nil

        let vc: UIViewController
        if #available(iOS 13.0, *) {
            vc = UIHostingController(rootView: CallScreenWrapper(
                calleeName: callInfo.callName,
                callStatus: callStatus,
                avatarUrl: callInfo.callAvatar,
                metaData: self.metaData
            ))
        } else {
            let screen = CallScreenViewController()
            screen.callStatus = callStatus
            screen.calleeName = callInfo.callName
            screen.avatarUrl = callInfo.callAvatar
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

extension CallManager {
    func isInternetAvailable(completion: @escaping (Bool) -> Void) {
        let monitor = NWPathMonitor()
        let queue = DispatchQueue.global(qos: .background)
        var hasCompleted = false

        monitor.pathUpdateHandler = { path in
            guard !hasCompleted else { return }
            hasCompleted = true
            completion(path.status == .satisfied)
            monitor.cancel()
        }

        monitor.start(queue: queue)
        
        DispatchQueue.global().asyncAfter(deadline: .now() + 5.0) {
            guard !hasCompleted else { return }
            hasCompleted = true
            completion(false)
            monitor.cancel()
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
    func endCall(uuid: UUID?)
    func endedCall(uuid: UUID?, callState: CallStatus)
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
