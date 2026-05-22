import Foundation

extension Foundation.Bundle {
    static let module: Bundle = {
        let mainPath = Bundle.main.bundleURL.appendingPathComponent("CicareSdkCall_CicareSdkCall.bundle").path
        let buildPath = "/Users/annaselh/PROJECT/Swift/sdk-1.2.1-rc.43/.build/index-build/arm64-apple-macosx/debug/CicareSdkCall_CicareSdkCall.bundle"

        let preferredBundle = Bundle(path: mainPath)

        guard let bundle = preferredBundle ?? Bundle(path: buildPath) else {
            // Users can write a function called fatalError themselves, we should be resilient against that.
            Swift.fatalError("could not load resource bundle: from \(mainPath) or \(buildPath)")
        }

        return bundle
    }()
}