//
//  LiveTranslationLanguage.swift
//  VivaDicta
//
//  Soniox realtime language list, shared by the realtime STT client
//  (realtime dictation) and its tests. The Live Translation feature
//  itself was removed; this list stays because the STT client's
//  translation mode takes one of these languages.
//

import Foundation

enum LiveTranslationLanguage: String, CaseIterable, Identifiable, Sendable {
    // Source list: Soniox real-time STT + translation supported languages.
    // https://soniox.com/docs/stt/concepts/supported-languages
    // The same 60-language list is also covered by tts-rt-v1-preview's
    // multilingual voices, so any of these can be used as source or target.
    case afrikaans = "af"
    case albanian = "sq"
    case arabic = "ar"
    case azerbaijani = "az"
    case basque = "eu"
    case belarusian = "be"
    case bengali = "bn"
    case bosnian = "bs"
    case bulgarian = "bg"
    case catalan = "ca"
    case chinese = "zh"
    case croatian = "hr"
    case czech = "cs"
    case danish = "da"
    case dutch = "nl"
    case english = "en"
    case estonian = "et"
    case finnish = "fi"
    case french = "fr"
    case galician = "gl"
    case german = "de"
    case greek = "el"
    case gujarati = "gu"
    case hebrew = "he"
    case hindi = "hi"
    case hungarian = "hu"
    case indonesian = "id"
    case italian = "it"
    case japanese = "ja"
    case kannada = "kn"
    case kazakh = "kk"
    case korean = "ko"
    case latvian = "lv"
    case lithuanian = "lt"
    case macedonian = "mk"
    case malay = "ms"
    case malayalam = "ml"
    case marathi = "mr"
    case norwegian = "no"
    case persian = "fa"
    case polish = "pl"
    case portuguese = "pt"
    case punjabi = "pa"
    case romanian = "ro"
    case russian = "ru"
    case serbian = "sr"
    case slovak = "sk"
    case slovenian = "sl"
    case spanish = "es"
    case swahili = "sw"
    case swedish = "sv"
    case tagalog = "tl"
    case tamil = "ta"
    case telugu = "te"
    case thai = "th"
    case turkish = "tr"
    case ukrainian = "uk"
    case urdu = "ur"
    case vietnamese = "vi"
    case welsh = "cy"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .afrikaans: "Afrikaans"
        case .albanian: "Albanian"
        case .arabic: "Arabic"
        case .azerbaijani: "Azerbaijani"
        case .basque: "Basque"
        case .belarusian: "Belarusian"
        case .bengali: "Bengali"
        case .bosnian: "Bosnian"
        case .bulgarian: "Bulgarian"
        case .catalan: "Catalan"
        case .chinese: "Chinese"
        case .croatian: "Croatian"
        case .czech: "Czech"
        case .danish: "Danish"
        case .dutch: "Dutch"
        case .english: "English"
        case .estonian: "Estonian"
        case .finnish: "Finnish"
        case .french: "French"
        case .galician: "Galician"
        case .german: "German"
        case .greek: "Greek"
        case .gujarati: "Gujarati"
        case .hebrew: "Hebrew"
        case .hindi: "Hindi"
        case .hungarian: "Hungarian"
        case .indonesian: "Indonesian"
        case .italian: "Italian"
        case .japanese: "Japanese"
        case .kannada: "Kannada"
        case .kazakh: "Kazakh"
        case .korean: "Korean"
        case .latvian: "Latvian"
        case .lithuanian: "Lithuanian"
        case .macedonian: "Macedonian"
        case .malay: "Malay"
        case .malayalam: "Malayalam"
        case .marathi: "Marathi"
        case .norwegian: "Norwegian"
        case .persian: "Persian"
        case .polish: "Polish"
        case .portuguese: "Portuguese"
        case .punjabi: "Punjabi"
        case .romanian: "Romanian"
        case .russian: "Russian"
        case .serbian: "Serbian"
        case .slovak: "Slovak"
        case .slovenian: "Slovenian"
        case .spanish: "Spanish"
        case .swahili: "Swahili"
        case .swedish: "Swedish"
        case .tagalog: "Tagalog"
        case .tamil: "Tamil"
        case .telugu: "Telugu"
        case .thai: "Thai"
        case .turkish: "Turkish"
        case .ukrainian: "Ukrainian"
        case .urdu: "Urdu"
        case .vietnamese: "Vietnamese"
        case .welsh: "Welsh"
        }
    }

    var displayNameWithFlag: String {
        TranscriptionModelProvider.languageWithFlag(rawValue, name: displayName)
    }

    /// Languages alphabetically sorted by display name. Use this for the
    /// "rest" section of the picker.
    static var alphabetical: [LiveTranslationLanguage] {
        allCases.sorted { $0.displayName < $1.displayName }
    }

    /// User's preferred languages from `Locale.preferredLanguages`, intersected
    /// with what we support, in order of preference. Used to surface the most
    /// likely picks at the top of the picker.
    static var userPreferred: [LiveTranslationLanguage] {
        var seen: Set<LiveTranslationLanguage> = []
        var ordered: [LiveTranslationLanguage] = []
        for identifier in Locale.preferredLanguages {
            let locale = Locale(identifier: identifier)
            guard let code = locale.language.languageCode?.identifier,
                  let lang = LiveTranslationLanguage(rawValue: code),
                  !seen.contains(lang) else {
                continue
            }
            seen.insert(lang)
            ordered.append(lang)
        }
        return ordered
    }
}
