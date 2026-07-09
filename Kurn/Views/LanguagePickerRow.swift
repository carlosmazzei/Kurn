//
//  LanguagePickerRow.swift
//  Kurn
//
//  A language Picker row: the (short) display name plus a warning icon when
//  the language isn't expected to work with the given transcription engine,
//  so the user finds out here rather than after starting a transcription.
//

import SwiftUI

struct LanguagePickerRow: View {
    let language: MeetingLanguage
    let engine: TranscriptionEngine

    var body: some View {
        HStack {
            Text(language.displayName)
            if !TranscriptionLanguageSupport.isSupported(language, by: engine) {
                Spacer()
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityLabel(Text(NSLocalizedString("lang.unsupported_a11y", comment: "Language may not be supported")))
            }
        }
    }
}
