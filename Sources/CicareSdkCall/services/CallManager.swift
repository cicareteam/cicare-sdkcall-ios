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
    
    private var callWindow: UIWindow?

    private var delegate: CallManagerDelegate?
    private var provider: CXProvider?
    private var callController: CXCallController?
    
    private let callObserver = CXCallObserver()
    
    private var calls: [UUID: CallInfo] = [:]
    
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
    
    public func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
        isOutgoing = call.isOutgoing
        if call.hasEnded {
            delegate?.callDidEnd()
        } else if call.isOutgoing && !call.hasConnected && !call.hasEnded {
            delegate?.callInprogress()
        } else if call.hasConnected {
            delegate?.callDidConnected()
        //} else if !call.isOutgoing && !call.hasConnected && !call.hasEnded {
        //} else if !call.isOutgoing && call.hasConnected {
        //    delegate?.callDidConnected()
        }
    }
    
    public func providerDidReset(_ provider: CXProvider) {
        for (uuid, call) in calls {
            endCall(uuid: uuid)
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
        let incomingSocket = SocketSignaling(callService: self)
        self.metaData = metaData
        
        if var alertData = metaData["alert_data"] {
            extractServerData(alertData) { result in
                switch result {
                case .success(let data):
                    if let url = URL(string: data.server) {
                        incomingSocket.connect(wssUrl: url, token: data.token) {connected in
                            
                        }
                    }
                case .failure(let error):
                    completion(.failure(error))
                }
            }
        }
        
        incomingSocket.setCallState(.incoming)
        
        let inUUID = UUID()
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: callerName)
        update.localizedCallerName = callerName
        update.hasVideo = false
        
        provider?.reportNewIncomingCall(with: inUUID, update: update) { error in
            /*if (self.activeCall != nil) {
                incomingSocket.setCallState(.busy)
            }*/
            if let error = error {
                completion(.failure(error))
            } else {
                self.calls[inUUID] = CallInfo(
                    callId: callerId,
                    hasVideo: false,
                    callName: callerName,
                    callAvatar: avatarUrl,
                    callType: .INCOMING,
                    signaling: incomingSocket
                )
                incomingSocket.emit("RINGING_CALL", [:])
                completion(.success(()))
            }
        }
    }
    
    func endCall(uuid: UUID) {
        let endCallAction = CXEndCallAction.init(call:uuid)
        let transaction = CXTransaction.init()
        transaction.addAction(endCallAction)
        requestTransaction(transaction: transaction) { success in
            self.calls[uuid]?.signaling.setCallState(.ended)
            self.calls.removeValue(forKey: uuid)
        }
    }
    
    public func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if (!self.screenIsShown) {
                self.showCallScreen(uuid: action.callUUID ,callStatus: "connecting")
            }
        }
        
        self.postCallStatus(.connecting)
        
        for (uuid, call) in calls {
            if (uuid != action.callUUID) {
                endCall(uuid: uuid)
            } else {
                call.signaling.answerCall() {
                    self.postCallStatus(.connected)
                    self.configureAudioSession()
                    call.signaling.initOffer()
                }
            }
        }
        
    }
    
    private func postCallStatus(_ status: CallStatus) {
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
            //logger.error(msg: "Error configuring AVAudioSession: \(error.localizedDescription)")
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

    private func dismissCallScreen() {
        DispatchQueue.main.async {
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
    var signaling: SocketSignaling
}

protocol CallServiceDelegate: AnyObject {
    
}
