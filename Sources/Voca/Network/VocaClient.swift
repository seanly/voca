import Foundation
import os.log

private let logger = Logger(subsystem: "com.yetone.Voca", category: "VocaClient")

/// HTTP client for communicating with dmr-plugin-voca server.
final class VocaClient {
    let baseURL: String
    let authToken: String
    private let session: URLSession

    init(baseURL: String, authToken: String) {
        self.baseURL = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        self.authToken = authToken
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config)
    }

    // MARK: - Health Check

    func health(completion: @escaping (Bool) -> Void) {
        guard let url = URL(string: "\(baseURL)/v1/health") else {
            completion(false)
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        session.dataTask(with: request) { data, response, error in
            if let error {
                logger.warning("Health check failed: \(error.localizedDescription)")
                completion(false)
                return
            }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                completion(false)
                return
            }
            completion(true)
        }.resume()
    }

    // MARK: - Transcribe (audio mode)

    struct TranscribeResult: Codable {
        let text: String
        let raw: String
        let language: String?
        let refined: Bool
        let duration: Double?
    }

    func transcribe(
        audio: Data,
        format: String,
        language: String,
        appContext: String?,
        completion: @escaping (Result<TranscribeResult, Error>) -> Void
    ) {
        guard let url = URL(string: "\(baseURL)/v1/transcribe") else {
            completion(.failure(VocaClientError.invalidURL))
            return
        }

        let boundary = UUID().uuidString
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        addAuth(&request)

        var body = Data()
        // Audio file
        body.appendMultipart(boundary: boundary, name: "audio", filename: "audio.\(format)", contentType: "application/octet-stream", data: audio)
        // Fields
        body.appendMultipartField(boundary: boundary, name: "format", value: format)
        body.appendMultipartField(boundary: boundary, name: "language", value: language)
        if let ctx = appContext { body.appendMultipartField(boundary: boundary, name: "app_context", value: ctx) }
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        session.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(error))
                return
            }
            guard let data else {
                completion(.failure(VocaClientError.emptyResponse))
                return
            }
            do {
                let result = try JSONDecoder().decode(TranscribeResult.self, from: data)
                completion(.success(result))
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }

    // MARK: - Transcribe (text passthrough mode, for Apple Speech local results)

    func refineText(
        text: String,
        language: String,
        appContext: String?,
        completion: @escaping (Result<TranscribeResult, Error>) -> Void
    ) {
        guard let url = URL(string: "\(baseURL)/v1/transcribe") else {
            completion(.failure(VocaClientError.invalidURL))
            return
        }

        let boundary = UUID().uuidString
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        addAuth(&request)

        var body = Data()
        body.appendMultipartField(boundary: boundary, name: "mode", value: "text")
        body.appendMultipartField(boundary: boundary, name: "text", value: text)
        body.appendMultipartField(boundary: boundary, name: "language", value: language)
        if let ctx = appContext { body.appendMultipartField(boundary: boundary, name: "app_context", value: ctx) }
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        session.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(error))
                return
            }
            guard let data else {
                completion(.failure(VocaClientError.emptyResponse))
                return
            }
            do {
                let result = try JSONDecoder().decode(TranscribeResult.self, from: data)
                completion(.success(result))
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }

    // MARK: - History

    struct HistoryResponse: Codable {
        let entries: [HistoryEntry]
        let total: Int
    }

    struct HistoryEntry: Codable {
        let id: Int
        let timestamp: String
        let raw_text: String
        let refined_text: String
        let language: String?
        let app_context: String?
        let refined: Bool
    }

    func history(limit: Int = 50, query: String? = nil, completion: @escaping (Result<HistoryResponse, Error>) -> Void) {
        var components = URLComponents(string: "\(baseURL)/v1/history")!
        var queryItems = [URLQueryItem(name: "limit", value: "\(limit)")]
        if let q = query, !q.isEmpty {
            queryItems.append(URLQueryItem(name: "q", value: q))
        }
        components.queryItems = queryItems

        guard let url = components.url else {
            completion(.failure(VocaClientError.invalidURL))
            return
        }

        var request = URLRequest(url: url)
        addAuth(&request)

        session.dataTask(with: request) { data, _, error in
            if let error { completion(.failure(error)); return }
            guard let data else { completion(.failure(VocaClientError.emptyResponse)); return }
            do {
                let result = try JSONDecoder().decode(HistoryResponse.self, from: data)
                completion(.success(result))
            } catch { completion(.failure(error)) }
        }.resume()
    }

    // MARK: - Private

    private func addAuth(_ request: inout URLRequest) {
        if !authToken.isEmpty {
            request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        }
    }

    enum VocaClientError: LocalizedError {
        case invalidURL
        case emptyResponse

        var errorDescription: String? {
            switch self {
            case .invalidURL: return "Invalid server URL"
            case .emptyResponse: return "Empty response from server"
            }
        }
    }
}

// MARK: - Data multipart helpers

private extension Data {
    mutating func appendMultipartField(boundary: String, name: String, value: String) {
        append("--\(boundary)\r\n".data(using: .utf8)!)
        append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
        append("\(value)\r\n".data(using: .utf8)!)
    }

    mutating func appendMultipart(boundary: String, name: String, filename: String, contentType: String, data: Data) {
        append("--\(boundary)\r\n".data(using: .utf8)!)
        append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        append("Content-Type: \(contentType)\r\n\r\n".data(using: .utf8)!)
        append(data)
        append("\r\n".data(using: .utf8)!)
    }
}
