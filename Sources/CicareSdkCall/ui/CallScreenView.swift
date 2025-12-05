import UIKit
import CallKit
import AVFoundation
import Network

public class CallScreenViewController: UIViewController {
    
    var calleeName: String = ""
    var callStatus: String = ""
    var avatarUrl: String? = ""
    var metaData: [String: String] = [:]
    var dismissed = true
    var pendingDismissed = false
    
    let monitor = NWPathMonitor()
    let queue = DispatchQueue.global(qos: .background)
    var isNetworkReallyDown = false
    var checkTimer: DispatchWorkItem?
    
    // MARK: - UI Elements
    private let nameLabel = UILabel()
    var statusLabel = UILabel()
    private let avatarImageView = UIImageView()
    private let connectionLabel = UILabel()
    private var incomingButtonStack: UIStackView!
    private var connectedButtonStack: UIStackView!
    
    private var muteButton: CircleIconButton!
    private var speakerButton: CircleIconButton!
    private var endButton: CircleIconButton!
    private var isMuted: Bool = false
    private var isSpeakerOn: Bool = false
    private var isConnected: Bool = false
    
    private var onMessageClicked: (() -> Void)?
    
    private var status: CallStatus?
    
    init(onMessageClicked: (() -> Void)? = nil) {
        super.init(nibName: nil, bundle: nil)
        self.onMessageClicked = onMessageClicked
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
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
    
    public override func viewDidLoad() {
        super.viewDidLoad()
        let gradientBackground = MultiLayerGradientView(frame: view.bounds)
        gradientBackground.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.insertSubview(gradientBackground, at: 0)
        
        monitor.pathUpdateHandler = { path in
            // Reset timer setiap ada perubahan path
            self.checkTimer?.cancel()

            if path.status == .unsatisfied {
                // Delay 3 detik untuk memastikan benar-benar tidak ada koneksi
                let task = DispatchWorkItem {
                    if self.monitor.currentPath.status == .unsatisfied {
                        DispatchQueue.main.async {
                            if !self.isNetworkReallyDown {
                                self.isNetworkReallyDown = true
                                self.showErrorConnectionAlert(
                                    text: self.metaData["call_failed_no_connection"] ?? "No internet connection",
                                    icon: nil
                                )
                            }
                        }
                    }
                }
                self.checkTimer = task
                DispatchQueue.global().asyncAfter(deadline: .now() + 3, execute: task)
            } else {
                // Kalau koneksi balik lagi
                self.isNetworkReallyDown = false
            }
        }
        monitor.start(queue: queue)

        setupUI()
        requestMicrophonePermission { granted in
            /*if !granted {
                CallManager.sharedInstance.endCallOnDeniedMic()
                self.showErrorConnectionAlert(text: self.metaData["call_failed_mic_permission_denied"] ?? "Call failed, mic permission denied",icon: nil)
            }*/
        }
        NotificationCenter.default.addObserver(self, selector: #selector(handleCallStatus(_:)), name: .callStatusChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(callProfileSet(_:)), name: .callProfileSet, object: "")
        NotificationCenter.default.addObserver(self, selector: #selector(handleNetworkSignal(_:)), name: .callNetworkChanged, object: nil)
        /*NotificationCenter.default.addObserver(
            self,
            selector: #selector(dismissScreen),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )*/
    }
    
    @objc private func handleNetworkSignal(_ notification: Notification) {
        guard let value = (notification.userInfo?["signalStrength"] as? String)
            ?? (notification.userInfo?["error"] as? String)
        else {
            return
        }
        DispatchQueue.main.async {
            if (self.isConnected) {
                switch value {
                case "weak":
                    self.connectionLabel.text = "\(self.metaData["call_weak_signal"] ?? "Weak signal")..."
                    self.connectionLabel.textColor = .systemRed
                case "lost":
                    self.connectionLabel.text = "\(self.metaData["call_lost_connection"] ?? "Lost connection")..."
                    self.connectionLabel.textColor = .systemRed
                case "reconnecting":
                    self.connectionLabel.text = "\(self.metaData["call_reconnecting"] ?? "Reconnecting")..."
                    self.connectionLabel.textColor = .systemRed
                default:
                    self.connectionLabel.text = ""
                }
            } else if (notification.userInfo?["error"] != nil) {
                self.showErrorConnectionAlert(text: self.metaData[value] ?? value, icon: AsssetKitImageProvider.Resources.errorIcon.image)
            }
        }
    }
    
    @objc private func callProfileSet(_ notification: Notification) {
        guard let nameString = notification.userInfo?["name"] as? String else { return }
        guard let avatarString = notification.userInfo?["avatar"] as? String else { return }
        DispatchQueue.main.async {
            
            self.calleeName = nameString
            
            if let callNameTitle = self.metaData["call_name_title"] {
                if (!callNameTitle.isEmpty) {
                    self.calleeName = callNameTitle
                }
            }
            
            self.nameLabel.text = self.calleeName
        }
        if let url = URL(string: avatarString) {
            URLSession.shared.dataTask(with: url) { data, _, _ in
                if let data = data {
                    DispatchQueue.main.async {
                        self.avatarImageView.image = UIImage(data: data)
                    }
                }
            }.resume()
        } else {
            if #available(iOS 13.0, *) {
                avatarImageView.image = UIImage(systemName: "person.fill")
            } else {
                avatarImageView.image = UIImage(named: "avatar_default")
            }
            avatarImageView.tintColor = .gray
        }
    }
    
    @objc private func handleCallStatus(_ notification: Notification) {
        guard let statusString = notification.userInfo?["status"] as? String,
              let status = CallStatus(rawValue: statusString) else { return }
        
        self.callStatus = status.rawValue
        DispatchQueue.main.async {
            self.endButton.button.isEnabled = true
        }
        
        DispatchQueue.main.async {
            switch status {
            case .incoming:
                self.isConnected = true
                self.statusLabel.text = self.metaData["call_incoming"]
                //self.updateUIForIncomingCall()
            case .calling:
                self.isConnected = true
                self.statusLabel.text = self.metaData["call_calling"] ?? "Calling..."
                //self.updateUIForOutgoingCall()
            case .ongoing:
                self.statusLabel.text = self.metaData["call_connected"] ?? "Connected"
            case .ended:
                self.statusLabel.text = self.metaData["call_end"] ?? "Call End"
                self.endedCall(delay: 0.5)
            case .accepted:
                self.statusLabel.text = self.metaData["call_accepted"] ?? "Call Accepted"
            case .connected:
                self.isConnected = true
                self.statusLabel.text = self.metaData["call_connected"] ?? "Connected"
                //NotificationManager.shared.showOngoingCallNotification(callee: self.calleeName)
                self.muteButton.isEnabled = true
                self.startCallDurationTimer()
                DispatchQueue.main.async {
                    self.incomingButtonStack.isHidden = true
                    self.connectedButtonStack.isHidden = false
                }
            case .connecting:
                self.isConnected = true
                self.statusLabel.text = self.metaData["call_connecting"] ?? "Connecting"
                DispatchQueue.main.async {
                    self.incomingButtonStack.isHidden = true
                    self.connectedButtonStack.isHidden = false
                }
                /*if CallService.sharedInstance.answeredButNotReady {
                    DispatchQueue.main.async {
                        self.incomingButtonStack.isHidden = true
                        self.connectedButtonStack.isHidden = false
                    }
                }*/
            case .ringing:
                self.statusLabel.text = self.metaData["call_ringing"] ?? "Ringing"
            case .answering:
                self.statusLabel.text = self.metaData["call_answering"] ?? "Answering"
            case .busy:
                self.statusLabel.text = self.metaData["call_busy"] ?? "Busy"
                self.endedCall(delay: 1.5)
            case .refused:
                self.statusLabel.text = self.metaData["call_refused"] ?? "Declined"
                self.endedCall(delay: 1.5)
            case .timeout:
                self.statusLabel.text = self.metaData["call_timeout"] ?? "No Answer"
                self.endedCall(delay: 1.5)
            case .cancel:
                self.statusLabel.text = self.metaData["call_cancel"] ?? "Canceled"
                self.endedCall()
            default:
                break;
            }
        }
        self.status = status
    }
    
    private func showErrorConnectionAlert(text: String, icon: UIImage?) {
        let toast = Alert(
            message: text,
            icon: icon
        ) {
            self.endedCall(delay: 0.0)
            CallManager.sharedInstance.endActiveCall()
            CallManager.sharedInstance.dismissCallScreen()
        }
        DispatchQueue.main.async {
            toast.show(in: self.view)
        }
    }

    func endedCall(delay: Double = 1.5) {
        //if (!dismissed) {
        self.isConnected = false
     //   self.pendingDismissed = true
        self.callDurationTimer?.invalidate()
        self.muteButton.isEnabled = false
        self.speakerButton.isEnabled = false
        self.endButton.isEnabled = false
        //print("end call")
        //}
        //SocketManagerSignaling.shared.disconnect()
    }
    
    /*@objc private func dismissScreen() {
        if (self.pendingDismissed) {
            self.dismissed = true
            self.pendingDismissed = false
            //print("dismissed")
            //CallService.sharedInstance.callVC = nil
            CallService.sharedInstance.closedCall()
        }
    }*/
    
    deinit {
        NotificationCenter.default.removeObserver(self)
        monitor.cancel()
    }
    
    func compatibleImage(named: String, systemName: String) -> UIImage? {
        if #available(iOS 13.0, *) {
            return UIImage(systemName: systemName) ?? UIImage(named: named)
        } else {
            return UIImage(named: named)
        }
    }
    
    private func setupUI() {
        self.dismissed = false
        self.pendingDismissed = false
        self.isConnected = false
        let titleLabel = UILabel()
        titleLabel.text = metaData["call_title"] ?? "Call Free"
        titleLabel.font = UIFont.boldSystemFont(ofSize: 22)
        titleLabel.textAlignment = .center
        titleLabel.textColor = .black
        
        let titleStack = UIStackView(arrangedSubviews: [titleLabel])
        titleStack.axis = .vertical
        titleStack.spacing = 10
        titleStack.alignment = .center
        titleStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(titleStack)
        
        statusLabel.text = self.metaData["call_\(callStatus)"] ?? callStatus
        statusLabel.font = UIFont.systemFont(ofSize: 16)
        statusLabel.textColor = .black
        statusLabel.textAlignment = .center
        
        // Stack setup for labels
        let statusStack = UIStackView(arrangedSubviews: [statusLabel])
        statusStack.axis = .vertical
        statusStack.spacing = 8
        statusStack.alignment = .center
        statusStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusStack)
        
        // Setup avatar
        avatarImageView.contentMode = .scaleAspectFill
        avatarImageView.layer.cornerRadius = 80
        avatarImageView.clipsToBounds = true
        avatarImageView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(avatarImageView)
        
        if let callNameTitle = metaData["call_name_title"] {
            if (!callNameTitle.isEmpty) {
                calleeName = callNameTitle
            }
        }
        
        nameLabel.text = calleeName
        nameLabel.font = UIFont.boldSystemFont(ofSize: 18)
        nameLabel.textColor = .black
        nameLabel.textAlignment = .center
        
        connectionLabel.text = ""
        connectionLabel.font = UIFont.systemFont(ofSize: 14)
        connectionLabel.textColor = .red
        connectionLabel.textAlignment = .center
        
        let nameLabelStack = UIStackView(arrangedSubviews: [nameLabel, connectionLabel])
        nameLabelStack.axis = .vertical
        nameLabelStack.spacing = 8
        nameLabelStack.alignment = .center
        nameLabelStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(nameLabelStack)

        // Load avatar from URL
        if let avatarUrl = avatarUrl, let url = URL(string: avatarUrl) {
            URLSession.shared.dataTask(with: url) { data, _, _ in
                if let data = data {
                    DispatchQueue.main.async {
                        self.avatarImageView.image = UIImage(data: data)
                    }
                }
            }.resume()
        } else {
            if #available(iOS 13.0, *) {
                avatarImageView.image = UIImage(systemName: "person.fill")
                avatarImageView.backgroundColor = .systemGray5
            } else {
                avatarImageView.image = AsssetKitImageProvider.Resources.avatarDefault.image
            }
            avatarImageView.tintColor = .black
        }

        // Stack setup for buttons
        incomingButtonStack = UIStackView(arrangedSubviews: incomingbuttons())
        incomingButtonStack.axis = .vertical
        incomingButtonStack.spacing = 50
        incomingButtonStack.alignment = .center
        incomingButtonStack.translatesAutoresizingMaskIntoConstraints = false
        incomingButtonStack.isUserInteractionEnabled = true
        view.addSubview(incomingButtonStack)
        
        connectedButtonStack = UIStackView(arrangedSubviews: connectedButtons())
        connectedButtonStack.axis = .vertical
        connectedButtonStack.spacing = 50
        connectedButtonStack.alignment = .center
        connectedButtonStack.translatesAutoresizingMaskIntoConstraints = false
        connectedButtonStack.isUserInteractionEnabled = true
        view.addSubview(connectedButtonStack)

        NSLayoutConstraint.activate([
            // labelStack at top
            titleStack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            titleStack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            
            statusStack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusStack.bottomAnchor.constraint(equalTo: avatarImageView.topAnchor, constant: -20),
            
            // avatar in center
            avatarImageView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            avatarImageView.bottomAnchor.constraint(equalTo: view.centerYAnchor, constant: -20),
            avatarImageView.widthAnchor.constraint(equalToConstant: 160),
            avatarImageView.heightAnchor.constraint(equalToConstant: 160),
            
            nameLabelStack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            nameLabelStack.topAnchor.constraint(equalTo: avatarImageView.bottomAnchor, constant: 30),
                        
            incomingButtonStack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            incomingButtonStack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -40),
            incomingButtonStack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 20),
            incomingButtonStack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -20),
            
            connectedButtonStack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            connectedButtonStack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -40),
            connectedButtonStack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 20),
            connectedButtonStack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -20)
        ])
        
        if (callStatus == "incoming")  {
            incomingButtonStack.isHidden = false
            connectedButtonStack.isHidden = true
        } else {
            incomingButtonStack.isHidden = true
            connectedButtonStack.isHidden = false
        }
    }
    
    var callDurationTimer: Timer?
    var secondsElapsed: Int = 0

    func startCallDurationTimer() {
        callDurationTimer?.invalidate()
        secondsElapsed = 0
        DispatchQueue.main.async {
          self.callDurationTimer = Timer.scheduledTimer(timeInterval: 1.0,
                                                        target: self,
                                                        selector: #selector(self.updateCallDuration),
                                                        userInfo: nil,
                                                        repeats: true)
        }
    }

    @objc func updateCallDuration() {
        secondsElapsed += 1
        let minutes = secondsElapsed / 60
        let seconds = secondsElapsed % 60
        self.statusLabel.text = String(format: "%02d:%02d", minutes, seconds)
    }
    
    private func incomingbuttons()-> [UIView]{
        // Initialize the buttons and add actions via closures
        muteButton = CircleIconButton(
            icon: compatibleImage(named: "mic.slash", systemName: "mic.slash"),
            labelText: self.metaData["call_btn_mute"] ?? "Mute",
            iconColor: UIColor(hex: "17666A")!,
            backgroundColor: UIColor(hex: "E9F8F9")!
        ) {
            if (SocketSignaling.shared.muteCall(!self.isMuted)) {
                print("view mute success")
                self.isMuted.toggle()
            }
            self.muteButton.icon = self.isMuted ? self.compatibleImage(named: "mic.slash", systemName: "mic.slash.fill") : self.compatibleImage(named: "mic.slash", systemName: "mic.slash")
            self.muteButton.button.tintColor = self.isMuted ? .white : UIColor(hex: "17666A")!
            self.muteButton.button.backgroundColor = self.isMuted ? UIColor(hex: "00BABD")! : UIColor(hex: "E9F8F9")!
            
        }
        muteButton.widthAnchor.constraint(equalToConstant: 64).isActive = true
        muteButton.isEnabled = false
        
        speakerButton = CircleIconButton(
            icon: compatibleImage(named: "speaker", systemName: "speaker.wave.2"),
            labelText: self.metaData["call_btn_speaker"] ?? "Speaker",
            iconColor: UIColor(hex: "17666A")!,
            backgroundColor: UIColor(hex: "E9F8F9")!
        ) {
            self.isSpeakerOn.toggle()
            self.speakerButton.icon = self.isSpeakerOn ? self.compatibleImage(named: "speaker", systemName: "speaker.wave.2.fill") : self.compatibleImage(named: "speaker", systemName: "speaker.wave.2")
            self.speakerButton.button.tintColor = self.isSpeakerOn ? .white : UIColor(hex: "17666A")!
            self.speakerButton.button.backgroundColor =  self.isSpeakerOn ? UIColor(hex: "00BABD")! : UIColor(hex: "E9F8F9")!
            let session = AVAudioSession.sharedInstance()
            do {
                try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth])
                try session.setActive(true)
                
                // Toggle the audio route to speaker or default (e.g., earphone)
                if self.isSpeakerOn {
                    try session.overrideOutputAudioPort(.speaker)
                } else {
                    try session.overrideOutputAudioPort(.none)
                }
            } catch {
                print("Failed to set audio session: \(error)")
            }
        }
        speakerButton.widthAnchor.constraint(equalToConstant: 64).isActive = true
        
        /*let messageButton = CircleIconButton(
            icon: compatibleImage(named: "message", systemName: "message"),
            labelText: self.metaData["call_btn_message"] ?? "Message",
            iconColor: UIColor(hex: "17666A")!,
            backgroundColor: UIColor(hex: "E9F8F9")!
        ) {
            self.onMessageClicked?()
            if CallState.shared.currentCallUUID != nil {
                CallService.sharedInstance.declineCall()
            }
        }
        messageButton.widthAnchor.constraint(equalToConstant: 64).isActive = true*/
        
        let audioButtonStack = UIStackView(arrangedSubviews: [speakerButton, muteButton/*, messageButton*/])
        audioButtonStack.axis = .horizontal
        audioButtonStack.spacing = 100
        audioButtonStack.distribution = .fillEqually
        audioButtonStack.alignment = .center
        audioButtonStack.translatesAutoresizingMaskIntoConstraints = false
        audioButtonStack.isUserInteractionEnabled = true
        
        let endCallButton = CircleIconButton(
            icon: compatibleImage(named: "xmark", systemName: "xmark"),
            labelText: "",
            iconColor: .white,
            backgroundColor: .red
        ) {
            //if CallState.shared.currentCallUUID != nil {
            //CallService.sharedInstance.declineCall()
            //} else {
            //    self.endedCall()
            //}
        }
        endCallButton.widthAnchor.constraint(equalToConstant: 64).isActive = true
        let answerCallButton = CircleIconButton(
            icon: compatibleImage(named: "phone.fill", systemName: "phone.fill"),
            labelText: "",
            iconColor: .white,
            backgroundColor: .green
        ) {
            //if let uuid = CallState.shared.currentCallUUID {
            //CallService.sharedInstance.answerCall()
            //}
        }
        answerCallButton.widthAnchor.constraint(equalToConstant: 64).isActive = true
        let actionButtonStack = UIStackView(arrangedSubviews: [endCallButton, answerCallButton])
        actionButtonStack.axis = .horizontal
        actionButtonStack.spacing = 150
        actionButtonStack.distribution = .fillEqually
        actionButtonStack.alignment = .fill
        actionButtonStack.translatesAutoresizingMaskIntoConstraints = false
        actionButtonStack.isUserInteractionEnabled = true
        return [audioButtonStack, actionButtonStack]
    }
    
    private func connectedButtons()-> [UIView]{
        // Initialize the buttons and add actions via closures
        muteButton = CircleIconButton(
            icon: compatibleImage(named: "mic.slash", systemName: "mic.slash"),
            labelText: self.metaData["call_btn_mute"] ?? "Mute",
            iconColor: UIColor(hex: "17666A")!,
            backgroundColor: UIColor(hex: "E9F8F9")!
        ) {
            if (SocketSignaling.shared.muteCall(!self.isMuted)) {
                print("view mute success")
                self.isMuted.toggle()
            }
            self.muteButton.icon = self.isMuted ? self.compatibleImage(named: "mic.slash", systemName: "mic.slash.fill") : self.compatibleImage(named: "mic.slash", systemName: "mic.slash")
            self.muteButton.button.tintColor = self.isMuted ? .white : UIColor(hex: "17666A")!
            self.muteButton.button.backgroundColor = self.isMuted ? UIColor(hex: "00BABD")! : UIColor(hex: "E9F8F9")!
        }
        muteButton.widthAnchor.constraint(equalToConstant: 64).isActive = true
        muteButton.isEnabled = false
        
        speakerButton = CircleIconButton(
            icon: compatibleImage(named: "speaker", systemName: "speaker.wave.2"),
            labelText: self.metaData["call_btn_speaker"] ?? "Speaker",
            iconColor: UIColor(hex: "17666A")!,
            backgroundColor: UIColor(hex: "E9F8F9")!
        ) {
            self.isSpeakerOn.toggle()
            self.speakerButton.icon = self.isSpeakerOn ? self.compatibleImage(named: "speaker", systemName: "speaker.wave.2.fill") : self.compatibleImage(named: "speaker", systemName: "speaker.wave.2")
            self.speakerButton.button.tintColor = self.isSpeakerOn ? .white : UIColor(hex: "17666A")!
            self.speakerButton.button.backgroundColor =  self.isSpeakerOn ? UIColor(hex: "00BABD")! : UIColor(hex: "E9F8F9")!
            let session = AVAudioSession.sharedInstance()
            do {
                try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth])
                try session.setActive(true)
                
                // Toggle the audio route to speaker or default (e.g., earphone)
                if self.isSpeakerOn {
                    try session.overrideOutputAudioPort(.speaker)
                } else {
                    try session.overrideOutputAudioPort(.none)
                }
            } catch {
                print("Failed to set audio session: \(error)")
            }
        }
        speakerButton.widthAnchor.constraint(equalToConstant: 64).isActive = true
        
        let audioButtonStack = UIStackView(arrangedSubviews: [speakerButton, muteButton])
        audioButtonStack.axis = .horizontal
        audioButtonStack.spacing = 100
        audioButtonStack.distribution = .fillEqually
        audioButtonStack.alignment = .center
        audioButtonStack.translatesAutoresizingMaskIntoConstraints = false
        audioButtonStack.isUserInteractionEnabled = true
        
        endButton = CircleIconButton(
            icon: compatibleImage(named: "xmark", systemName: "xmark"),
            labelText: "",
            iconColor: .white,
            backgroundColor: .red
        ) {
            CallManager.sharedInstance.endActiveCall()
            // Handle end call action here
        }
        endButton.widthAnchor.constraint(equalToConstant: 64).isActive = true
        
        return [audioButtonStack, endButton]
    }
    
}

extension UIColor {
  /// Initialize from hex string (supports 6 or 8 hex digits, with optional "#").
  public convenience init?(hex: String) {
    var hexStr = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    if hexStr.hasPrefix("#") {
      hexStr.removeFirst()
    }
    guard hexStr.count == 6 || hexStr.count == 8,
          let hexVal = UInt64(hexStr, radix: 16) else {
      return nil
    }
    let r, g, b, a: UInt64
    if hexStr.count == 6 {
      a = 255
      r = (hexVal >> 16) & 0xFF
      g = (hexVal >> 8) & 0xFF
      b = hexVal & 0xFF
    } else { // 8 characters = AARRGGBB
      a = (hexVal >> 24) & 0xFF
      r = (hexVal >> 16) & 0xFF
      g = (hexVal >> 8) & 0xFF
      b = hexVal & 0xFF
    }
    self.init(
      red: CGFloat(r) / 255,
      green: CGFloat(g) / 255,
      blue: CGFloat(b) / 255,
      alpha: CGFloat(a) / 255
    )
  }
}
