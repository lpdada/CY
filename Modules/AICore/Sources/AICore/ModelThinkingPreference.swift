//
//  ModelThinkingPreference.swift
//  VivaDicta
//

import Foundation

/// User preference: let the AI processing model reason before answering.
///
/// Off by default, which is also what `ReasoningConfig` already assumes:
/// stripping thinking per model family is what keeps enhancement fast, and a
/// dictation cleanup gains nothing from a reasoning round. Turning this on sends
/// no reasoning parameter at all, so each model keeps whichever default it
/// happens to ship with.
///
/// Read while the request body is being built (see `ReasoningConfig`), and
/// written by the Settings toggle through the same key - so flipping it applies
/// to the next enhancement, no relaunch needed. Stored in `UserDefaults.standard`
/// rather than the app group: enhancement runs in the app, and the keyboard
/// target never builds an AI request body.
public enum ModelThinkingPreference {
    /// Shared with the `@AppStorage` toggle in `SettingsView`.
    public static let userDefaultsKey = "isModelThinkingEnabled"

    public static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: userDefaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: userDefaultsKey) }
    }
}
