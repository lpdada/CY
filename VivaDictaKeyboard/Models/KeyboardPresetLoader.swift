//
//  KeyboardPresetLoader.swift
//  VivaDictaKeyboard
//
//  Created by Anton Novoselov on 2026.03.29
//

import Foundation
import AppGroup
import Presets

/// Loads presets from shared App Group UserDefaults for display in the keyboard extension.
///
/// The keyboard doesn't have access to `PresetManager`, but `Preset` and `PresetCatalog`
/// are available via target membership. This loader reads the persisted preset array directly.
enum KeyboardPresetLoader {
    private static let storageKey = UserDefaultsStorage.SharedKeys.presets
    private static let hiddenPresetIDsStorageKey = UserDefaultsStorage.SharedKeys.hiddenPresetIDs

    /// Loads all presets from shared UserDefaults.
    static func loadPresets() -> [Preset] {
        let defaults = AppGroupCoordinator.shared.clientDefaults
        guard let data = defaults.data(forKey: storageKey) else {
            return []
        }
        return (try? JSONDecoder().decode([Preset].self, from: data)) ?? []
    }

    /// Loads presets visible in pickers and keyboard on this device.
    static func loadVisiblePresets() -> [Preset] {
        let hiddenPresetIDs = loadHiddenPresetIDs()
        return loadPresets().filter { !hiddenPresetIDs.contains($0.id) }
    }

    private static func loadHiddenPresetIDs() -> Set<String> {
        let defaults = AppGroupCoordinator.shared.clientDefaults
        guard let ids = defaults.array(forKey: hiddenPresetIDsStorageKey) as? [String] else {
            return []
        }

        return Set(ids)
    }
}
