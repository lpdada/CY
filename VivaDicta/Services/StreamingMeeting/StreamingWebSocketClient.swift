import Foundation
import os

/// Server-side speaker confirmation state, carried verbatim from the
/// streaming contract's `speaker_status` field.
enum StreamingSpeakerStatus: String, Sendable {
    case provisional
    case confirmed
    case uncertain
}

/// One segment affected by a `speaker_update` frame, keyed by the
/// contract's `segment_id` (never by list position).
struct StreamingSpeakerUpdateSegment: Sendable {
    let segmentID: String
    let speakerLabel: String?
}

/// Failure of the streaming connection. A server `error` frame keeps its
/// `code` verbatim: the session layer matches
/// `streaming_unsupported_language` on it to fall back to the old path,
/// so this type must never rewrite or localise the code.
enum StreamingError: Error, Sendable {
    case transport(String)
    case server(code: String, message: String)

    /// The server error code, if this failure came from an `error` frame.
    var serverCode: String? {
        if case .server(let code, _) = self { return code }
        return nil
    }

    var message: String {
        switch self {
        case .transport(let text): return text
        case .server(_, let text): return text
        }
    }
}

/// URLSessionWebSocketTask client for the self-hosted streaming ASR
/// endpoint. It speaks exactly one wire contract (see `Event`); every
/// field name below matches the contract, including the snake_case
/// names, which are mapped through explicit `CodingKeys`.
///
/// Flow: `connect` opens the socket and sends the `auth` frame as the
/// first text frame, then starts the receive loop. The caller owns the
/// ready wait: the first `Event` is normally `.ready`, and an `error`
/// frame before it surfaces as `.failed` instead of being swallowed.
/// Audio goes out as binary frames; `sendEnd` sends the `{"type":"end"}`
/// frame. An `error` frame mid-session is yielded as `.failed` but does
/// NOT close the stream (the server may keep going); a transport failure
/// or `session_end` does finish the stream.
actor StreamingWebSocketClient {
    enum Event: Sendable {
        case ready
        case interimSegment(
            segmentID: String,
            text: String,
            speakerLabel: String?,
            start: Double,
            end: Double
        )
        case finalSegment(
            segmentID: String,
            text: String,
            speakerLabel: String?,
            status: StreamingSpeakerStatus,
            confidence: Double?,
            start: Double,
            end: Double,
            corrected: Bool
        )
        case speakerUpdated(
            remap: [String: String],
            segments: [StreamingSpeakerUpdateSegment]
        )
        case failed(StreamingError)
        case sessionEnded
    }

    private let logger = Logger(category: .selfHostedTranslation)
    private var task: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var continuation: AsyncStream<Event>.Continuation?

    /// Opens the socket for `serverURL` (its scheme is converted
    /// http->ws / https->wss and `/v1/stream` is appended; the host is
    /// never hard-coded) and sends the auth frame. Returns the event
    /// stream; the caller waits for `.ready` on it.
    ///
    /// - Parameters:
    ///   - language: BCP-style code the server expects, e.g. "zh".
    ///   - maxSpeakers: forwarded as `max_speakers` in the auth frame.
    func connect(
        serverURL: URL,
        apiKey: String,
        language: String,
        maxSpeakers: Int
    ) -> AsyncStream<Event> {
        disconnect()

        let (stream, continuation) = AsyncStream<Event>.makeStream()
        self.continuation = continuation

        guard let url = Self.streamURL(from: serverURL) else {
            continuation.yield(.failed(.transport("无法从服务器地址拼出流式地址")))
            continuation.finish()
            self.continuation = nil
            return stream
        }

        let session = URLSession(configuration: .default)
        let task = session.webSocketTask(with: url)
        self.task = task
        task.resume()

        let auth: [String: Any] = [
            "type": "auth",
            // Raw key, no "Bearer " prefix: the contract says so.
            "token": apiKey,
            "language": language,
            "max_speakers": maxSpeakers,
            "offline_correction": true,
            "session_id": UUID().uuidString
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: auth)
            let message = URLSessionWebSocketTask.Message.string(String(decoding: data, as: UTF8.self))
            task.send(message) { [weak self] error in
                if let error {
                    Task { await self?.emitFailure(.transport("auth 发送失败：\(error.localizedDescription)")) }
                }
            }
        } catch {
            emitFailure(.transport("auth 编码失败：\(error.localizedDescription)"))
            return stream
        }

        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }
        return stream
    }

    /// Sends one chunk of 16 kHz mono PCM16 audio as a binary frame.
    /// Callers forward `StreamingAudioCapture`'s stream verbatim: that
    /// capture is already 16 kHz mono Int16 (see its `sampleRate` and
    /// `captureFormat`), so no resampling or second capture is needed.
    func sendAudioChunk(_ data: Data) {
        guard let task else { return }
        task.send(.data(data)) { [weak self] error in
            if let error {
                Task { await self?.emitFailure(.transport("音频发送失败：\(error.localizedDescription)")) }
            }
        }
    }

    /// Sends the contract's end frame. The caller still disconnects
    /// afterwards (see `StreamingMeetingSession.stop`): the end frame
    /// asks the server to finish, it does not close the socket by itself.
    func sendEnd() {
        guard let task else { return }
        task.send(.string(#"{"type":"end"}"#)) { _ in }
    }

    /// Idempotent. Finishing the continuation ends the caller's event
    /// loop; the nil checks make a repeated call a no-op.
    func disconnect() {
        receiveTask?.cancel()
        receiveTask = nil
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        if let continuation {
            self.continuation = nil
            continuation.finish()
        }
    }

    // MARK: - Private

    /// http(s) -> ws(s) + `/v1/stream`. A path already on the base URL
    /// is kept as a prefix; the config URL is normally bare-host.
    static func streamURL(from serverURL: URL) -> URL? {
        guard var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        switch components.scheme {
        case "http": components.scheme = "ws"
        case "https": components.scheme = "wss"
        case "ws", "wss": break
        default: return nil
        }
        let basePath = components.path
        let trimmedBase = basePath.hasSuffix("/") ? String(basePath.dropLast()) : basePath
        components.path = trimmedBase + "/v1/stream"
        return components.url
    }

    private func receiveLoop() async {
        guard let task else { return }
        while !Task.isCancelled {
            do {
                let message = try await task.receive()
                handleMessage(message)
                // `session_end` and failures finish the continuation;
                // once it is gone there is nothing left to receive.
                if continuation == nil { return }
            } catch {
                if !Task.isCancelled {
                    emitFailure(.transport("接收失败：\(error.localizedDescription)"))
                }
                return
            }
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        let text: String?
        switch message {
        case .string(let value): text = value
        case .data(let data): text = String(data: data, encoding: .utf8)
        @unknown default: text = nil
        }
        guard let text, let data = text.data(using: .utf8) else { return }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
            logger.logError("流式：无法解析服务器帧")
            return
        }
        switch envelope.type {
        case "ready":
            continuation?.yield(.ready)
        case "interim":
            guard let segmentID = envelope.segmentID, let segmentText = envelope.text else { return }
            continuation?.yield(.interimSegment(
                segmentID: segmentID,
                text: segmentText,
                speakerLabel: envelope.speakerLabel,
                start: envelope.start ?? 0,
                end: envelope.end ?? 0
            ))
        case "final":
            guard let segmentID = envelope.segmentID, let segmentText = envelope.text else { return }
            let status: StreamingSpeakerStatus
            switch envelope.speakerStatus {
            case "uncertain": status = .uncertain
            case "provisional": status = .provisional
            default: status = .confirmed
            }
            continuation?.yield(.finalSegment(
                segmentID: segmentID,
                text: segmentText,
                speakerLabel: envelope.speakerLabel,
                status: status,
                confidence: envelope.confidence,
                start: envelope.start ?? 0,
                end: envelope.end ?? 0,
                corrected: envelope.corrected ?? false
            ))
        case "speaker_update":
            let segments = (envelope.segments ?? []).map {
                StreamingSpeakerUpdateSegment(segmentID: $0.segmentID, speakerLabel: $0.speakerLabel)
            }
            continuation?.yield(.speakerUpdated(remap: envelope.remap ?? [:], segments: segments))
        case "error":
            // Verbatim passthrough: the session matches
            // `streaming_unsupported_language` on `code` for fallback.
            // The stream stays open; only the session decides whether
            // this error is fatal (before ready) or just a status line.
            continuation?.yield(.failed(.server(
                code: envelope.code ?? "",
                message: envelope.message ?? "服务器错误"
            )))
        case "session_end":
            continuation?.yield(.sessionEnded)
            if let continuation {
                self.continuation = nil
                continuation.finish()
            }
        default:
            break
        }
    }

    private func emitFailure(_ error: StreamingError) {
        logger.logError("流式：\(error.message)")
        continuation?.yield(.failed(error))
        if let continuation {
            self.continuation = nil
            continuation.finish()
        }
    }

    /// One frame of the streaming contract. All names are the contract's
    /// names, not Swift-style renames; `speaker_label` is optional
    /// because interim frames carry null until a speaker is assigned.
    private struct Envelope: Decodable {
        let type: String
        let segmentID: String?
        let text: String?
        let speakerLabel: String?
        let speakerStatus: String?
        let start: Double?
        let end: Double?
        let confidence: Double?
        let corrected: Bool?
        let remap: [String: String]?
        let segments: [EnvelopeSegment]?
        let code: String?
        let message: String?

        enum CodingKeys: String, CodingKey {
            case type
            case segmentID = "segment_id"
            case text
            case speakerLabel = "speaker_label"
            case speakerStatus = "speaker_status"
            case start
            case end
            case confidence
            case corrected
            case remap
            case segments
            case code
            case message
        }

        struct EnvelopeSegment: Decodable {
            let segmentID: String
            let speakerLabel: String?

            enum CodingKeys: String, CodingKey {
                case segmentID = "segment_id"
                case speakerLabel = "speaker_label"
            }
        }
    }
}
