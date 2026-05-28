import Foundation

enum HuggingFaceClient {
    enum TokenResult {
        case valid
        case invalid
        case network(String)
    }

    enum ModelResult {
        case granted
        case denied
        case notFound
        case unauthorized
        case network(String)
    }

    static func validateToken(_ token: String) async -> TokenResult {
        guard let url = URL(string: "https://huggingface.co/api/whoami-v2") else {
            return .network("invalid url")
        }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("openXTranscriber", forHTTPHeaderField: "User-Agent")
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 200: return .valid
            case 401, 403: return .invalid
            default: return .network("HTTP \(status)")
            }
        } catch {
            return .network(error.localizedDescription)
        }
    }

    static func checkModelAccess(modelID: String, token: String) async -> ModelResult {
        guard let url = URL(string: "https://huggingface.co/api/models/\(modelID)") else {
            return .network("invalid url")
        }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("openXTranscriber", forHTTPHeaderField: "User-Agent")
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 200: return .granted
            case 401: return .unauthorized
            case 403: return .denied
            case 404: return .notFound
            default: return .network("HTTP \(status)")
            }
        } catch {
            return .network(error.localizedDescription)
        }
    }
}
