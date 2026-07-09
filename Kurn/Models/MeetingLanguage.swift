//
//  MeetingLanguage.swift
//  Kurn
//
//  Supported transcription languages: every language Whisper's cloud API
//  understands. Table-driven rather than switch-driven so SwiftLint's
//  cyclomatic-complexity/function-length limits stay unaffected by the
//  number of supported languages.
//

import Foundation

/// Supported transcription languages, with the BCP-47 locale used for the
/// on-device recognizer and the code Whisper expects in its `language` hint.
/// `autoDetect` lets the engine decide. Case rawValues are persisted via
/// `Meeting.languageRaw` — never rename or remove an existing case.
enum MeetingLanguage: String, Codable, Sendable, CaseIterable, Identifiable {
    case autoDetect
    case portuguese
    case english
    case spanish
    case french
    case german
    case japanese
    case chinese
    case russian
    case korean
    case turkish
    case polish
    case catalan
    case dutch
    case arabic
    case swedish
    case italian
    case indonesian
    case hindi
    case finnish
    case vietnamese
    case hebrew
    case ukrainian
    case greek
    case malay
    case czech
    case romanian
    case danish
    case hungarian
    case tamil
    case norwegian
    case thai
    case urdu
    case croatian
    case bulgarian
    case lithuanian
    case latin
    case maori
    case malayalam
    case welsh
    case slovak
    case telugu
    case persian
    case latvian
    case bengali
    case serbian
    case azerbaijani
    case slovenian
    case kannada
    case estonian
    case macedonian
    case breton
    case basque
    case icelandic
    case armenian
    case nepali
    case mongolian
    case bosnian
    case kazakh
    case albanian
    case swahili
    case galician
    case marathi
    case punjabi
    case sinhala
    case khmer
    case shona
    case yoruba
    case somali
    case afrikaans
    case occitan
    case georgian
    case belarusian
    case tajik
    case sindhi
    case gujarati
    case amharic
    case yiddish
    case lao
    case uzbek
    case faroese
    case haitianCreole
    case pashto
    case turkmen
    case norwegianNynorsk
    case maltese
    case sanskrit
    case luxembourgish
    case burmese
    case tibetan
    case tagalog
    case malagasy
    case assamese
    case tatar
    case hawaiian
    case lingala
    case hausa
    case bashkir
    case javanese
    case sundanese
    case cantonese

    var id: String { rawValue }

    /// Per-case metadata driving locale resolution, Whisper hints, and
    /// localization.
    private struct Info {
        let whisperCode: String?
        let localeIdentifier: String?
        let localizationKey: String
    }

    private static let table: [MeetingLanguage: Info] = [
        .autoDetect: Info(whisperCode: nil, localeIdentifier: nil, localizationKey: "lang.auto"),
        .portuguese: Info(whisperCode: "pt", localeIdentifier: "pt-BR", localizationKey: "lang.pt"),
        .english: Info(whisperCode: "en", localeIdentifier: "en-US", localizationKey: "lang.en"),
        .spanish: Info(whisperCode: "es", localeIdentifier: "es-ES", localizationKey: "lang.es"),
        .french: Info(whisperCode: "fr", localeIdentifier: "fr-FR", localizationKey: "lang.fr"),
        .german: Info(whisperCode: "de", localeIdentifier: "de-DE", localizationKey: "lang.de"),
        .japanese: Info(whisperCode: "ja", localeIdentifier: "ja-JP", localizationKey: "lang.ja"),
        .chinese: Info(whisperCode: "zh", localeIdentifier: "zh-CN", localizationKey: "lang.zh"),
        .russian: Info(whisperCode: "ru", localeIdentifier: "ru", localizationKey: "lang.ru"),
        .korean: Info(whisperCode: "ko", localeIdentifier: "ko", localizationKey: "lang.ko"),
        .turkish: Info(whisperCode: "tr", localeIdentifier: "tr", localizationKey: "lang.tr"),
        .polish: Info(whisperCode: "pl", localeIdentifier: "pl", localizationKey: "lang.pl"),
        .catalan: Info(whisperCode: "ca", localeIdentifier: "ca", localizationKey: "lang.ca"),
        .dutch: Info(whisperCode: "nl", localeIdentifier: "nl", localizationKey: "lang.nl"),
        .arabic: Info(whisperCode: "ar", localeIdentifier: "ar", localizationKey: "lang.ar"),
        .swedish: Info(whisperCode: "sv", localeIdentifier: "sv", localizationKey: "lang.sv"),
        .italian: Info(whisperCode: "it", localeIdentifier: "it", localizationKey: "lang.it"),
        .indonesian: Info(whisperCode: "id", localeIdentifier: "id", localizationKey: "lang.id"),
        .hindi: Info(whisperCode: "hi", localeIdentifier: "hi", localizationKey: "lang.hi"),
        .finnish: Info(whisperCode: "fi", localeIdentifier: "fi", localizationKey: "lang.fi"),
        .vietnamese: Info(whisperCode: "vi", localeIdentifier: "vi", localizationKey: "lang.vi"),
        .hebrew: Info(whisperCode: "he", localeIdentifier: "he", localizationKey: "lang.he"),
        .ukrainian: Info(whisperCode: "uk", localeIdentifier: "uk", localizationKey: "lang.uk"),
        .greek: Info(whisperCode: "el", localeIdentifier: "el", localizationKey: "lang.el"),
        .malay: Info(whisperCode: "ms", localeIdentifier: "ms", localizationKey: "lang.ms"),
        .czech: Info(whisperCode: "cs", localeIdentifier: "cs", localizationKey: "lang.cs"),
        .romanian: Info(whisperCode: "ro", localeIdentifier: "ro", localizationKey: "lang.ro"),
        .danish: Info(whisperCode: "da", localeIdentifier: "da", localizationKey: "lang.da"),
        .hungarian: Info(whisperCode: "hu", localeIdentifier: "hu", localizationKey: "lang.hu"),
        .tamil: Info(whisperCode: "ta", localeIdentifier: "ta", localizationKey: "lang.ta"),
        .norwegian: Info(whisperCode: "no", localeIdentifier: "no", localizationKey: "lang.no"),
        .thai: Info(whisperCode: "th", localeIdentifier: "th", localizationKey: "lang.th"),
        .urdu: Info(whisperCode: "ur", localeIdentifier: "ur", localizationKey: "lang.ur"),
        .croatian: Info(whisperCode: "hr", localeIdentifier: "hr", localizationKey: "lang.hr"),
        .bulgarian: Info(whisperCode: "bg", localeIdentifier: "bg", localizationKey: "lang.bg"),
        .lithuanian: Info(whisperCode: "lt", localeIdentifier: "lt", localizationKey: "lang.lt"),
        .latin: Info(whisperCode: "la", localeIdentifier: "la", localizationKey: "lang.la"),
        .maori: Info(whisperCode: "mi", localeIdentifier: "mi", localizationKey: "lang.mi"),
        .malayalam: Info(whisperCode: "ml", localeIdentifier: "ml", localizationKey: "lang.ml"),
        .welsh: Info(whisperCode: "cy", localeIdentifier: "cy", localizationKey: "lang.cy"),
        .slovak: Info(whisperCode: "sk", localeIdentifier: "sk", localizationKey: "lang.sk"),
        .telugu: Info(whisperCode: "te", localeIdentifier: "te", localizationKey: "lang.te"),
        .persian: Info(whisperCode: "fa", localeIdentifier: "fa", localizationKey: "lang.fa"),
        .latvian: Info(whisperCode: "lv", localeIdentifier: "lv", localizationKey: "lang.lv"),
        .bengali: Info(whisperCode: "bn", localeIdentifier: "bn", localizationKey: "lang.bn"),
        .serbian: Info(whisperCode: "sr", localeIdentifier: "sr", localizationKey: "lang.sr"),
        .azerbaijani: Info(whisperCode: "az", localeIdentifier: "az", localizationKey: "lang.az"),
        .slovenian: Info(whisperCode: "sl", localeIdentifier: "sl", localizationKey: "lang.sl"),
        .kannada: Info(whisperCode: "kn", localeIdentifier: "kn", localizationKey: "lang.kn"),
        .estonian: Info(whisperCode: "et", localeIdentifier: "et", localizationKey: "lang.et"),
        .macedonian: Info(whisperCode: "mk", localeIdentifier: "mk", localizationKey: "lang.mk"),
        .breton: Info(whisperCode: "br", localeIdentifier: "br", localizationKey: "lang.br"),
        .basque: Info(whisperCode: "eu", localeIdentifier: "eu", localizationKey: "lang.eu"),
        .icelandic: Info(whisperCode: "is", localeIdentifier: "is", localizationKey: "lang.is"),
        .armenian: Info(whisperCode: "hy", localeIdentifier: "hy", localizationKey: "lang.hy"),
        .nepali: Info(whisperCode: "ne", localeIdentifier: "ne", localizationKey: "lang.ne"),
        .mongolian: Info(whisperCode: "mn", localeIdentifier: "mn", localizationKey: "lang.mn"),
        .bosnian: Info(whisperCode: "bs", localeIdentifier: "bs", localizationKey: "lang.bs"),
        .kazakh: Info(whisperCode: "kk", localeIdentifier: "kk", localizationKey: "lang.kk"),
        .albanian: Info(whisperCode: "sq", localeIdentifier: "sq", localizationKey: "lang.sq"),
        .swahili: Info(whisperCode: "sw", localeIdentifier: "sw", localizationKey: "lang.sw"),
        .galician: Info(whisperCode: "gl", localeIdentifier: "gl", localizationKey: "lang.gl"),
        .marathi: Info(whisperCode: "mr", localeIdentifier: "mr", localizationKey: "lang.mr"),
        .punjabi: Info(whisperCode: "pa", localeIdentifier: "pa", localizationKey: "lang.pa"),
        .sinhala: Info(whisperCode: "si", localeIdentifier: "si", localizationKey: "lang.si"),
        .khmer: Info(whisperCode: "km", localeIdentifier: "km", localizationKey: "lang.km"),
        .shona: Info(whisperCode: "sn", localeIdentifier: "sn", localizationKey: "lang.sn"),
        .yoruba: Info(whisperCode: "yo", localeIdentifier: "yo", localizationKey: "lang.yo"),
        .somali: Info(whisperCode: "so", localeIdentifier: "so", localizationKey: "lang.so"),
        .afrikaans: Info(whisperCode: "af", localeIdentifier: "af", localizationKey: "lang.af"),
        .occitan: Info(whisperCode: "oc", localeIdentifier: "oc", localizationKey: "lang.oc"),
        .georgian: Info(whisperCode: "ka", localeIdentifier: "ka", localizationKey: "lang.ka"),
        .belarusian: Info(whisperCode: "be", localeIdentifier: "be", localizationKey: "lang.be"),
        .tajik: Info(whisperCode: "tg", localeIdentifier: "tg", localizationKey: "lang.tg"),
        .sindhi: Info(whisperCode: "sd", localeIdentifier: "sd", localizationKey: "lang.sd"),
        .gujarati: Info(whisperCode: "gu", localeIdentifier: "gu", localizationKey: "lang.gu"),
        .amharic: Info(whisperCode: "am", localeIdentifier: "am", localizationKey: "lang.am"),
        .yiddish: Info(whisperCode: "yi", localeIdentifier: "yi", localizationKey: "lang.yi"),
        .lao: Info(whisperCode: "lo", localeIdentifier: "lo", localizationKey: "lang.lo"),
        .uzbek: Info(whisperCode: "uz", localeIdentifier: "uz", localizationKey: "lang.uz"),
        .faroese: Info(whisperCode: "fo", localeIdentifier: "fo", localizationKey: "lang.fo"),
        .haitianCreole: Info(whisperCode: "ht", localeIdentifier: "ht", localizationKey: "lang.ht"),
        .pashto: Info(whisperCode: "ps", localeIdentifier: "ps", localizationKey: "lang.ps"),
        .turkmen: Info(whisperCode: "tk", localeIdentifier: "tk", localizationKey: "lang.tk"),
        .norwegianNynorsk: Info(whisperCode: "nn", localeIdentifier: "nn", localizationKey: "lang.nn"),
        .maltese: Info(whisperCode: "mt", localeIdentifier: "mt", localizationKey: "lang.mt"),
        .sanskrit: Info(whisperCode: "sa", localeIdentifier: "sa", localizationKey: "lang.sa"),
        .luxembourgish: Info(whisperCode: "lb", localeIdentifier: "lb", localizationKey: "lang.lb"),
        .burmese: Info(whisperCode: "my", localeIdentifier: "my", localizationKey: "lang.my"),
        .tibetan: Info(whisperCode: "bo", localeIdentifier: "bo", localizationKey: "lang.bo"),
        .tagalog: Info(whisperCode: "tl", localeIdentifier: "tl", localizationKey: "lang.tl"),
        .malagasy: Info(whisperCode: "mg", localeIdentifier: "mg", localizationKey: "lang.mg"),
        .assamese: Info(whisperCode: "as", localeIdentifier: "as", localizationKey: "lang.as"),
        .tatar: Info(whisperCode: "tt", localeIdentifier: "tt", localizationKey: "lang.tt"),
        .hawaiian: Info(whisperCode: "haw", localeIdentifier: "haw", localizationKey: "lang.haw"),
        .lingala: Info(whisperCode: "ln", localeIdentifier: "ln", localizationKey: "lang.ln"),
        .hausa: Info(whisperCode: "ha", localeIdentifier: "ha", localizationKey: "lang.ha"),
        .bashkir: Info(whisperCode: "ba", localeIdentifier: "ba", localizationKey: "lang.ba"),
        .javanese: Info(whisperCode: "jw", localeIdentifier: "jw", localizationKey: "lang.jw"),
        .sundanese: Info(whisperCode: "su", localeIdentifier: "su", localizationKey: "lang.su"),
        .cantonese: Info(whisperCode: "yue", localeIdentifier: "yue", localizationKey: "lang.yue")
    ]

    /// BCP-47 identifier for the on-device recognizer, or `nil` for auto-detect.
    var localeIdentifier: String? { Self.table[self]!.localeIdentifier }

    /// Code Whisper expects in its `language` field, or `nil` for auto-detect.
    var whisperCode: String? { Self.table[self]!.whisperCode }

    var displayName: String {
        NSLocalizedString(Self.table[self]!.localizationKey, comment: "Language name")
    }

    /// Reverse index from a Whisper/BCP-47 code to the matching language,
    /// built once from `table`.
    private static let byCode: [String: MeetingLanguage] = {
        var map: [String: MeetingLanguage] = [:]
        for (language, info) in table {
            if let code = info.whisperCode {
                map[code] = language
            }
        }
        return map
    }()

    /// Map a detector code (e.g. "pt", "pt-BR", "zh-Hans", "yue") to a
    /// supported `MeetingLanguage`, or `.autoDetect` when it isn't one we
    /// pin. Checks the full lowercased code first — needed for 3-letter
    /// Whisper codes like "yue"/"haw" — then falls back to the 2-letter
    /// prefix for region-qualified codes like "zh-Hans" or "pt-BR".
    init(detectedCode code: String) {
        let normalized = code.lowercased()
        if let match = Self.byCode[normalized] {
            self = match
        } else if let match = Self.byCode[String(normalized.prefix(2))] {
            self = match
        } else {
            self = .autoDetect
        }
    }
}
