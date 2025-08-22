Berikut **README.md** yang siap dipakai untuk dokumentasi penggunaan SDK kamu.

---

````markdown
# CiCare SDK Call iOS

SDK untuk mengintegrasikan fitur **call (outgoing & incoming)** ke dalam aplikasi iOS Anda menggunakan **CiCare SDK**.

## 📦 Instalasi

Tambahkan source CocoaPods pada `Podfile`:

```ruby
source 'https://github.com/CocoaPods/Specs.git'

target 'YourAppTarget' do
  use_frameworks!
  pod 'CiCareSDKCallIOS', '1.2.0-alpha.3'
end
````

Lalu jalankan:

```bash
pod install
```

---

## 🚀 Cara Menggunakan

### 1. Inisialisasi & Setup API

Sebelum memulai panggilan, lakukan inisialisasi SDK dan konfigurasi API:

```swift
let cicare = CicareSdkCall()
cicare.setAPI(baseUrl: "https://your-api-url.com", token: "your-api-token")
```

---

### 2. Melakukan Outgoing Call

Gunakan kode berikut untuk memulai panggilan keluar:

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
        metaData: ["call_title": "Call Gratis"]
    )
}
```

---

### 3. Menangani Incoming Call

Untuk menampilkan panggilan masuk:

```swift
func handleIncomingCall(token: String) {
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
}
```

---

## ⚙ Metadata Opsional

Anda dapat menyesuaikan teks label atau status panggilan dengan `metaData`.
Contoh penggunaan:

```swift
let meta: [String: String] = [
    "call_title": "Gratis Call",
    "call_busy": "User sedang sibuk",
    "call_weak_signal": "Sinyal lemah"
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

## 🔗 Referensi

* CocoaPods: [https://cocoapods.org/pods/CiCareSDKCallIOS](https://cocoapods.org/pods/CiCareSDKCallIOS)
* Versi terbaru: **1.2.0-alpha.3**

---

