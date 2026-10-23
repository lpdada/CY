import Foundation

/// Client for the self-hosted TTS endpoints (GET /v1/voices, POST /v1/tts).
/// Same server and Bearer key as self-hosted transcription; only the paths
/// differ. Requests are short: one translated sentence at a time, so the
/// server returns a complete WAV instead of streaming.
struct ServerTTSClient: Sendable {
    let baseURL: URL
    let apiKey: String

    func fetchVoices() async throws -> [ServerTTSVoice] {
        var request = URLRequest(url: baseURL.appending(path: "v1/voices"))
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        let (data, status) = try await perform(request)
        guard status == 200 else { throw ServerTTSError.httpStatus(status) }
        do {
            return try JSONDecoder().decode(ServerTTSVoiceListResponse.self, from: data).voices
        } catch {
            throw ServerTTSError.decoding(error)
        }
    }

    /// Synthesizes one sentence and returns the audio bytes (WAV).
    func synthesize(text: String, voiceID: String, languageCode: String) async throws -> Data {
        var request = URLRequest(url: baseURL.appending(path: "v1/tts"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30
        request.httpBody = try JSONEncoder().encode(
            SynthesisRequest(text: text, voice: voiceID, language: languageCode)
        )
        let (data, status) = try await perform(request)
        guard status == 200 else { throw ServerTTSError.httpStatus(status) }
        guard !data.isEmpty else { throw ServerTTSError.emptyAudio }
        return data
    }

    private func perform(_ request: URLRequest) async throws -> (Data, Int) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ServerTTSError.unexpectedResponse
        }
        return (data, httpResponse.statusCode)
    }

    private struct SynthesisRequest: Encodable {
        let text: String
        let voice: String
        let language: String
    }
}

enum ServerTTSError: Error, LocalizedError {
    case httpStatus(Int)
    case emptyAudio
    case decoding(Error)
    case unexpectedResponse

    var errorDescription: String? {
        switch self {
        case .httpStatus(let status):
            "服务器返回 \(status)"
        case .emptyAudio:
            "服务器返回了空音频"
        case .decoding:
            "服务器声音列表解析失败"
        case .unexpectedResponse:
            "服务器响应异常"
        }
    }
}
