//
//  LiveTranslationToken.swift
//  VivaDicta
//
//  Shared token type for the Soniox realtime dictation path.
//  The Live Translation feature itself was removed; this type stays because
//  RealtimeTranscriptAccumulator and SonioxRealtimeDictationSession use it.
//

import Foundation

struct LiveTranslationToken: Sendable, Hashable {
    let id: UUID
    let text: String
    let isFinal: Bool
    let kind: Kind

    enum Kind: Sendable, Hashable {
        case original
        case translation
    }
}
