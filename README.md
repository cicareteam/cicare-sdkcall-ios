# CiCare SDK Call iOS

This SDK allows you to integrate **outgoing and incoming call features** into your iOS app using **CiCare SDK**.

## 📦 Installation

Add the CocoaPods source in your `Podfile`:

```ruby
source 'https://github.com/CocoaPods/Specs.git'

target 'YourAppTarget' do
  use_frameworks!
  pod 'CiCareSDKCallIOS', '1.2.0-alpha.4'
end
````

Then run:

```bash
pod install
```

---

## 🚀 Usage

### 1. Initialize & Setup API

Before starting a call, initialize the SDK and configure the API:

```swift
let cicare = CicareSdkCall()
cicare.setAPI(baseUrl: "https://your-api-url.com", token: "your-api-token")
```

---

### 2. Make an Outgoing Call

Use the following code to start an outgoing call:

```swift
func makeCall() {
    let cicare = CicareSdkCall()
    
    cicare.outgoing(
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

To display an incoming call, add the following code when handling the APNs notification:

```swift
let cicare = CicareSdkCall()

cicare.incoming(
    callerId: "2",
    callerName: "Halis",
    callerAvatar: "https://avatar.iran.liara.run/public/boy",
    calleeId: "3",
    calleeName: "Anas",
    calleeAvatar: "https://avatar.iran.liara.run/public",
    checkSum: "asdfasdf",
    server: "https://sip-gw.c-icare.cc:8443",
    token: token,
    isFormPhone: false,
    metaData: [:]
)
```

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

cicare.outgoing(
    callerId: "2",
    callerName: "Halis",
    callerAvatar: "https://avatar.iran.liara.run/public/boy",
    calleeId: "3",
    calleeName: "Anas",
    calleeAvatar: "https://avatar.iran.liara.run/public",
    checkSum: "asdfasdf",
    metaData: meta
)
```

---

## 🔗 References

* CocoaPods: [https://cocoapods.org/pods/CiCareSDKCallIOS](https://cocoapods.org/pods/CiCareSDKCallIOS)
* Latest version: **1.2.0-alpha.4**
