
//
//  SocketSignaling.swift
//  CicareSdkCall
//
//  Created by Mohammad Annas Al Hariri on 25/10/25.
//

import Foundation
import SocketIO
import WebRTC

protocol SignalingDelegate: AnyObject {
    func initReceive()
    func initCall()
}

enum SocketIOClientStatus: String {
    case connected
    case disconnected
}

enum SocketDisconnectReason {
    case network
    case server
    case unknown
}

class SocketSignaling: NSObject {
    
    static let shared = SocketSignaling()
    
    private var webrtcManager: WebRTCManager?
    private var manager: SocketManager?
    private var socket: SocketIOClient?
    
    private var connectStartTime: Date?
    private var pingStartTime: Date?
    private var timer: Timer?
    private var callState: CallStatus?
    
    private var uuid: UUID?
    
    private var isConnected = false
    private var pendingActions: [() -> Void] = []
    
    private var isCallConnected = false
    private var isReconnecting = false
    private let reconnectMax = 4
    private var reconnectAttempt: Int = 0
    
    private var disconnectTimer: Timer?
    private let disconnectGracePeriod: TimeInterval = 30.0  // 35 detik grace period (increased for better stability)
    private var disconnectStartTime: Date?  // Track when disconnect started
    
    override init() {
        super.init()
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
    
    func connect(wssUrl: URL, token: String, uuid: UUID, completion: @escaping (SocketIOClientStatus) -> Void) {
        self.uuid = uuid
        isCallConnected = false
        webrtcManager = WebRTCManager()
        self.webrtcManager?.callback = self
        manager = SocketManager(socketURL: wssUrl,
                                    config: [.log(false),
                                             .compress,
                                             .reconnectWait(2),
                                             .reconnectWaitMax(5),
                                             .reconnectAttempts(8),
                                             .forceNew(true),
                                             .forceWebsockets(true),
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
                } else {
                    NotificationCenter.default.post(name: .callNetworkChanged, object: nil, userInfo: ["signalStrength": "connected"])
                }
            }
            
            self.isConnected = true
            self.reconnectAttempt = 0
            
            self.cancelDisconnectTimer()
            
            if (self.isReconnecting) {
                CallManager.sharedInstance.postCallStatus(.reconnecting)
                self.emit("RECONNECT", [:])
                print("set reconnect false")
                self.isReconnecting = false
            }
            for action in self.pendingActions {
                action()
            }
            self.pendingActions.removeAll()
            self.startPingMonitoring()
            completion(.connected)
        }
        socket?.on(clientEvent: .disconnect) { _, _ in
            self.isConnected = false
            if (self.callState == CallStatus.connected) {
                CallManager.sharedInstance.postCallStatus(.reconnecting)
                //self.startDisconnectGracePeriod()
            } else {
                self.reconnectAttempt = self.reconnectMax
            }
        }
        socket?.on(clientEvent: .reconnect) { _, _ in
            NotificationCenter.default.post(name: .callNetworkChanged, object: nil, userInfo: ["signalStrength": "reconnecting"])
            self.isReconnecting = true
        }
        socket?.on(clientEvent: .error) { [weak self] data, ack in
            
            guard let self = self else { return }
            

            let errorDescription = self.parseSocketError(data)

            let reason = self.classifySocketErrorDescription(errorDescription)

            self.isConnected = false
            
            switch reason {

            case .network:
                if self.isReconnecting {
                    //self.startDisconnectGracePeriod()
                    NotificationCenter.default.post(name: .callNetworkChanged, object: nil, userInfo: ["signalStrength": "reconnecting"])
                    self.reconnectAttempt += 1
                    print("reconnecting attempt", self.reconnectAttempt)
                }

            case .server:
                CallManager.sharedInstance.endActiveCall()
                self.isConnected = false
                self.manager = nil
                self.socket = nil
                completion(.disconnected)
                self.close()

            case .unknown:
                if self.isReconnecting {
                    //self.startDisconnectGracePeriod()
                    self.reconnectAttempt += 1
                }
            }
            
            if (self.reconnectAttempt >= self.reconnectMax) {
                NotificationCenter.default.post(name: .callNetworkChanged, object: nil, userInfo: ["signalStrength": "lost"])
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    CallManager.sharedInstance.endActiveCall()
                    self.isConnected = false
                    self.manager = nil
                    self.socket = nil
                    completion(.disconnected)
                    self.close()
                }
            }
        }

        registerHandlers()
        socket?.connect()
    }
    
    public func reconnect() {
        self.isReconnecting = true
        socket?.connect()
    }
    
    private func startDisconnectGracePeriod() {
        // Only start if not already started (prevent multiple timers)
        guard disconnectTimer == nil else {
            return
        }
        
        disconnectStartTime = Date()
        print("⏱️ Starting disconnect grace period (\(disconnectGracePeriod)s)")
        
        disconnectTimer = Timer.scheduledTimer(withTimeInterval: disconnectGracePeriod, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            
            if !self.isConnected {
                if let start = self.disconnectStartTime {
                    let elapsed = Date().timeIntervalSince(start)
                    print("❌ Grace period expired after \(String(format: "%.1f", elapsed))s, closing call...")
                }
                NotificationCenter.default.post(name: .callNetworkChanged, object: nil, userInfo: ["error": "call_failed_no_connection"])
                self.close()
            } else {
                print("✅ Connected before grace period expired")
            }
            
            self.disconnectTimer = nil
            self.disconnectStartTime = nil
        }
    }
    
    private func cancelDisconnectTimer() {
        if disconnectTimer != nil {
            print("🛑 Cancelling disconnect grace period timer")
        }
        disconnectTimer?.invalidate()
        disconnectTimer = nil
        disconnectStartTime = nil
    }
    
    private func reinitWebRTC() {
        webrtcManager?.reinit()
        initOffer()
    }
    
    private func registerHandlers() {
        socket?.on("INIT_OK") { _, _ in
            self.initOffer()
        }
        socket?.on("PONG") { _, _ in
            self.handlePong()
        }
        socket?.on("ANSWER_OK") { _, _ in
        }
        socket?.on("MISSED_CALL") {_, _ in
            //self.onCallStateChanged(.missed)
            CallManager.sharedInstance.missedCall()
            self.close()
        }
        socket?.on("RINGING_OK") {_, _ in
        }
        socket?.on("ACCEPTED") { _, _ in
            //self.onCallStateChanged(.accepted)
            //self.socket?.emit("CONNECTED")
            CallManager.sharedInstance.callAccepted()
            if (!self.isCallConnected) {
                //CallManager.sharedInstance.callConnected()
                self.isCallConnected = true
            }
        }
        socket?.on("RECONNECTING") { _, _ in
            self.reinitWebRTC()
            CallManager.sharedInstance.postCallStatus(.reconnected)
            NotificationCenter.default.post(name: .callNetworkChanged, object: nil, userInfo: ["signalStrength": "connected"])
        }
        /*socket?.on("RECONNECTED") { _, _ in
            CallManager.sharedInstance.postCallStatus(.connected)
        }*/
        socket?.on("CONNECTED") { _, _ in
            //self.onCallStateChanged(.connected)
            //self.socket?.emit("CONNECTED")
            self.callState = .connected
            CallManager.sharedInstance.callConnected()
            if (!self.isCallConnected) {
                self.isCallConnected = true
            }
        }
        socket?.on("RINGING") { _, _ in
            CallManager.sharedInstance.callRinging()
        }
        socket?.on("HANGUP") { _, _ in
            if (self.callState != .ended && self.callState != .refused  && self.callState != .busy) {
                CallManager.sharedInstance.endedCall(uuid: self.uuid!, callState: .ended)
            }
            self.send(event: "CLEARING_SESSION", data: [:])
            self.close()
        }
        socket?.on("NO_ANSWER") { _, _ in
            CallManager.sharedInstance.endedCall(uuid: self.uuid!, callState: .timeout)
            self.send(event: "CLEARING_SESSION", data: [:])
            self.callState = nil
            //self.disconnect()
        }
        socket?.on("REJECTED") { _, _ in
            CallManager.sharedInstance.callRejected()
        }
        socket?.on("BUSY") { _, _ in
            CallManager.sharedInstance.callBusy()
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
            self.webrtcManager?.setRemoteDescription(sdp: sdp) { error in
            }
        }
    }
    
    private func startPingMonitoring() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            self.sendPing()
        }
    }

    private func sendPing() {
        if (pingStartTime == nil) {
            pingStartTime = Date()
            socket?.emit("PING")
        } else {
            handlePong()
        }
    }

    private func handlePong() {
        guard let start = pingStartTime else { return }
        let latency = Date().timeIntervalSince(start) * 1000
        if (!self.isReconnecting) {
            if latency > 300 {
                NotificationCenter.default.post(name: .callNetworkChanged, object: nil, userInfo: ["signalStrength": "weak"])
            } else {
                NotificationCenter.default.post(name: .callNetworkChanged, object: nil, userInfo: ["signalStrength": "other"])
            }
        }
        pingStartTime = nil
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
        callState = state
        switch state {
        case .busy:
            socket?.emitWithAck("BUSY", ["reason": "ended"]).timingOut(after: 3) { data in
                completion?()
            }
        case .cancel:
            socket?.emitWithAck("CANCEL", ["reason": "ended"]).timingOut(after: 3) { data in
                completion?()
            }
        case .ended:
            socket?.emitWithAck("REQUEST_HANGUP", ["reason": "ended"]).timingOut(after: 3) { data in
                completion?()
            }
        default:
            break
        }
    }
    
    func rejectCall() {
        callState = .ended
        emit("REJECT", [:])
    }
    
    func sendBusyCall(token: String) {
        emit("BUSY_CALL", ["token":token])
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
        callState = .connected
    }
    
    func send(event: String, data: [String: Any]) {
        if (self.isConnected) {
            socket?.emit(event, data)
        }
    }
    
    public func initOffer() {
        if let webrtc = self.webrtcManager {
            if (!webrtc.isPeerConnectionActive()) {
                webrtc.reinit()
            }
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
        } else {
            print("webrtc not initialized")
        }
    }
    
    public func releaseWebrtc() {
        webrtcManager?.close()
        webrtcManager = nil
    }
    
    func muteCall(_ mute: Bool) -> Bool {
        //self.send(event: "MUTE", data: ["mute": mute])
        let success = self.webrtcManager?.setMicEnabled(!mute);
        print("🎤 Mute call: \(mute), success: \(success ?? false)")
        return success ?? false
    }
    
    func isMicMuted() -> Bool {
        return webrtcManager?.isMuted() ?? false
    }
    
    func initCall() {
        if (callState == .cancel) {
            self.send(event: "CANCEL", data: [:])
        } else {
            self.send(event: "INIT_CALL", data: [:])
        }
    }
    
    func close() {
        guard isConnected else { return }
        isConnected = false
        isReconnecting = false
        self.reconnectAttempt = 0
        cancelDisconnectTimer()
        timer?.invalidate()
        timer = nil
        
        CallManager.sharedInstance.endCall(uuid: self.uuid!)
        socket?.disconnect()
        socket?.removeAllHandlers()
        socket = nil
        
    }
    
    deinit {
        close()
    }
}

extension SocketSignaling: WebRTCEventCallback {
    func onLocalSdpCreated(sdp: RTCSessionDescription) {
        send(event: "SDP_OFFER", data: ["sdp": sdp.sdp])
    }
    func onIceCandidateGenerated(candidate: RTCIceCandidate) {
        send(event: "ICE_CANDIDATE", data: ["candidate": candidate.sdp])
    }
    func onRemoteStreamReceived(stream: RTCMediaStream) {
        // optional: handle remote media stream
    }
    func onConnectionStateChanged(state: RTCPeerConnectionState) {
        // optional: map state to callEventListener if needed
    }
    func onIceConnectionStateChanged(state: RTCIceConnectionState) {
        
        switch state {
        case .disconnected:
            print("ice state disconnected")
            //NotificationCenter.default.post(name: .callNetworkChanged, object: nil, userInfo: ["signalStrength": "disconnected"])
            break
        case .failed:
            print("ice state failed")
            //NotificationCenter.default.post(name: .callNetworkChanged, object: nil, userInfo: ["signalStrength": "disconnected"])
            break
        case .closed:
            print("ice state closed")
            //NotificationCenter.default.post(name: .callNetworkChanged, object: nil, userInfo: ["signalStrength": "lost_connection"])
            if (self.callState == .connected || self.callState == .connecting) {
                reinitWebRTC()
            }
            break
        case .connected, .completed:
            print("ice state connected")
            //NotificationCenter.default.post(name: .callNetworkChanged, object: nil, userInfo: ["signalStrength": "connected"])
            break
        default:
            //NotificationCenter.default.post(name: .callNetworkChanged, object: nil, userInfo: ["signalStrength": "other"])
            break
        }
    }
    func onIceGatheringStateChanged(state: RTCIceGatheringState) {}
}

extension SocketSignaling {
    func classifySocketError(_ error: Error?) -> SocketDisconnectReason {
        guard let error = error else { return .unknown }

        let desc = error.localizedDescription.lowercased()

        if desc.contains("network") ||
           desc.contains("timeout") ||
           desc.contains("offline") ||
           desc.contains("not connected") ||
           desc.contains("connection reset") {
            return .network
        }

        if desc.contains("server") ||
           desc.contains("unauthorized") ||
           desc.contains("forbidden") {
            return .server
        }

        return .unknown
    }
    
    func parseSocketError(_ data: [Any]) -> String {
        guard let first = data.first else { return "unknown socket error" }

        if let dict = first as? [String: Any] {
            return dict["message"] as? String
                ?? dict["reason"] as? String
                ?? dict.description
        }

        if let str = first as? String {
            return str
        }

        return String(describing: first)
    }
    
    func classifySocketErrorDescription(_ desc: String) -> SocketDisconnectReason {
        let d = desc.lowercased()

        if d.contains("network")
            || d.contains("timeout")
            || d.contains("offline")
            || d.contains("not connected")
            || d.contains("connection reset") {
            return .network
        }

        if d.contains("unauthorized")
            || d.contains("forbidden")
            || d.contains("server")
            || d.contains("invalid token"){
            return .server
        }

        return .unknown
    }


}
