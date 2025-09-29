import Foundation
internal import SocketIO
import WebRTC

protocol CallEventListener: AnyObject {
    func onCallStateChanged(_ state: CallStatus)
}

enum SocketIOClientStatus: String {
    case connected
    case disconnected
}

class SocketManagerSignaling: NSObject {
    
    public static let shared = SocketManagerSignaling()
    
    private let webrtcManager: WebRTCManager = WebRTCManager.init()
    private var manager: SocketManager?
    private var socket: SocketIOClient?
    private var isConnected: Bool = false

    private override init() {
        super.init()
        self.webrtcManager.callback = self
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
                                             //.reconnects(true),
                                             .connectParams(["token": token])])
        socket = manager?.socket(forNamespace: "/")
        socket?.on(clientEvent: .statusChange) { data, _ in
                if let status = data.first as? SocketIOClientStatus {
                    completion(status)
                }
        }
        socket?.on(clientEvent: .connect) { _, _ in
            self.isConnected = true
            completion(.connected)
        }
        socket?.on(clientEvent: .disconnect) { _, _ in
            self.isConnected = false
            completion(.disconnected)
            self.manager = nil
            self.socket = nil
        }
        socket?.on(clientEvent: .error) { _, _ in
            self.isConnected = false
            completion(.disconnected)
        }


        registerHandlers()
        socket?.connect()
    }
    
    func initCall() {
        self.send(event: "INIT_CALL", data: [:])
    }
    
    func ringingCall() {
        self.send(event: "RINGING_CALL", data: [:])
    }
    
    func muteCall(_ mute: Bool) {
        self.webrtcManager.setMicEnabled(!mute);
    }

    private func registerHandlers() {
        socket?.on(clientEvent: .error) { error, arg  in print("socket error: \(error) \(arg)")
        }
        socket?.on(clientEvent: .statusChange) { data, _ in
        }
        socket?.on("INIT_OK") { _, _ in
            if (!self.webrtcManager.isPeerConnectionActive()) {
                self.webrtcManager.reinit()
            }
            self.webrtcManager.initMic()
            self.onCallStateChanged(.calling)
            self.webrtcManager.createOffer { result in
                switch result {
                case .success(let sdpDesc):
                    let sdpPayload: [String: String] = [
                        "type": "offer",
                        "sdp": sdpDesc.sdp
                    ]
                    let payload: [String: Any] = [
                        "is_caller": true,
                        "sdp": sdpPayload
                    ]
                    self.send(event: "SDP_OFFER", data: payload)
                case .failure(let error):
                    print("Failed to create offer:", error.localizedDescription)
                }
            }
        }
        socket?.on("ANSWER_OK") { _, _ in
            if (!self.webrtcManager.isPeerConnectionActive()) {
                self.webrtcManager.reinit()
            }
            self.onCallStateChanged(.answering)
            self.webrtcManager.initMic()
            self.webrtcManager.createOffer { result in
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
        socket?.on("MISSED_CALL") {_, _ in
            self.onCallStateChanged(.missed)
        }
        socket?.on("RINGING_OK") {_, _ in
            self.onCallStateChanged(.ringing_ok)
            print("ringing")
        }
        socket?.on("MISSED_CALL") {_, _ in
            self.onCallStateChanged(.ended)
        }
        socket?.on("ACCEPTED") { _, _ in
        }
        socket?.on("CONNECTED") { _, _ in
            self.onCallStateChanged(.connected)
            self.socket?.emit("CONNECTED")
        }
        socket?.on("RINGING") { _, _ in
            self.onCallStateChanged(.ringing)
        }
        socket?.on("HANGUP") { _, _ in
            self.onCallStateChanged(.ended)
        }
        socket?.on("REJECTED") { _, _ in
            self.onCallStateChanged(.refused)
        }
        socket?.on("BUSY") { _, _ in
            self.onCallStateChanged(.busy)
        }
        socket?.on("SDP_OFFER") { data, _ in
            guard let dict = data.first as? [String: Any],
                  let sdpStr = dict["sdp"] as? String else { return }
            DispatchQueue.main.async {
                self.onCallStateChanged(.connecting)
                self.webrtcManager.initMic()
                let sdp = RTCSessionDescription(type: .offer, sdp: sdpStr)
                self.webrtcManager.setRemoteDescription(sdp: sdp)
            }
        }
        socket?.on("SLOWLINK") { data, _ in
            
        }
        socket?.on("SDP_ANSWER") { data, _ in
            guard let dict = data.first as? [String: Any],
                  let sdpStr = dict["sdp"] as? String else { return }
            let sdp = RTCSessionDescription(type: .answer, sdp: sdpStr)
            self.webrtcManager.setRemoteDescription(sdp: sdp)
        }
    }

    func send(event: String, data: [String: Any]) {
        if (self.isConnected) {
            socket?.emit(event, data)
        }
    }

    func disconnect() {
        webrtcManager.close()
        if (self.isConnected) {
            print("disconnecting")
            socket?.removeAllHandlers()
            socket?.disconnect()
        }
        socket = nil
        manager = nil
        isConnected = false
    }
    
    func onCallStateChanged(_ state: CallStatus) {
        switch state {
        case .ringing_ok:
            CallService.sharedInstance.postCallStatus(state)
            break;
            //CallService.sharedInstance.ringing()
        case .missed:
            CallService.sharedInstance.missed()
        case .connected:
            break
        case .ringing:
            CallService.sharedInstance.postCallStatus(state)
            break
        case .ended:
            CallService.sharedInstance.endCall()
            break
        case .refused:
            CallService.sharedInstance.postCallStatus(state)
            //CallService.sharedInstance.declineCall()
            break
        case .busy:
            CallService.sharedInstance.postCallStatus(state)
            //CallService.sharedInstance.busyCall()
            break
        default:
            CallService.sharedInstance.postCallStatus(state)
            break
        }
    }
    
}

extension SocketManagerSignaling: WebRTCEventCallback {
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
            NotificationCenter.default.post(name: .callNetworkChanged, object: nil, userInfo: ["signalStrength": "disconnected"])
            break
        case .failed:
            NotificationCenter.default.post(name: .callNetworkChanged, object: nil, userInfo: ["signalStrength": "weak"])
            break
        case .closed:
            NotificationCenter.default.post(name: .callNetworkChanged, object: nil, userInfo: ["signalStrength": "lost"])
            break
        case .connected, .completed:
            NotificationCenter.default.post(name: .callNetworkChanged, object: nil, userInfo: ["signalStrength": "connected"])
            break
        default:
            NotificationCenter.default.post(name: .callNetworkChanged, object: nil, userInfo: ["signalStrength": "other"])
            break
        }
    }
    func onIceGatheringStateChanged(state: RTCIceGatheringState) {}
}
