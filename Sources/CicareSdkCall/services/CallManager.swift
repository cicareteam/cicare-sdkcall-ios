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

final class CallManager: NSObject, CallServiceDelegate, CXCallObserverDelegate, CXProviderDelegate {
    
    static let sharedInstance: CallManager = CallManager()
    
    private var isOutgoing: Bool = false
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
    
    private override init() {
        super.init()
        setupCallKit()
    }
    
    private func setupCallKit() {
        let configuration = CXProviderConfiguration.init(localizedName: "CallKit")
        configuration.supportsVideo = false
        configuration.maximumCallsPerCallGroup = 1;
        configuration.supportedHandleTypes = [CXHandle.HandleType.generic]
        callObserver.setDelegate(self, queue: nil)
        provider = CXProvider.init(configuration: configuration)
        provider?.setDelegate(self, queue: nil)
        callObserver.setDelegate(self, queue: nil)
        
        callController = CXCallController.init()
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
    
    private func extractServerData (_ alertData: String, completion: @escaping (Result<(server: String, token: String, isFromPhone: Bool), Error>) -> Void) {
        var base64String = alertData
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
                    completion(.success((jsonObject["server"] as! String, jsonObject["token"] as! String, (jsonObject["isFromPhone"] != nil))))
                }
            } catch {
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
            //delegate?.callDidEnd()
        } else if call.isOutgoing && !call.hasConnected && !call.hasEnded {
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
        requestMicrophonePermission { granted in
            if (granted) {
                self.currentCall = UUID.init()
                if let unwrappedCurrentCall = self.currentCall {
                    self.calls[unwrappedCurrentCall] = CallInfo (
                        callId: calleeId,
                        hasVideo: false,
                        callName: calleeName,
                        callAvatar: calleeAvatar ?? "",
                        callType: .OUTGOING,
                        callStatus: .connecting,
                        signaling: SocketSignaling(callService: self, uuid: unwrappedCurrentCall)
                    )
                    let cxHandle = CXHandle(type: CXHandle.HandleType.generic, value: handle)
                    let action = CXStartCallAction.init(call: unwrappedCurrentCall, handle: cxHandle)
                    action.isVideo = false
                    let transaction = CXTransaction.init()
                    transaction.addAction(action)
                    self.requestTransaction(transaction: transaction) { success in
                        if success {
                            DispatchQueue.main.async {
                                self.showCallScreen(uuid: unwrappedCurrentCall, callStatus: "connecting")
                            }
                            NotificationManager.shared.showOutgoingCallNotification(callee: handle)
                            
                            guard let bodyData = try? JSONEncoder().encode(callData) else {
                                return
                            }
                            self.calls[unwrappedCurrentCall]?.callStatus = .connecting
                            self.calls[unwrappedCurrentCall]?.signaling.setCallState(.connecting)
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
                                            self.calls[unwrappedCurrentCall]?.signaling.connect(wssUrl: wssUrl, token: callSession.token) { status in
                                                if status == .connected {
                                                    self.calls[unwrappedCurrentCall]?.signaling.initCall()
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
                                            completion(.failure(CallError.internalServerError(code: 500, message: "Internal server error")))
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
        let inUUID = UUID()
        let incomingSocket = SocketSignaling(callService: self, uuid: inUUID)
        self.metaData = metaData
        
        if let alertData = metaData["alert_data"] {
            extractServerData(alertData) { result in
                switch result {
                case .success(let data):
                    if let url = URL(string: data.server) {
                        //DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        incomingSocket.connect(wssUrl: url, token: data.token) {connected in
                            
                        }
                        //}
                    }
                case .failure(let error):
                    completion(.failure(error))
                }
            }
        }
        self.postCallStatus(.incoming)
        incomingSocket.setCallState(.incoming)
        
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: callerName)
        update.localizedCallerName = callerName
        update.hasVideo = false
        
        provider?.reportNewIncomingCall(with: inUUID, update: update) { error in
            if (self.currentCall != nil) {
                incomingSocket.setCallState(.busy)
                self.provider?.reportCall(with: inUUID, endedAt: Date(), reason: .unanswered)
            }
            if let error = error {
                completion(.failure(error))
            } else {
                self.calls[inUUID] = CallInfo(
                    callId: callerId,
                    hasVideo: false,
                    callName: callerName,
                    callAvatar: avatarUrl,
                    callType: .INCOMING,
                    callStatus: .incoming,
                    signaling: incomingSocket
                )
                /*if (!self.screenIsShown && self.currentCall == nil) {
                    self.showCallScreen(uuid: inUUID, callStatus: "incoming")
                }*/
                incomingSocket.emit("RINGING_CALL", [:])
                completion(.success(()))
            }
        }
    }
    
    func muteCall(isMuted: Bool) {
        if let currentCall = currentCall {
            let muteAction = CXSetMutedCallAction(call: currentCall, muted: isMuted)
            let transaction = CXTransaction(action: muteAction)
            requestTransaction(transaction: transaction) { success in
                if (success) {
                    
                }
            }
        }
    }
    
    func endActiveCall() {
        for (uuid, call) in calls {
            if (call.callType == .OUTGOING && (call.callStatus == .connecting || call.callStatus == .calling)) {
                cancelCall(uuid: uuid)
            } else {
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
        let endCallAction = CXEndCallAction.init(call:uuid)
        let transaction = CXTransaction.init()
        transaction.addAction(endCallAction)
        requestTransaction(transaction: transaction) { success in
            self.calls[uuid]?.signaling.rejectCall()
            self.postCallStatus(.ended)
            self.calls.removeValue(forKey: uuid)
        }
    }
    
    func cancelCall(uuid: UUID) {
        let endCallAction = CXEndCallAction.init(call:uuid)
        let transaction = CXTransaction.init()
        transaction.addAction(endCallAction)
        requestTransaction(transaction: transaction) { success in
            self.calls[uuid]?.signaling.setCallState(.cancel)
            self.delegate?.onCallStateChanged(.cancel)
            self.postCallStatus(.ended)
            if (self.currentCall == uuid) {
                self.calls[uuid]?.signaling.releaseWebrtc()
                self.dismissCallScreen()
                self.currentCall = nil
            }
            self.calls.removeValue(forKey: uuid)
        }
    }
    
    func endCall(uuid: UUID) {
        let endCallAction = CXEndCallAction.init(call:uuid)
        let transaction = CXTransaction.init()
        transaction.addAction(endCallAction)
        requestTransaction(transaction: transaction) { success in
            self.calls[uuid]?.signaling.setCallState(.ended)
            self.postCallStatus(.ended)
            if (self.currentCall == uuid) {
                self.calls[uuid]?.signaling.releaseWebrtc()
                self.dismissCallScreen()
                self.currentCall = nil
            }
            self.calls.removeValue(forKey: uuid)
        }
    }
    
    func endedCall(uuid: UUID, callState: CallStatus) {
        
        let endCallAction = CXEndCallAction.init(call:uuid)
        let transaction = CXTransaction.init()
        transaction.addAction(endCallAction)
        requestTransaction(transaction: transaction) { success in
            self.postCallStatus(callState)
            if (self.currentCall == uuid) {
                self.calls[uuid]?.signaling.releaseWebrtc()
                self.dismissCallScreen()
                self.currentCall = nil
            }
            self.calls.removeValue(forKey: uuid)
            
        }
    }
    
    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        configureAudioSession()
        provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: nil)
        provider.reportOutgoingCall(with: action.callUUID, connectedAt: nil)
        action.fulfill()
    }
    
    public func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if (!self.screenIsShown) {
                self.showCallScreen(uuid: action.callUUID ,callStatus: "connecting")
            }
        }
        
        self.postCallStatus(.connecting)
        self.calls[action.callUUID]?.callStatus = .connecting
        
        self.requestMicrophonePermission { granted in
            if (granted) {
                for (uuid, call) in self.calls {
                    if (uuid != action.callUUID) {
                        self.endCall(uuid: uuid)
                    } else {
                        self.currentCall = action.callUUID
                        call.signaling.answerCall() {
                            self.calls[action.callUUID]?.callStatus = .connected
                            self.postCallStatus(.connected)
                            self.configureAudioSession()
                            call.signaling.initOffer()
                        }
                    }
                }
                action.fulfill()
            } else {
                action.fulfill()
                self.endCall(uuid: action.callUUID)
            }
        }
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
        calls[action.callUUID]?.signaling.muteCall(action.isMuted)
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
        if let currentCall = currentCall {
            calls[currentCall]?.signaling.initOffer()
        }
    }
    
    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        print("🔇 Audio session deactivated")
        if let currentCall = currentCall {
            calls[currentCall]?.signaling.releaseWebrtc()
        }
    }
    
    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        if (calls[action.callUUID]?.callStatus == .incoming) {
            rejectCall()
        } else if (self.screenIsShown) {
            self.dismissCallScreen()
        }
        action.fulfill()
    }
    
    private func postCallStatus(_ status: CallStatus) {
        delegate?.onCallStateChanged(status)
        NotificationCenter.default.post(name: .callStatusChanged, object: nil, userInfo: ["status" : status.rawValue])
    }
    
    private func postNetworkStatus(_ status: String) {
        NotificationCenter.default.post(name: .callNetworkChanged, object: nil, userInfo: ["error" : status])
    }
    
    private func configureAudioSession() {
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
            print("Error configuring AVAudioSession: \(error.localizedDescription)")
        }
    }
    
    private func showCallScreen(uuid: UUID, callStatus: String) {
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
    var signaling: SocketSignaling
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
