//
//  SocketSignaling.swift
//  CicareSdkCall
//
//  Created by Mohammad Annas Al Hariri on 25/10/25.
//

import Foundation
internal import SocketIO
import WebRTC

protocol SignalingDelegate: AnyObject {
    func initReceive()
    func initCall()
}

class SocketSignaling {
    
    private var webrtcManager: WebRTCManager?
    private var manager: SocketManager?
    private var socket: SocketIOClient?
    
    private var connectStartTime: Date?
    private var pingStartTime: Date?
    private var timer: Timer?
    private var callState: CallStatus?
    
    private var callService: CallServiceDelegate?
    
    private var isConnected = false
    private var pendingActions: [() -> Void] = []
    

    init(callService: CallServiceDelegate) {
        self.callService = callService 
    }
    
    func convertToWebSocket(url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme else {
            return nil
        }
        switch scheme.lowercased() {
        case "https":
            components.scheme = "wss"
        case "http":
            components.scheme = "ws"
        default:
            break
        }
        return components.url
    }
    
    func connect(wssUrl: URL, token: String, completion: @escaping (SocketIOClientStatus) -> Void) {
        manager = SocketManager(socketURL: wssUrl,
                                    config: [.log(false),
                                             .compress,
                                             .reconnects(true),
                                             .connectParams(["token": token])])
        socket = manager?.socket(forNamespace: "/")
        
        connectStartTime = Date()
        
        socket?.removeAllHandlers()

        socket?.on(clientEvent: .statusChange) { data, _ in
                if let status = data.first as? SocketIOClientStatus {
                    completion(status)
                }
        }
        socket?.on(clientEvent: .connect) { _, _ in
            if let start = self.connectStartTime {
                let elapsed = Date().timeIntervalSince(start)
                if elapsed > 1.5 {
                    NotificationCenter.default.post(name: .callNetworkChanged, object: nil, userInfo: ["signalStrength": "weak"])
                }
            }
            self.isConnected = true
            for action in self.pendingActions {
                action()
            }
            self.pendingActions.removeAll()
            self.startPingMonitoring()
            completion(.connected)
        }
        socket?.on(clientEvent: .disconnect) { _, _ in
            self.isConnected = false
            self.manager = nil
            self.socket = nil
            completion(.disconnected)
        }
        socket?.on(clientEvent: .error) { _, _ in
            self.isConnected = false
            self.manager = nil
            self.socket = nil
            completion(.disconnected)
        }

        registerHandlers()
        socket?.connect()
    }
    
    private func registerHandlers() {
        socket?.on("INIT_OK") { _, _ in
            self.initOffer()
        }
        socket?.on("PONG") { _, _ in
            self.handlePong()
        }
        socket?.on("ANSWER_OK") { _, _ in
            //print("answer_ok")
        }
        socket?.on("MISSED_CALL") {_, _ in
            //self.onCallStateChanged(.missed)
        }
        socket?.on("RINGING_OK") {_, _ in
        }
        socket?.on("ACCEPTED") { _, _ in
            //self.onCallStateChanged(.accepted)
            self.socket?.emit("CONNECTED")
        }
        socket?.on("CONNECTED") { _, _ in
            //self.onCallStateChanged(.connected)
            self.socket?.emit("CONNECTED")
        }
        socket?.on("RINGING") { _, _ in
            //self.onCallStateChanged(.ringing)
        }
        socket?.on("HANGUP") { _, _ in
            //print("receive hangup")
            if (self.callState != .cancel && self.callState != .refused && self.callState != .busy) {
                self.callState = .ended
            }
            if let callState = self.callState {
                //self.onCallStateChanged(callState)
            }
            self.send(event: "CLEARING_SESSION", data: [:])
            self.callState = nil
            //self.disconnect()
        }
        socket?.on("NO_ANSWER") { _, _ in
            //self.onCallStateChanged(.timeout)
            self.send(event: "CLEARING_SESSION", data: [:])
            self.callState = nil
            //self.disconnect()
        }
        socket?.on("REJECTED") { _, _ in
            //self.onCallStateChanged(.refused)
        }
        socket?.on("BUSY") { _, _ in
            //self.onCallStateChanged(.busy)
        }
        socket?.on("SDP_OFFER") { data, _ in
            guard let dict = data.first as? [String: Any],
                  let sdpStr = dict["sdp"] as? String else { return }
            DispatchQueue.main.async {
                //self.onCallStateChanged(.connecting)
                self.webrtcManager?.initMic()
                let sdp = RTCSessionDescription(type: .offer, sdp: sdpStr)
                self.webrtcManager?.setRemoteDescription(sdp: sdp)
            }
        }
        socket?.on("SLOWLINK") { data, _ in
            
        }
        socket?.on("SDP_ANSWER") { data, _ in
            guard let dict = data.first as? [String: Any],
                  let sdpStr = dict["sdp"] as? String else { return }
            let sdp = RTCSessionDescription(type: .answer, sdp: sdpStr)
            self.webrtcManager?.setRemoteDescription(sdp: sdp)
        }
    }
    
    private func startPingMonitoring() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            self.sendPing()
        }
    }

    private func sendPing() {
        pingStartTime = Date()
        socket?.emit("PING")
    }

    private func handlePong() {
        guard let start = pingStartTime else { return }
        let latency = Date().timeIntervalSince(start) * 1000
        if latency > 300 {
            NotificationCenter.default.post(name: .callNetworkChanged, object: nil, userInfo: ["signalStrength": "weak"])
        } else {
            NotificationCenter.default.post(name: .callNetworkChanged, object: nil, userInfo: ["signalStrength": "other"])
        }
    }
    
    func emit(_ event: String, _ data: [String: Any], completion: (() -> Void)? = nil) {
        if isConnected {
            socket?.emitWithAck(event, data).timingOut(after: 3) { data in
                completion?()
            }
        } else {
            pendingActions.append { [weak self] in
                self?.socket?.emitWithAck(event, data).timingOut(after: 3) { data in
                    completion?()
                }
            }
        }
    }
    
    func setCallState(_ state: CallStatus, completion: (() -> Void)? = nil) {
        switch state {
        case .ended:
            // kirim event hangup ke server
            socket?.emitWithAck("REQUEST_HANGUP", ["reason": "ended"]).timingOut(after: 3) { data in
                completion?()
            }
        default:
            break
        }
    }
    
    func answerCall(completion: (() -> Void)? = nil) {
        if isConnected {
            socket?.emitWithAck("ANSWER_CALL", [:]).timingOut(after: 3) { data in
                completion?()
            }
        } else {
            pendingActions.append { [weak self] in
                self?.socket?.emitWithAck("ANSWER_CALL", [:]).timingOut(after: 3) { data in
                    completion?()
                }
            }
        }
    }
    
    func send(event: String, data: [String: Any]) {
        if (self.isConnected) {
            //print("send \(event)")
            socket?.emit(event, data)
        }
    }
    
    public func initOffer() {
        if let webrtc = self.webrtcManager {
            if (!webrtc.isPeerConnectionActive()) {
                webrtc.reinit()
            }
            //self.onCallStateChanged(.answering)
            webrtc.initMic()
            webrtc.createOffer { result in
                switch result {
                case .success(let sdpDesc):
                    let sdpPayload: [String: Any] = [
                        "type": "offer",
                        "sdp": sdpDesc.sdp
                    ]
                    let payload: [String: Any] = [
                        "is_caller": false,
                        "sdp": sdpPayload
                    ]
                    self.send(event: "SDP_OFFER", data: payload)
                case .failure(let error):
                    print("Failed to create offer:", error.localizedDescription)
                }
            }
        }
    }
    
    public func releaseWebrtc() {
        webrtcManager?.close()
        webrtcManager = nil
    }
    
    func close() {
        guard isConnected else { return }
        isConnected = false
        
        socket?.disconnect()
        socket?.removeAllHandlers()
        socket = nil
        
    }
    
    deinit {
        close()
    }
}
