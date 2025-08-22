import Foundation

enum APIError: Error {
    case badURL
    case requestFailed(Error)
    case invalidResponse
    case decodingFailed(Error)
}

final class APIService: NSObject {

    static let shared = APIService()

    var baseURL: String!
    var apiKey: String!
    private let session: URLSession

    private override init() {
        self.session = .shared
    }

    // MARK: - Completion Handler (support iOS 12+)
    func request<T: Decodable>(
        path: String,
        method: String = "GET",
        query: [String: String]? = nil,
        body: Data? = nil,
        headers: [String: String]? = nil,
        completion: @escaping (Result<T, APIError>) -> Void
    ) {
        guard let base = baseURL, let baseUrl = URL(string: base) else {
            completion(.failure(.badURL))
            return
        }

        var components = URLComponents(url: baseUrl.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        if let query = query {
            components?.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components?.url else {
            completion(.failure(.badURL))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        if let authToken = apiKey {
            request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        }
        headers?.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }

        session.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(.failure(.requestFailed(error)))
                return
            }
            guard let http = response as? HTTPURLResponse,
                  200...299 ~= http.statusCode,
                  let data = data else {
                completion(.failure(.invalidResponse))
                return
            }
            do {
                let decoded = try JSONDecoder().decode(T.self, from: data)
                completion(.success(decoded))
            } catch {
                completion(.failure(.decodingFailed(error)))
            }
        }.resume()
    }

    // MARK: - Async/Await wrapper (iOS 13+)
    @available(iOS 13.0, *)
    func requestAsync<T: Decodable>(
        path: String,
        method: String = "GET",
        query: [String: String]? = nil,
        body: Data? = nil,
        headers: [String: String]? = nil
    ) async throws -> T {
        return try await withCheckedThrowingContinuation { continuation in
            self.request(
                path: path,
                method: method,
                query: query,
                body: body,
                headers: headers
            ) { (result: Result<T, APIError>) in
                switch result {
                case .success(let value):
                    continuation.resume(returning: value)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
