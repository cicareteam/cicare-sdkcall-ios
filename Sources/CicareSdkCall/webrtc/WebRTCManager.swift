//
//  WebRTCManager.swift
//  CicareSdkCall
//
//  Created by cicare.team on 29/07/25.
//

import Foundation
import WebRTC
import AVFAudio

protocol WebRTCEventCallback: AnyObject {
    func onLocalSdpCreated(sdp: RTCSessionDescription)
    func onIceCandidateGenerated(candidate: RTCIceCandidate)
    func onRemoteStreamReceived(stream: RTCMediaStream)
    func onConnectionStateChanged(state: RTCPeerConnectionState)
    func onIceConnectionStateChanged(state: RTCIceConnectionState)
    func onIceGatheringStateChanged(state: RTCIceGatheringState)
}

class WebRTCManager: NSObject {
    weak var callback: WebRTCEventCallback?
    private var peerConnection: RTCPeerConnection!
    private var peerConnectionFactory: RTCPeerConnectionFactory!
    private var audioTrack: RTCAudioTrack?
    private let iceServers = [RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302"])]
    
    // Track mute state to preserve across reconnections
    private var isMicMuted: Bool = false
    
    override init() {
        super.init()
        initializePeerConnectionFactory()
        createPeerConnection()
    }
    
    func reinit() {
        // State will be preserved (isMicMuted not reset)
        print("🔄 Reinitializing WebRTC, mute state: \(isMicMuted)")
        initializePeerConnectionFactory()
        createPeerConnection()
    }

    private func initializePeerConnectionFactory() {
        RTCInitializeSSL()
        let encoderFactory = RTCDefaultVideoEncoderFactory()
        let decoderFactory = RTCDefaultVideoDecoderFactory()
        peerConnectionFactory = RTCPeerConnectionFactory(encoderFactory: encoderFactory,
                                                         decoderFactory: decoderFactory)
    }

    private func createPeerConnection() {
        //print("peer created")
        let config = RTCConfiguration()
        config.iceServers = iceServers
        config.sdpSemantics = .unifiedPlan
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil,
                                              optionalConstraints: nil)
        peerConnection = peerConnectionFactory.peerConnection(with: config,
                                                              constraints: constraints,
                                                              delegate: self)
        peerConnection.statistics { reports in
            for report in reports.statistics.values {
                if report.type == "outbound-rtp" || report.type == "inbound-rtp" {
                    if let packetLoss = report.values["packetLoss"] as? String,
                       let rtt = report.values["roundTripTime"] as? String {
                        let packetLossValue = Int(packetLoss) ?? 0
                        let rttValue = Double(rtt) ?? 0
                        if packetLossValue > 10 || rttValue > 0.3 {
                            
                        }
                    }
                }
            }
        }
    }

    func initMic() {
        
        if peerConnection.transceivers.contains(where: { $0.mediaType == .audio }) {
            print("Audio transceiver already exists, skipping initMic")
            return
        }
        
        let audioSource = peerConnectionFactory.audioSource(with: RTCMediaConstraints(mandatoryConstraints: nil,
                                                                                      optionalConstraints: nil))
        
        audioTrack = peerConnectionFactory.audioTrack(with: audioSource, trackId: "audio101")
        let transceiverInit = RTCRtpTransceiverInit()
            transceiverInit.direction = .sendRecv
        
        if let transceiver = peerConnection.addTransceiver(of: .audio, init: transceiverInit) {
            transceiver.sender.track = audioTrack
        }
        
        // CRITICAL: Restore mute state after creating new track (for reconnection scenarios)
        if isMicMuted {
            print("♻️ Restoring muted state after reinit")
            setMicEnabled(false)
        }
        
        //peerConnection.addTransceiver(with: audioTrack!)
        
        /*audioTrack?.isEnabled = true
        if let track = audioTrack {
            peerConnection.add(track, streamIds: ["stream0"])
        }*/
    }

    func setAudioOutputToSpeaker(enabled: Bool) {
        let session = AVAudioSession.sharedInstance()
        do {
            //try session.setCategory(.playAndRecord, mode: .voiceChat, options: enabled ? .defaultToSpeaker : [])
            
            //try session.setActive(true)
            if (enabled) {
                try session.overrideOutputAudioPort(.speaker)
            } else {
                try session.overrideOutputAudioPort(.none)
            }
        } catch {
            print("Audio session error: \(error)")
        }
    }

    func createOffer(completion: @escaping (Result<RTCSessionDescription, Error>) -> Void) {
        let constraints = RTCMediaConstraints(mandatoryConstraints: ["OfferToReceiveAudio": "true",
                                                                     "OfferToReceiveVideo": "false"],
                                              optionalConstraints: nil)
        peerConnection.offer(for: constraints) { sdp, error in
            if let err = error {
                completion(.failure(err))
                return
            }
            guard let sdp = sdp else {
                completion(.failure(NSError(domain: "WebRTC", code: -1, userInfo: [NSLocalizedDescriptionKey: "SDP is nil"])))
                return
            }
            self.peerConnection.setLocalDescription(sdp) { setError in
                if let se = setError {
                    completion(.failure(se))
                } else {
                    completion(.success(sdp))
                }
            }
        }
    }

    func createAnswer(completion: @escaping (Result<RTCSessionDescription, Error>) -> Void) {
        let constraints = RTCMediaConstraints(mandatoryConstraints: ["OfferToReceiveAudio": "true",
                                                                     "OfferToReceiveVideo": "false"],
                                              optionalConstraints: nil)
        peerConnection.answer(for: constraints) { sdp, error in
            if let err = error {
                completion(.failure(err))
                return
            }
            guard let sdp = sdp else {
                completion(.failure(NSError(domain: "WebRTC", code: -1, userInfo: [NSLocalizedDescriptionKey: "SDP is nil"])))
                return
            }
            self.peerConnection.setLocalDescription(sdp) { setError in
                if let se = setError {
                    completion(.failure(se))
                } else {
                    completion(.success(sdp))
                }
            }
        }
    }

    func setRemoteDescription(sdp: RTCSessionDescription, completion: ((Error?) -> Void)? = nil) {
        let state = peerConnection.signalingState

        if sdp.type == .answer && state != .haveLocalOffer {
            print("Ignoring answer SDP, invalid state:", state)
            return
        }
        
        peerConnection.setRemoteDescription(sdp) { error in
          if let err = error {
            print("Remote SDP error: \(err)")
          } else {
            print("Remote SDP set successfully")
          }
          completion?(error)
        }
    }

    func isPeerConnectionActive() -> Bool {
        return peerConnection.signalingState != .closed
    }

    func setMicEnabled(_ enabled: Bool) -> Bool {
        // Update state FIRST before applying to track
        isMicMuted = !enabled
        print("🎤 Setting mic enabled: \(enabled), muted: \(isMicMuted)")
        
        if (audioTrack != nil) {
            peerConnection.transceivers
                        .compactMap { return $0.sender.track as? RTCAudioTrack }
                        .forEach { $0.isEnabled = enabled }
            print("audio \(enabled ? "enabled" : "disabled")")
            return true
        } else {
            print("audio track not set yet")
            return false
        }
        //RTCAudioSession.sharedInstance().isAudioEnabled = enabled
    }
    
    func isMuted() -> Bool {
        return isMicMuted
    }

    func close() {
        if (peerConnection.iceConnectionState == .connected ||
            peerConnection.iceConnectionState == .completed) {
            peerConnection.close()
            RTCShutdownInternalTracer()
        }
    }
}

extension WebRTCManager: RTCPeerConnectionDelegate {
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        callback?.onIceGatheringStateChanged(state: newState)
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        callback?.onRemoteStreamReceived(stream: stream)
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        callback?.onConnectionStateChanged(state: newState)
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        callback?.onIceConnectionStateChanged(state: newState)
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        callback?.onIceCandidateGenerated(candidate: candidate)
    }
    func peerConnection(_ peerConnection: RTCPeerConnection,
                        didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection,
                        didOpen dataChannel: RTCDataChannel) {}
    func peerConnection(_ peerConnection: RTCPeerConnection,
                        didStartReceivingOn transceiver: RTCRtpTransceiver) {}
}

