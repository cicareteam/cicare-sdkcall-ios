import Foundation

struct ErrorResponse: Decodable {
    let code: Int?
    let message: String

    enum CodingKeys: String, CodingKey {
        case code
        case statusCode   // 🔹 tambahkan ini
        case message
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        // decode statusCode
        code = try container.decodeIfPresent(Int.self, forKey: .statusCode)
            ?? (try container.decodeIfPresent(Int.self, forKey: .code))
        
        // decode message bisa string atau array
        if let msgArray = try? container.decode([String].self, forKey: .message) {
            message = msgArray.joined(separator: "\n") // gabungkan array jadi string
        } else {
            message = try container.decode(String.self, forKey: .message)
        }
    }
}

enum APIError: Error {
    case badURL
    case requestFailed(Error)
    case invalidResponse(Error?)
    case decodingFailed(Error)
    case badRequest(ErrorResponse)
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
                  let data = data else {
                completion(.failure(.invalidResponse(error ?? nil)))
                return
            }
            // Cek status code
            switch http.statusCode {
            case 200...299:
                do {
                    let decoded = try JSONDecoder().decode(T.self, from: data)
                    completion(.success(decoded))
                } catch {
                    completion(.failure(.decodingFailed(error)))
                }

            case 400:
                do {
                    print("Raw JSON:\n", error ?? "nil")
                    let errorDecoded = try JSONDecoder().decode(ErrorResponse.self, from: data)
                    completion(.failure(.badRequest(errorDecoded)))
                } catch {
                    completion(.failure(.invalidResponse(error)))
                }

            default:
                completion(.failure(.invalidResponse(error)))
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
