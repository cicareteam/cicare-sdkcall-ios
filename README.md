# CiCare SDK Call iOS

This SDK allows you to integrate **outgoing and incoming call features** into your iOS app using **CiCare SDK**.

---

## 📦 Installation

Add the CocoaPods source in your `Podfile`:

```ruby
source 'https://github.com/CocoaPods/Specs.git'

target 'YourAppTarget' do
  use_frameworks!
  pod 'CiCareSDKCallIOS', '1.2.1-rc.25'
end
````

Then run:

```bash
pod install
```

---

## ⚙ iOS Setup Requirements

### 1. Enable Push Notification & VoIP

1. Open your Xcode project settings → **Signing & Capabilities**.
2. Add the following capabilities:

   * **Push Notifications**
   * **Background Modes** → Check:

     * `Voice over IP`
     * `Background fetch`
     * `Remote notifications`

---

### 2. Add Permissions in `Info.plist`

Add these keys for proper permission descriptions:

```xml
<key>UIBackgroundModes</key>
<array>
    <string>voip</string>
    <string>fetch</string>
    <string>remote-notification</string>
</array>
<key>NSUserNotificationUsageDescription</key>
<string>This app uses notifications to alert you for incoming calls.</string>
<key>NSMicrophoneUsageDescription</key>
<string>This app requires microphone access for voice calls.</string>
```

---

### 3. APNs Configuration

* Configure your app in the **Apple Developer Console**.
* Enable Push Notifications and generate the **VoIP Services Certificate**.
* Use the generated credentials for your server to send VoIP push notifications.

---

## 🚀 Usage

### 1. Initialize & Setup API

Import module:

```swift
import CicareSdkCall
```

Before starting a call, configure the API:

```swift
CicareSdkCall.shared.setAPI(baseUrl: "https://your-api-url.com", token: "your-api-token")
```

---

### 2. Make an Outgoing Call

Use the following code to start an outgoing call:

```swift
func makeCall() {
    CicareSdkCall.shared.outgoing(
        callerId: "2",
        callerName: "Halis",
        callerAvatar: "https://avatar.iran.liara.run/public/boy",
        calleeId: "3",
        calleeName: "Anas",
        calleeAvatar: "https://avatar.iran.liara.run/public",
        checkSum: "asdfasdf",
        metaData: ["call_title": "Free Call"]
    )
}
```

---

### 3. Handle Incoming Calls

To display an incoming call, add the following code when handling the VoIP type APNs notification:

```swift
CicareSdkCall.shared.incoming(
    callerId: "2",
    callerName: "Halis",
    callerAvatar: "https://avatar.iran.liara.run/public/boy",
    calleeId: "3",
    calleeName: "Anas",
    calleeAvatar: "https://avatar.iran.liara.run/public",
    checkSum: "asdfasdf",
    metaData: [:]
) {
    print("on message button clicked")
}
```

> **Note**: `metaData["alert_data"]` is required.

---

## ⚙ Optional Metadata

You can customize call labels or status texts using the `metaData` parameter.

Example:

```swift
let meta: [String: String] = [
    "call_title": "Free Call",
    "call_busy": "User is busy",
    "call_weak_signal": "Weak signal"
]

CicareSdkCall.shared.outgoing(
    callerId: "2",
    callerName: "Halis",
    callerAvatar: "https://avatar.iran.liara.run/public/boy",
    calleeId: "3",
    calleeName: "Anas",
    calleeAvatar: "https://avatar.iran.liara.run/public",
    checkSum: "asdfasdf",
    metaData: meta
) { result in

}
```

## ⚙ Call State Listener
You can get call state event by doing this
```swift

class CallEventDelegate: CallEventListener {
    CicareSdkCall.shared.delegate = this
    
    public func onCallStateChanged(_ state: CallStatus) {
        print(state)
    }

}

```
State list are:
* connecting: For outgoing it is trying to reach the server
* calling: Outgoing call is in progress
* ringing: Outgoing call is ringing on the callee
* accepted: Outgoing call is accepted by the callee
* connected: The call is connected in callee or in caller
* end: The call is end normally
* refused: The call is end cause refused by the callee
* busy: The call is end cause the callee busy
* cancel: Outgoing call is canceled
* timeout: Outgoing call is not answered by the callee
---

## Outgoing call error result and code
When you make an outgoign call there are error code result
```swift
CicareSdkCall.shared.outgoing(...) { result in
            switch result {
                case .success:
                    print("Call success")
                case .failure(let error):
                print("Error:", error.numericCode, error.localizedDescription)
            }
}
```
Error code list are:
* 101: Mic permission denied
* 401: Api unauthorized
* 400: Some field is required
* 505: Server not found
* 500: Internal server error
* 3: Call not found
* some code is return from api checksum server

## 🔗 References

* CocoaPods: [https://cocoapods.org/pods/CiCareSDKCallIOS](https://cocoapods.org/pods/CiCareSDKCallIOS)
* Latest version: **1.2.1-rc.25**
* Apple Docs:

  * [Push Notifications](https://developer.apple.com/documentation/usernotifications)
  * [VoIP Push Notifications](https://developer.apple.com/documentation/pushkit)
  * [Microphone Permissions](https://developer.apple.com/documentation/avfoundation/capturing_setup)

---

## 🛠 Notes

* `CicareSdkCall` is a **singleton**, always use `CicareSdkCall.shared` instead of creating a new instance.
* Ensure **APNs VoIP certificate** or **token authentication** is correctly set up.
* Test notifications and calls on a **real device** (VoIP push is not supported in simulators).
* Make sure to request microphone permission before initiating a call.
