/*import Foundation
 import WebRTC

 public class WebRTCClient {
     private var peerConnectionFactory: RTCPeerConnectionFactory
     private var peerConnection: RTCPeerConnection?
     private var localAudioTrack: RTCAudioTrack?
     private var remoteAudioTrack: RTCAudioTrack?

     public init() {
         RTCInitializeSSL()
         self.peerConnectionFactory = RTCPeerConnectionFactory()
     }

     public func createPeerConnection() {
         let config = RTCConfiguration()
         config.sdpSemantics = .unifiedPlan

         let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)

         self.peerConnection = peerConnectionFactory.peerConnection(with: config, constraints: constraints, delegate: nil)
     }

     public func startCall() {
         guard let peerConnection = peerConnection else {
             print("PeerConnection is nil")
             return
         }

         let audioSource = peerConnectionFactory.audioSource(with: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil))
         let audioTrack = peerConnectionFactory.audioTrack(with: audioSource, trackId: "audio0")
         self.localAudioTrack = audioTrack

         let audioSender = peerConnection.add(audioTrack, streamIds: ["stream0"])
         print("AudioSender added: \(String(describing: audioSender))")
     }

     public func sendOffer(completion: @escaping (RTCSessionDescription?) -> Void) {
         let constraints = RTCMediaConstraints(mandatoryConstraints: ["OfferToReceiveAudio": "true"], optionalConstraints: nil)

         peerConnection?.offer(for: constraints, completionHandler: { offer, error in
             if let error = error {
                 print("Offer error: \(error)")
                 completion(nil)
             } else if let offer = offer {
                 self.peerConnection?.setLocalDescription(offer, completionHandler: { error in
                     if let error = error {
                         print("SetLocalDescription error: \(error)")
                         completion(nil)
                     } else {
                         completion(offer)
                     }
                 })
             }
         })
     }

     public func receiveOffer(_ offer: RTCSessionDescription, completion: @escaping (RTCSessionDescription?) -> Void) {
         peerConnection?.setRemoteDescription(offer, completionHandler: { error in
             if let error = error {
                 print("SetRemoteDescription error: \(error)")
                 completion(nil)
                 return
             }

             let constraints = RTCMediaConstraints(mandatoryConstraints: ["OfferToReceiveAudio": "true"], optionalConstraints: nil)

             self.peerConnection?.answer(for: constraints, completionHandler: { answer, error in
                 if let error = error {
                     print("Answer error: \(error)")
                     completion(nil)
                 } else if let answer = answer {
                     self.peerConnection?.setLocalDescription(answer, completionHandler:

*/
