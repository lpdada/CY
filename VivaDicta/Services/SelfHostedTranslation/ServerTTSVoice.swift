import AppGroup
import Foundation

/// One voice offered by the self-hosted TTS endpoint (GET /v1/voices).
/// The id is opaque to the app: it is sent back verbatim to POST /v1/tts,
/// so new server voices show up in the picker without an app update.
struct ServerTTSVoice: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let language: String
    let engine: String

    var displayName: String { name }
}

struct ServerTTSVoiceListResponse: Decodable {
    let voices: [ServerTTSVoice]
}

/// The server voice chosen for readout, remembered per target language
/// (a Chinese voice cannot read Japanese text well, and vice versa).
/// A missing entry means "system default voice" for that language.
enum ServerTTSVoiceSelection {
    private static func key(forLanguageCode code: String) -> String {
        "serverTTSVoice_\(code)"
    }

    static func voiceID(forLanguageCode code: String) -> String? {
        let id = UserDefaultsStorage.appPrivate.string(forKey: key(forLanguageCode: code))
        return id?.isEmpty == true ? nil : id
    }

    static func setVoiceID(_ id: String?, forLanguageCode code: String) {
        UserDefaultsStorage.appPrivate.set(id, forKey: key(forLanguageCode: code))
    }
}
