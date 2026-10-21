//
//  VivaModeManager.swift
//  VivaDictaKeyboard
//
//  Created by Anton Novoselov on 2025.10.19
//

import Foundation
import AppGroup
import os
import AICore

@Observable
final class VivaModeManager {
    private let logger = Logger(category: .vivaModeManager)
    // 与 AppGroupCoordinator 同一份存储：正版是共享 suite，
    // 桥模式（自签）是扩展本地缓存，由桥从主 App 拉取 config 填充
    private let userDefaults = AppGroupCoordinator.shared.clientDefaults

    // MARK: - Properties
    public private(set) var availableVivaModes: [VivaMode] = []
    public var selectedVivaMode: VivaMode = VivaMode.defaultMode {
        didSet {
            if oldValue.id != selectedVivaMode.id {
                saveSelectedMode()
                // Notify the main app about the change
                AppGroupCoordinator.shared.setSelectedVivaMode(selectedVivaMode.name)
            }
        }
    }

    /// 键盘药丸/模式选择器里用户亲手点的模式：除了本地保存与原有通知，
    /// 还经 HTTP 推给主 App（桥模式下剪贴板读不到，只靠它主 App 收不到）。
    /// 重复点同一模式也会再推一次（幂等，可当重试）；load/refresh 走
    /// 直接赋值，不经过这里，避免启动拉取时把旧模式又推回去。
    public func userDidSelectMode(_ mode: VivaMode) {
        selectedVivaMode = mode
        Task {
            await BridgeStateClient.pushMode(name: mode.name)
        }
    }

    // MARK: - Init
    init() {
        loadVivaModes()
        loadSelectedMode()
    }

    // MARK: - Public Methods
    public func refreshVivaModes() {
        loadVivaModes()
        loadSelectedMode()
        // 桥模式：再异步从主 App 拉一次最新配置，落地缓存后重载，
        // 保证用户在主 App 里改的模式/预设能同步到键盘
        if LocalBridge.isEnabled {
            let defaults = userDefaults
            Task { @MainActor [weak self] in
                if let config = await BridgeStateClient.pullConfig() {
                    BridgeStateClient.applySnapshot(config, to: defaults)
                }
                self?.loadVivaModes()
                self?.loadSelectedMode()
            }
        }
    }

    // MARK: - Private Methods
    private func loadVivaModes() {
        logger.logInfo("🎯 Loading viva modes from shared storage...")

        if let savedVivaModesData = userDefaults.data(forKey: AppGroupCoordinator.vivaModesKey) {
            logger.logInfo("🎯 Found saved modes data, attempting to decode...")

            do {
                let savedVivaModes = try JSONDecoder().decode([VivaMode].self, from: savedVivaModesData)
                availableVivaModes = savedVivaModes
                logger.logInfo("🎯 Successfully loaded \(savedVivaModes.count) viva modes: \(savedVivaModes.map { $0.name }.joined(separator: ", "))")
            } catch {
                logger.logError("🎯 Failed to decode viva modes: \(error.localizedDescription)")
                availableVivaModes = [VivaMode.defaultMode]
            }
        } else {
            logger.logWarning("🎯 No saved viva modes found in shared storage")
            availableVivaModes = [VivaMode.defaultMode]
        }
    }

    private func loadSelectedMode() {
        let selectedVivaModeName = userDefaults.string(forKey: AppGroupCoordinator.selectedVivaModeKey) ?? VivaMode.defaultMode.name
        selectedVivaMode = availableVivaModes.first(where: { $0.name == selectedVivaModeName }) ?? VivaMode.defaultMode
        logger.logInfo("🎯 Loaded selected mode: \(selectedVivaMode.name)")
    }

    private func saveSelectedMode() {
        userDefaults.set(selectedVivaMode.name, forKey: AppGroupCoordinator.selectedVivaModeKey)
        userDefaults.synchronize() // Force immediate write
        logger.logInfo("🎯 Saved selected mode: \(selectedVivaMode.name)")
    }
}
