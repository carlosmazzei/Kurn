//
//  Error+LogCode.swift
//  Kurn
//
//  A fixed, redaction-safe identity for any error at `privacy: .public`.
//  `localizedDescription` is never safe there: an `AppError`'s own text can
//  embed a raw system message (see `privateContext`), and a library error's
//  text can carry a file path, a provider payload, or a URL. Log this at
//  `.public` and, when the text is needed, `localizedDescription` at
//  `.private`.
//

import Foundation
import KurnCore

extension Error {
    /// An `AppError`'s `logCode`; otherwise the NSError domain and numeric
    /// code (`NSCocoaErrorDomain#640`), which identify the failure class
    /// without any of the message text.
    var publicLogCode: String {
        if let appError = self as? AppError {
            return appError.logCode
        }
        let nsError = self as NSError
        return "\(nsError.domain)#\(nsError.code)"
    }
}
