//
//  CryptoKeyManager.swift
//  CicareSdkCall
//
//  Created by Mohammad Annas Al Hariri on 08/01/26.
//


final class CryptoKeyManager {
    static let shared = CryptoKeyManager()

    private let keychainKey = "com.app.crypto.sessionKey"
    private let queue = DispatchQueue(label: "crypto.key.manager.queue")

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
        guard let url = URL(string: "\()/session-key") else {
            completion(.failure(NSError(domain: "CryptoKey", code: -1)))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10

        // Pastikan authenticated
        request.addValue("Bearer \(AuthManager.shared.token)", forHTTPHeaderField: "Authorization")

        URLSession.shared.dataTask(with: request) { data, _, error in
            if let error = error {
                completion(.failure(error))
                return
            }

            guard
                let data = data,
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let key = json["sessionKey"] as? String
            else {
                completion(.failure(NSError(domain: "CryptoKey", code: -2)))
                return
            }

            completion(.success(key))
        }.resume()
    }
}
