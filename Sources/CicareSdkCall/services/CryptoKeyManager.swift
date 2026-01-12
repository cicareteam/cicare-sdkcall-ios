//
//  CryptoKeyManager.swift
//  CicareSdkCall
//
//  Created by Mohammad Annas Al Hariri on 08/01/26.
//
import Foundation
import Security

enum KeychainHelper {

    @discardableResult
    static func save(_ value: String, for key: String) -> Bool {
        guard let data = value.data(using: .utf8) else {
            return false
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        // Remove existing item if any
        SecItemDelete(query as CFDictionary)

        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    static func read(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard
            status == errSecSuccess,
            let data = result as? Data,
            let value = String(data: data, encoding: .utf8)
        else {
            return nil
        }

        return value
    }

    static func delete(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key
        ]

        SecItemDelete(query as CFDictionary)
    }
}


final class CryptoKeyManager {
    static let shared = CryptoKeyManager()

    private let keychainKey = "com.app.crypto.sessionKey"
    private let queue = DispatchQueue(label: "crypto.key.manager.queue")
    
    var baseUrl = ""
    var token = ""

    private init() {}

    func getKey(completion: @escaping (Result<String, Error>) -> Void) {
        queue.async {
            if let cachedKey = KeychainHelper.read(self.keychainKey) {
                completion(.success(cachedKey))
                return
            }

            self.fetchKeyFromServer { result in
                switch result {
                case .success(let key):
                    KeychainHelper.save(key, for: self.keychainKey)
                    completion(.success(key))
                case .failure(let error):
                    completion(.failure(error))
                }
            }
        }
    }
}

private extension CryptoKeyManager {
    func fetchKeyFromServer(
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        guard let url = URL(string: "\(baseUrl)/api/u/encrypt-key") else {
            completion(.failure(NSError(domain: "CryptoKey", code: -1)))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10

        // Pastikan authenticated
        request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        URLSession.shared.dataTask(with: request) { data, _, error in
            if let error = error {
                completion(.failure(error))
                return
            }

            guard
                let data = data,
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let key = json["key"] as? String
            else {
                completion(.failure(NSError(domain: "CryptoKey", code: -2)))
                return
            }
            print("key \(key)")

            completion(.success(key))
        }.resume()
    }
}
