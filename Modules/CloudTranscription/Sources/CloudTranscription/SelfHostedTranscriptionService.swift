// Copyright © 2026 Anton Novoselov. All rights reserved.

import Foundation
import Networking
import os
import TranscriptionCore

/// Client for a self-hosted sherpa-onnx transcription server (FastAPI).
///
/// Request contract:
///   POST {baseURL}/v1/transcribe
///   multipart form: `model` (e.g. "sensevoice", "qwen3-0.6b") + `audio` (file)
///   header: `Authorization: Bearer <apiKey>`
///   response: JSON with a `text` field.
///
/// SenseVoice quirk: its Japanese output separates words with spaces
/// ("抜群 の 運動 神経 ..."). When the transcribed text contains kana, the
/// spaces are formatting noise, so they are stripped for the sensevoice
/// model. Chinese output has no such spaces and English needs them, so the
/// strip only fires when kana is present.
public struct SelfHostedTranscriptionService: TranscriptionService, Sendable {
    private let logger = Logger(cloudTranscriptionCategory: "SelfHostedTranscription")

    public struct Config: Sendable {
        public let baseURL: URL
        public let apiKey: String
        public let modelName: String

        public init(baseURL: URL, apiKey: String, modelName: String) {
            self.baseURL = baseURL
            self.apiKey = apiKey
            self.modelName = modelName
        }
    }

    private let config: Config
    private let networkService: any NetworkService

    public init(
        config: Config,
        networkService: any NetworkService = DefaultNetworkService(category: "SelfHostedTranscription")
    ) {
        self.config = config
        self.networkService = networkService
    }

    public func transcribe(audioURL: URL) async throws -> TranscriptionServiceResult {
        let text = try await NetworkRetry.withRetry(logger: logger) {
            try await makeTranscriptionRequest(audioURL: audioURL)
        }
        return .plain(text)
    }

    private func makeTranscriptionRequest(audioURL: URL) async throws -> String {
        guard !config.apiKey.isEmpty else {
            throw CloudTranscriptionError.missingAPIKey
        }
        let apiURL = config.baseURL.appending(path: "v1/transcribe")

        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        // CPU transcription of a long clip can take minutes; the reference
        // server's nginx allows 300s, so match that here instead of the
        // 120s default other cloud services use.
        request.timeoutInterval = 300

        let body = try createRequestBody(audioURL: audioURL, boundary: boundary)

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await networkService.upload(request, from: body)
        } catch let error as NetworkError {
            throw error.asTranscriptionError()
        }

        guard (200...299).contains(response.statusCode) else {
            if response.statusCode == 401 {
                throw CloudTranscriptionError.invalidAPIKey
            }
            let message = (try? JSONDecoder().decode(ServerErrorResponse.self, from: data).detail) ?? ""
            throw CloudTranscriptionError.apiRequestFailed(statusCode: response.statusCode, message: message)
        }

        do {
            let transcriptionResponse = try JSONDecoder().decode(TranscriptionResponse.self, from: data)
            guard let text = transcriptionResponse.resolvedText, !text.isEmpty else {
                throw CloudTranscriptionError.noTranscriptionReturned
            }
            return cleanText(text)
        } catch let error as CloudTranscriptionError {
            throw error
        } catch {
            logger.logError("Failed to decode self-hosted transcription response: \(error.localizedDescription)")
            throw CloudTranscriptionError.noTranscriptionReturned
        }
    }

    private func createRequestBody(audioURL: URL, boundary: String) throws -> Data {
        var body = Data()
        let crlf = "\r\n"

        guard let audioData = try? Data(contentsOf: audioURL) else {
            throw CloudTranscriptionError.audioFileNotFound
        }

        body.append("--\(boundary)\(crlf)".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"model\"\(crlf)\(crlf)".data(using: .utf8)!)
        body.append(config.modelName.data(using: .utf8)!)
        body.append(crlf.data(using: .utf8)!)

        body.append("--\(boundary)\(crlf)".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"audio\"; filename=\"\(audioURL.lastPathComponent)\"\(crlf)".data(using: .utf8)!)
        body.append("Content-Type: \(audioURL.audioMIMEType)\(crlf)\(crlf)".data(using: .utf8)!)
        body.append(audioData)
        body.append(crlf.data(using: .utf8)!)

        body.append("--\(boundary)--\(crlf)".data(using: .utf8)!)

        return body
    }

    /// SenseVoice separates Japanese words with spaces; strip them when the
    /// text actually contains kana. Chinese has no such spaces and English
    /// needs them, so kana presence is the trigger.
    private func cleanText(_ text: String) -> String {
        guard config.modelName == "sensevoice", textContainsKana(text) else {
            return text
        }
        return text.replacing(" ", with: "").replacing("　", with: "")
    }

    private func textContainsKana(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x3040...0x309F).contains(scalar.value)  // Hiragana
            || (0x30A0...0x30FF).contains(scalar.value)  // Katakana
            || (0xFF66...0xFF9D).contains(scalar.value)  // Halfwidth katakana
        }
    }

    private struct TranscriptionResponse: Decodable {
        let text: String?
        let transcription: String?
        var resolvedText: String? { text ?? transcription }
    }

    private struct ServerErrorResponse: Decodable {
        let detail: String?
    }
}
