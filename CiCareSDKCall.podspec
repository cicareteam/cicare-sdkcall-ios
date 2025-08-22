


Pod::Spec.new do |spec|
  spec.name         = "CiCareSDKCall"
  spec.version      = "1.0.2"
  spec.summary      = "SDK for calling app to app webrtc."
  spec.description  = <<-DESC
    CiCareSDKCall is a SDK for calling app to app or app to phone via webrtc.
  DESC
  spec.homepage     = "https://github.com/cicareteam/c-icare-sdk-call-ios"
  spec.license      = { :type => "MIT", :file => "LICENSE" }
  spec.author       = { "C-icare Team" => "dev@c-icare.cc" }
  spec.platform     = :ios, "12.0"
  spec.swift_version = ['5.9', '5.10']

  # Source code SDK
  spec.source       = { :git => "https://github.com/cicareteam/c-icare-sdk-call-ios.git", :tag => spec.version.to_s }

  # Jika menggunakan source code
  spec.source_files = "Sources/CicareSdkCall/**/*.{swift,h,m}"

  # If use Framework binary
  # spec.vendored_frameworks = "Frameworks/MySDK.xcframework"

  # Dependencies (optional)
  spec.dependency "WebRTC-lib", "138.0.0"
  spec.dependency "Socket.IO-Client-Swift", "16.1.1"
  spec.dependency "Starscream", "4.0.8"
  spec.dependency "CryptoSwift", "1.8.4"
  
  # Build setting for module stability
  spec.pod_target_xcconfig = {
    "BUILD_LIBRARY_FOR_DISTRIBUTION" => "YES",
    "IPHONEOS_DEPLOYMENT_TARGET" => "12.0"
  }
end
