//
//  AppGroupCoordinator.swift
//  VivaDicta
//
//  Created by Anton Novoselov on 2025.10.03
//

@preconcurrency import Foundation
import os

/// Coordinates communication between the main app and extensions (keyboard, share, widget).
///
/// `AppGroupCoordinator` uses App Groups for shared storage and Darwin Notifications
/// for real-time event communication. It manages the bidirectional communication
/// needed for features like keyboard-initiated recording.
///
/// ## Overview
///
/// The coordinator handles:
/// - Recording commands (start, stop, cancel, pause, resume) from keyboard extension
/// - Transcription status updates (transcribing, enhancing, completed, error)
/// - Audio level sharing for remote visualization
/// - Keyboard session lifecycle management
/// - Transcribed text delivery back to keyboard
/// - VivaMode sharing between app and extensions
///
/// ## App Group
///
/// Uses the shared container `group.com.antonnovoselov.VivaDicta` for UserDefaults
/// and file storage accessible by all app extensions.
///
/// ## Darwin Notifications
///
/// Real-time events are communicated via Darwin notifications, which work across
/// process boundaries without requiring the target to be running.
///
/// ## Usage
///
/// ```swift
/// // From keyboard extension - request recording
/// AppGroupCoordinator.shared.requestStartRecording()
///
/// // From main app - listen for requests
/// AppGroupCoordinator.shared.onStartRecordingRequested = {
///     self.startRecording()
/// }
/// ```
public final class AppGroupCoordinator: @unchecked Sendable {
    public static let shared = AppGroupCoordinator()

    private let logger = Logger(appGroupCategory: "AppGroupCoordinator")

    
    // MARK: - Constants
    public let appGroupId = "group.com.antonnovoselov.VivaDicta"
    // AI Processing configuration
    public static let vivaModesKey = "VivaModes"
    public static let selectedVivaModeKey = "selectedVivaMode"
    // 键盘直译快照：主 App 同步选中模式的模型与 Key（见 AppGroupAISnapshot）。
    // 正版走 App Group suite；桥模式（自签无 App Group）下主 App 把它写进
    // 本地 defaults，/vd/config 再把它带给键盘（键盘读本地缓存兜底）。
    public static let kAISnapshotProvider = "vdAISnapshotProvider"
    public static let kAISnapshotModel = "vdAISnapshotModel"
    public static let kAISnapshotBaseURL = "vdAISnapshotBaseURL"
    public static let kAISnapshotAPIKey = "vdAISnapshotAPIKey"
    public static let kSelectedLanguageKey = "selectedLanguageKey"
    public static let kTranslationTargetLanguageKey = "translationTargetLanguageKey"
    public static let kAPIKeyTemplate = "apiKeyTemplate"
    public static let kSmartFormattingOnPaste = "smartFormattingOnPaste"
    public static let kKeepTranscriptInClipboard = "keepTranscriptInClipboard"
    public static let kIsVADEnabled = "IsVADEnabled"
    public static let kIsSpeakerDiarizationEnabled = "isSpeakerDiarizationEnabled"
    public static let kGeminiTranscriptionThinkingLevel = "geminiTranscriptionThinkingLevel"
    public static let kGeminiTranscriptionPrompt = "geminiTranscriptionPrompt"
    public static let kIsKeyboardHapticFeedbackEnabled = "isKeyboardHapticFeedbackEnabled"
    public static let kIsKeyboardSoundFeedbackEnabled = "isKeyboardSoundFeedbackEnabled"
    public static let kEnabledKeyboardLanguages = "enabledKeyboardLanguages"
    public static let kCurrentKeyboardLanguage = "currentKeyboardLanguage"
    private static let kDidMigrateLanguageSettings = "didMigrateLanguageSettings_v1"
    /// Languages already offered to this install, so a language added in a
    /// later release can be auto-enabled exactly once. See
    /// `ensureNewLanguagesSeeded()`.
    private static let kSeededLanguages = "seededKeyboardLanguages"
    // Legacy keys, kept here only so the migration code can read and clear them.
    private static let kLegacyKeyboardLayoutStyle = "keyboardLayoutStyle"
    private static let kLegacyIsRussianLayoutEnabled = "isRussianLayoutEnabled"
    private static let kLegacyIsCurrentlyRussian = "isCurrentlyRussian"

    public static let isHapticsEnabled = "isHapticsEnabled"

    // Keyboard success tracking (for deferred rating request in main app)
    public static let kKeyboardFirstSuccessfulUse = "keyboardFirstSuccessfulUse"

    // Share Extension
    public static let kPendingSharedAudioFileName = "pendingSharedAudioFileName"
    public static let kPendingLanguageOverride = "pendingLanguageOverride"
    public static let kPendingSourceTag = "pendingSourceTag"

    private enum UserDefaultsKeys {
        static let isRecording = "isRecording"
        static let lastRecordingTimestamp = "lastRecordingTimestamp"
        static let transcribedText = "transcribedText"
        static let transcriptionStatus = "transcriptionStatus"
        static let keyboardSessionActive = "keyboardSessionActive"
        static let keyboardSessionExpiryTime = "keyboardSessionExpiryTime"
        static let audioLevel = "audioLevel" // 0.0 ... 1.0
        static let transcriptionErrorMessage = "transcriptionErrorMessage"
        static let keyboardClipboardContext = "keyboardClipboardContext"

        // Text processing (keyboard rewrite feature)
        static let textProcessingInput = "textProcessingInput"
        static let textProcessingModeName = "textProcessingModeName"
        static let textProcessingPresetId = "textProcessingPresetId"
        static let textProcessingResult = "textProcessingResult"
        static let textProcessingErrorMessage = "textProcessingErrorMessage"

        // Voice instruction (keyboard "speak to edit"): the keyboard parks the
        // text to rewrite here *before* posting the ordinary start-recording
        // notification. The main app consumes it when recording starts, which
        // is what turns that recording into an instruction rather than a note.
        static let voiceInstructionTargetText = "voiceInstructionTargetText"
        static let voiceInstructionModeName = "voiceInstructionModeName"

        // Obsidian hand-off: main app publishes when the current transcription
        // was triggered by the keyboard and needs the keyboard extension to
        // open `obsidian://...` on its behalf. The keyboard owns the clipboard
        // write (it runs in the foregrounded host; background `UIPasteboard`
        // writes from the main app are unreliable and can return stale
        // Universal Clipboard content to Obsidian).
        static let pendingObsidianURL = "pendingObsidianURL"
        static let pendingObsidianClipboard = "pendingObsidianClipboard"
    }

    private enum NotificationNames {
        static let startRecording = "com.antonnovoselov.VivaDicta.startRecording"
        static let stopRecording = "com.antonnovoselov.VivaDicta.stopRecording"
        static let cancelRecording = "com.antonnovoselov.VivaDicta.cancelRecording"
        static let pauseRecording = "com.antonnovoselov.VivaDicta.pauseRecording"
        static let resumeRecording = "com.antonnovoselov.VivaDicta.resumeRecording"
        static let recordingStateChanged = "com.antonnovoselov.VivaDicta.recordingStateChanged"
        static let transcriptionCompleted = "com.antonnovoselov.VivaDicta.transcriptionCompleted"
        static let keyboardSessionActivated = "com.antonnovoselov.VivaDicta.keyboardSessionActivated"
        static let keyboardSessionExpired = "com.antonnovoselov.VivaDicta.keyboardSessionExpired"
        static let transcriptionTranscribing = "com.antonnovoselov.VivaDicta.transcriptionTranscribing"
        static let transcriptionEnhancing = "com.antonnovoselov.VivaDicta.transcriptionEnhancing"
        static let transcriptionError = "com.antonnovoselov.VivaDicta.transcriptionError"
        static let transcriptionCancelled = "com.antonnovoselov.VivaDicta.transcriptionCancelled"
        static let audioLevelUpdated = "com.antonnovoselov.VivaDicta.audioLevelUpdated"
        static let startRecordingFromControl = "com.antonnovoselov.VivaDicta.startRecordingFromControl"
        static let terminateSessionFromLiveActivity = "com.antonnovoselov.VivaDicta.terminateSessionFromLiveActivity"
        static let vivaModeChanged = "com.antonnovoselov.VivaDicta.vivaModeChanged"

        // Text processing (keyboard rewrite feature)
        static let requestTextProcessing = "com.antonnovoselov.VivaDicta.requestTextProcessing"
        static let textProcessingCompleted = "com.antonnovoselov.VivaDicta.textProcessingCompleted"
        static let textProcessingError = "com.antonnovoselov.VivaDicta.textProcessingError"
    }

    /// Status of the transcription pipeline, shared with extensions.
    public enum TranscriptionStatus: String {
        case idle = "idle"
        case recording = "recording"
        case transcribing = "transcribing"
        case enhancing = "AI processing"
        case completed = "completed"
        case error = "error"
    }

    // MARK: - Properties
    private let sharedDefaults: UserDefaults?
    private let notificationCenter = CFNotificationCenterGetDarwinNotifyCenter()

    @MainActor public var onStartRecordingRequested: (() -> Void)?
    @MainActor public var onStopRecordingRequested: (() -> Void)?
    @MainActor public var onCancelRecordingRequested: (() -> Void)?
    @MainActor public var onPauseRecordingRequested: (() -> Void)?
    @MainActor public var onResumeRecordingRequested: (() -> Void)?
    @MainActor public var onKeyboardSessionActivated: (() -> Void)?
    @MainActor public var onTranscriptionCompleted: ((String) -> Void)?
    @MainActor public var onTranscriptionTranscribing: (() -> Void)?
    @MainActor public var onTranscriptionEnhancing: (() -> Void)?
    @MainActor public var onTranscriptionError: (() -> Void)?
    @MainActor public var onTranscriptionCancelled: (() -> Void)?
    @MainActor public var onTranscriptionErrorMessage: ((String) -> Void)?
    @MainActor public var onKeyboardSessionExpired: (() -> Void)?
    @MainActor public var onAudioLevelUpdated: ((CGFloat) -> Void)?
    @MainActor public var onRecordingStateChanged: ((Bool) -> Void)?
    @MainActor public var onStartRecordingFromControl: (() -> Void)?
    @MainActor public var onTerminateSessionFromLiveActivity: (() -> Void)?
    @MainActor public var onVivaModeChanged: (() -> Void)?

    // Text processing (keyboard rewrite feature)
    @MainActor public var onTextProcessingRequested: (() -> Void)?
    @MainActor public var onTextProcessingCompleted: ((String) -> Void)?
    @MainActor public var onTextProcessingError: ((String) -> Void)?

    // MARK: - Initialization
    private init() {
        // 桥模式（自签无 App Group）下，两进程改用各自的本地存储：
        // 主 App 的是权威数据，扩展的是桥拉取的缓存；跨进程搬运交给 LocalBridge。
        if LocalBridge.isEnabled {
            sharedDefaults = LocalBridge.localDefaults
        } else {
            sharedDefaults = UserDefaults(suiteName: appGroupId)
        }
        setupNotificationObservers()
        startBridgeServerIfNeeded()
        warmBridgeCacheIfNeeded()
    }

    /// 供模块外的客户端（键盘的 VivaModeManager / KeyboardPresetLoader 等）
    /// 读取与 Coordinator 同一份存储：正版是共享 suite，桥模式是本地缓存。
    public var clientDefaults: UserDefaults {
        sharedDefaults ?? .standard
    }

    /// 扩展进程在桥模式下冷启动暖一次缓存，避免键盘刚展开时
    /// 同步 getter（会话是否激活、当前模式、预设）读到空值。
    /// 暖缓存拉回真值后也递交一次录音态：键盘进程重建时，
    /// 录音状态通知可能已在旧进程里发出并丢失，单靠通知驱动
    /// 的 UI 永远等不到那一次事件（fork24 前的微信键盘偶发
    /// 不翻红即此链）。递交时回调若尚未注册则为空操作，真正
    /// 的对账由键盘每次出现时调 reconcileRecordingState() 完成。
    private func warmBridgeCacheIfNeeded() {
        guard LocalBridge.isEnabled, !LocalBridge.isMainAppProcess,
              let defaults = sharedDefaults else { return }
        Task { @MainActor in
            if let state = await BridgeStateClient.pullState() {
                BridgeStateClient.applySnapshot(state, to: defaults)
            }
            if let config = await BridgeStateClient.pullConfig() {
                BridgeStateClient.applySnapshot(config, to: defaults)
            }
            deliverRecordingState()
        }
    }

    /// Test-only initializer with injectable UserDefaults and no Darwin notification observers.
    public init(userDefaults: UserDefaults) {
        sharedDefaults = userDefaults
    }

    deinit {
        removeNotificationObservers()
    }

    // MARK: - Local Bridge（自签无 App Group 时的数据通道）

    private var bridgeServer: BridgeStateServer?

    /// 桥模式且当前是主 App 进程时，启动本地状态/配置服务。
    /// 服务端只是本地存储的一个只读窗口：每次请求现读现返回，
    /// 所以主 App 侧的其它写方法不需要为桥做任何额外动作。
    private func startBridgeServerIfNeeded() {
        guard LocalBridge.isEnabled, LocalBridge.isMainAppProcess,
              let defaults = sharedDefaults else { return }
        let server = BridgeStateServer(
            stateProvider: {
                BridgeStateClient.makeSnapshot(
                    from: defaults,
                    stringKeys: [UserDefaultsKeys.transcriptionStatus],
                    boolKeys: [UserDefaultsKeys.isRecording, UserDefaultsKeys.keyboardSessionActive],
                    doubleKeys: [
                        UserDefaultsKeys.audioLevel,
                        UserDefaultsKeys.keyboardSessionExpiryTime,
                        UserDefaultsKeys.lastRecordingTimestamp,
                    ],
                    dataKeys: [],
                    arrayKeys: []
                )
            },
            configProvider: {
                BridgeStateClient.makeSnapshot(
                    from: defaults,
                    stringKeys: [
                        AppGroupCoordinator.selectedVivaModeKey,
                        AppGroupCoordinator.kGeminiTranscriptionThinkingLevel,
                        AppGroupCoordinator.kGeminiTranscriptionPrompt,
                        AppGroupCoordinator.kEnabledKeyboardLanguages,
                        AppGroupCoordinator.kCurrentKeyboardLanguage,
                        // 键盘直译快照：桥模式下主 App 只写本地 defaults，
                        // 不经这里就到不了键盘（applySnapshot 只写快照里有的键）。
                        AppGroupCoordinator.kAISnapshotProvider,
                        AppGroupCoordinator.kAISnapshotModel,
                        AppGroupCoordinator.kAISnapshotBaseURL,
                        AppGroupCoordinator.kAISnapshotAPIKey,
                    ],
                    boolKeys: [
                        AppGroupCoordinator.kSmartFormattingOnPaste,
                        AppGroupCoordinator.kKeepTranscriptInClipboard,
                        AppGroupCoordinator.kIsVADEnabled,
                        AppGroupCoordinator.kIsSpeakerDiarizationEnabled,
                        AppGroupCoordinator.kIsKeyboardHapticFeedbackEnabled,
                        AppGroupCoordinator.kIsKeyboardSoundFeedbackEnabled,
                    ],
                    doubleKeys: [],
                    dataKeys: [
                        AppGroupCoordinator.vivaModesKey,
                        UserDefaultsStorage.SharedKeys.presets,
                    ],
                    arrayKeys: [UserDefaultsStorage.SharedKeys.hiddenPresetIDs]
                )
            },
            onModeReceived: { [weak self] name in
                guard let self, let defaults = self.sharedDefaults else { return }
                defaults.set(name, forKey: AppGroupCoordinator.selectedVivaModeKey)
                defaults.synchronize()
                // 走已有的 Darwin 链：主 App 自己的 handler → ingest 兜底 →
                // onVivaModeChanged → reloadSelectedModeFromExtension，
                // UI 下拉与转写处理模式全跟上，无需 server 再认识 AIService。
                self.postDarwinNotification(NotificationNames.vivaModeChanged)
            }
        )
        server.start()
        bridgeServer = server
    }

    /// 扩展进程：把状态快照拉回本地缓存（录音状态/电平/会话）。
    /// 在依赖这些值的通知 handler 之前调用，保证随后走的原有读取逻辑命中新值。
    /// 返回值说明缓存是否可信：非桥模式或主 App 进程里直接返回 true；
    /// 桥模式下拉取失败时返回 false——调用方不能把旧缓存当新值读，
    /// 否则一次失败的拉取会让键盘整场录音都停留在普通界面（主 App
    /// 后台明明在录音），而录音状态通知整场只发一次，不会再纠正。
    @discardableResult
    private func pullBridgeStateIntoCache() async -> Bool {
        guard LocalBridge.isEnabled, !LocalBridge.isMainAppProcess,
              let defaults = sharedDefaults else { return true }
        if let snapshot = await BridgeStateClient.pullState() {
            BridgeStateClient.applySnapshot(snapshot, to: defaults)
            return true
        }
        return false
    }

    /// 键盘侧最近一次递交给 UI 的录音态。电平 tick 对账时用它判断
    /// 缓存里的录音态是否变了，避免每次电平更新都重复递交。
    /// 与回调一样标 MainActor：回调本身是 MainActor 隔离的，非隔离
    /// 方法里读它在 Swift 6 下直接编译失败（fork23 首版 CI 即此错）。
    @MainActor private var lastDeliveredRecordingState: Bool?

    @MainActor private func deliverRecordingState() {
        let recording = isRecording
        lastDeliveredRecordingState = recording
        onRecordingStateChanged?(recording)
    }

    /// 扩展进程：把配置快照拉回本地缓存（桥模式下键盘拿配置的通道）。
    /// 只写快照里有的键，拉不到、或快照里没有快照键时旧缓存原样保留；
    /// 所以译按钮每次点之前拉一次是安全的：主 App 在就刷新轮换后的 Key，
    /// 主 App 不在就瞬间失败、继续用旧缓存，不会把好缓存洗掉。
    public func pullBridgeConfigIntoCache() async {
        guard LocalBridge.isEnabled, !LocalBridge.isMainAppProcess,
              let defaults = sharedDefaults else { return }
        if let config = await BridgeStateClient.pullConfig() {
            BridgeStateClient.applySnapshot(config, to: defaults)
        }
    }

    /// 键盘每次出现时主动对账录音态（一次性 Darwin 通知丢失的兜底）。
    /// 拉取失败也不跳过递交：递交读的是本地缓存，至少把上一次
    /// 拉到的真值交给 UI；拉取成功时缓存已是最新，递交的就是真值。
    /// 调用方须先保证回调已注册（键盘在 viewWillAppear 里先重注册
    /// 再调本方法），否则递交会空操作。
    @MainActor public func reconcileRecordingState() async {
        await pullBridgeStateIntoCache()
        deliverRecordingState()
    }

    /// 主 App 进程：把键盘经剪贴板送来的载荷落地到本地存储。
    /// 在对应通知的 handler 开头调用，赶在业务回调读取之前。
    private func ingestBridgePayloads() {
        guard LocalBridge.isEnabled, LocalBridge.isMainAppProcess,
              let defaults = sharedDefaults else { return }
        if let fields = BridgePasteboard.consume(kind: .textProcessing) {
            defaults.set(fields["text"] ?? "", forKey: UserDefaultsKeys.textProcessingInput)
            defaults.set(fields["modeName"] ?? "", forKey: UserDefaultsKeys.textProcessingModeName)
            if let presetId = fields["presetId"], !presetId.isEmpty {
                defaults.set(presetId, forKey: UserDefaultsKeys.textProcessingPresetId)
            } else {
                defaults.removeObject(forKey: UserDefaultsKeys.textProcessingPresetId)
            }
        }
        if let fields = BridgePasteboard.consume(kind: .voiceInstruction) {
            defaults.set(fields["targetText"] ?? "", forKey: UserDefaultsKeys.voiceInstructionTargetText)
            defaults.set(fields["modeName"] ?? "", forKey: UserDefaultsKeys.voiceInstructionModeName)
        }
        if let fields = BridgePasteboard.consume(kind: .clipboardContext) {
            if fields["present"] == "1" {
                defaults.set(fields["text"] ?? "", forKey: UserDefaultsKeys.keyboardClipboardContext)
            } else {
                defaults.removeObject(forKey: UserDefaultsKeys.keyboardClipboardContext)
            }
        }
        if let fields = BridgePasteboard.consume(kind: .selectedMode) {
            defaults.set(fields["name"] ?? "", forKey: AppGroupCoordinator.selectedVivaModeKey)
        }
    }

    /// 扩展进程：把主 App 回传的某一类结果落地到本地缓存。
    /// 两条腿：先试命名剪贴板（原通道），没货再经本地 HTTP 拉结果槽
    /// （fork5 主通道——自签环境下命名剪贴板跨进程读不到，剪贴板
    /// 这一路到不了，听写结果到不了输入框）。结果槽里的原件按完成
    /// 时刻去重：本类已消费水位存在本地存储里，同一份不会落地两次；
    /// 剪贴板有货时同样把水位推到当下，挡住 HTTP 再送同一份。
    private func ingestBridgeResult(
        kind: BridgePayloadKind,
        defaultsKey: String,
        field: String
    ) async {
        guard LocalBridge.isEnabled, !LocalBridge.isMainAppProcess,
              let defaults = sharedDefaults else { return }
        let waterKey = "vdBridgeConsumedAt.\(kind.rawValue)"
        if let fields = BridgePasteboard.consume(kind: kind) {
            defaults.set(fields[field] ?? "", forKey: defaultsKey)
            defaults.set(Date().timeIntervalSince1970, forKey: waterKey)
            return
        }
        guard let pulled = await BridgeStateClient.pullResult(kind: kind),
              pulled.at > defaults.double(forKey: waterKey) else { return }
        defaults.set(pulled.value, forKey: defaultsKey)
        defaults.set(pulled.at, forKey: waterKey)
    }

    // MARK: - App Launch State Management

    /// Reset session state on app launch to prevent stale state issues
    public func resetSessionStateOnAppLaunch() {
        sharedDefaults?.set(false, forKey: UserDefaultsKeys.keyboardSessionActive)
        sharedDefaults?.removeObject(forKey: UserDefaultsKeys.keyboardSessionExpiryTime)
        sharedDefaults?.set(false, forKey: UserDefaultsKeys.isRecording)
        sharedDefaults?.removeObject(forKey: UserDefaultsKeys.transcribedText)
        updateTranscriptionStatus(.idle)

        sharedDefaults?.removeObject(forKey: UserDefaultsKeys.audioLevel)
        sharedDefaults?.removeObject(forKey: UserDefaultsKeys.transcriptionErrorMessage)

        sharedDefaults?.removeObject(forKey: UserDefaultsKeys.lastRecordingTimestamp)

        // Clear stale text processing state
        sharedDefaults?.removeObject(forKey: UserDefaultsKeys.textProcessingInput)
        sharedDefaults?.removeObject(forKey: UserDefaultsKeys.textProcessingModeName)
        sharedDefaults?.removeObject(forKey: UserDefaultsKeys.textProcessingPresetId)
        sharedDefaults?.removeObject(forKey: UserDefaultsKeys.textProcessingResult)
        sharedDefaults?.removeObject(forKey: UserDefaultsKeys.textProcessingErrorMessage)
        sharedDefaults?.removeObject(forKey: UserDefaultsKeys.voiceInstructionTargetText)
        sharedDefaults?.removeObject(forKey: UserDefaultsKeys.voiceInstructionModeName)

        logger.logError("🧹 Complete session state reset on app launch - fresh start")
    }

    // MARK: - Public Interface for Keyboard Extension

    /// Requests the main app to start recording (called from keyboard extension).
    public func requestStartRecording() {
        let timestamp = Date().timeIntervalSince1970
        sharedDefaults?.set(timestamp, forKey: UserDefaultsKeys.lastRecordingTimestamp)
        postDarwinNotification(NotificationNames.startRecording)
    }

    public func requestStartRecordingFromControl() {
        postDarwinNotification(NotificationNames.startRecordingFromControl)
    }

    /// Requests the main app to stop recording and begin transcription.
    public func requestStopRecording() {
        let timestamp = Date().timeIntervalSince1970
        sharedDefaults?.set(timestamp, forKey: UserDefaultsKeys.lastRecordingTimestamp)
        postDarwinNotification(NotificationNames.stopRecording)
    }

    /// Requests the main app to cancel the current recording or transcription.
    public func requestCancelRecording() {
        let timestamp = Date().timeIntervalSince1970
        sharedDefaults?.set(timestamp, forKey: UserDefaultsKeys.lastRecordingTimestamp)
        postDarwinNotification(NotificationNames.cancelRecording)
    }

    public func requestTerminateSessionFromLiveActivity() {
        postDarwinNotification(NotificationNames.terminateSessionFromLiveActivity)
        logger.logError("📡 Requested session termination from Live Activity")
    }

    public var isRecording: Bool {
        let storedState = sharedDefaults?.bool(forKey: UserDefaultsKeys.isRecording) ?? false
        let timestamp = sharedDefaults?.double(forKey: UserDefaultsKeys.lastRecordingTimestamp) ?? 0
        let currentTime = Date().timeIntervalSince1970

        if storedState && (currentTime - timestamp) > 30 && !isKeyboardSessionActive {
            logger.logError("⚠️ Recording state appears stale, clearing it")
            updateRecordingState(false)
            return false
        }

        return storedState
    }

    /// Raw `isRecording` flag without the 30-second staleness check.
    /// Use when you need the stored value as-is - e.g. from a polling loop
    /// where the getter's side-effect of clearing the flag mid-recording
    /// would corrupt state. Only the default `isRecording` getter (with
    /// its crash-recovery semantics) should be used by UI-level callers.
    public var isRecordingRaw: Bool {
        sharedDefaults?.bool(forKey: UserDefaultsKeys.isRecording) ?? false
    }

    // MARK: - Public Interface for Main App

    public func updateRecordingState(_ isRecording: Bool) {
        sharedDefaults?.set(isRecording, forKey: UserDefaultsKeys.isRecording)
        sharedDefaults?.set(Date().timeIntervalSince1970, forKey: UserDefaultsKeys.lastRecordingTimestamp)
        postDarwinNotification(NotificationNames.recordingStateChanged)
        logger.logError("📡 Updated recording state: \(isRecording)")
    }

    // MARK: - Audio Level Sharing
    public func updateAudioLevel(_ level: CGFloat) {
        let clamped = max(0, min(1, level))
        sharedDefaults?.set(Double(clamped), forKey: UserDefaultsKeys.audioLevel)
        postDarwinNotification(NotificationNames.audioLevelUpdated)
    }

    public var currentAudioLevel: CGFloat {
        let value = sharedDefaults?.double(forKey: UserDefaultsKeys.audioLevel) ?? 0
        return CGFloat(max(0, min(1, value)))
    }

    // MARK: - Keyboard Dictation Session Management

    /// Sentinel `timeoutSeconds` for a keyboard session that never expires on its
    /// own (Settings -> Keyboard -> Session Timeout -> "Never"). Such a session is
    /// stored with an expiry in the distant future, so every expiry comparison
    /// keeps working unchanged and only an explicit
    /// ``deactivateKeyboardSession()`` ends it.
    public static let sessionTimeoutNever = 0

    /// Wall-clock expiry stamp for a session started/refreshed right now with
    /// `timeoutSeconds`, honouring the ``sessionTimeoutNever`` sentinel.
    private func expiryTime(forTimeout timeoutSeconds: Int) -> TimeInterval {
        guard timeoutSeconds != Self.sessionTimeoutNever else {
            return Date.distantFuture.timeIntervalSince1970
        }
        return Date().timeIntervalSince1970 + Double(timeoutSeconds)
    }

    /// Activates a keyboard recording session with the specified timeout.
    ///
    /// - Parameter timeoutSeconds: How long the session remains active without
    ///   activity, or ``sessionTimeoutNever`` for a session with no expiry.
    public func activateKeyboardSession(timeoutSeconds: Int) {
        sharedDefaults?.set(true, forKey: UserDefaultsKeys.keyboardSessionActive)
        sharedDefaults?.set(expiryTime(forTimeout: timeoutSeconds), forKey: UserDefaultsKeys.keyboardSessionExpiryTime)
        sharedDefaults?.set(Date().timeIntervalSince1970, forKey: UserDefaultsKeys.lastRecordingTimestamp)
        postDarwinNotification(NotificationNames.keyboardSessionActivated)
        if timeoutSeconds == Self.sessionTimeoutNever {
            logger.logError("🔑 Keyboard session activated with no timeout")
        } else {
            logger.logError("🔑 Keyboard session activated for \(timeoutSeconds) seconds")
        }
    }

    public var isKeyboardSessionActive: Bool {
        guard let defaults = sharedDefaults else { return false }

        let isActive = defaults.bool(forKey: UserDefaultsKeys.keyboardSessionActive)
        let expiryTime = defaults.double(forKey: UserDefaultsKeys.keyboardSessionExpiryTime)
        let currentTime = Date().timeIntervalSince1970

        if isActive && currentTime > expiryTime {
            let isCurrentlyRecording = defaults.bool(forKey: UserDefaultsKeys.isRecording)
            if isCurrentlyRecording {
                return true
            }
            deactivateKeyboardSession()
            return false
        }

        return isActive
    }

    public func deactivateKeyboardSession() {
        let wasActive = sharedDefaults?.bool(forKey: UserDefaultsKeys.keyboardSessionActive) ?? true
        guard wasActive else { return }

        sharedDefaults?.set(false, forKey: UserDefaultsKeys.keyboardSessionActive)
        sharedDefaults?.removeObject(forKey: UserDefaultsKeys.keyboardSessionExpiryTime)
        postDarwinNotification(NotificationNames.keyboardSessionExpired)
        logger.logError("🔑 Keyboard session deactivated")
    }

    public func refreshKeyboardSessionExpiry(timeoutSeconds: Int) {
        guard let defaults = sharedDefaults else { return }
        let isActive = defaults.bool(forKey: UserDefaultsKeys.keyboardSessionActive)
        guard isActive else { return }
        defaults.set(expiryTime(forTimeout: timeoutSeconds), forKey: UserDefaultsKeys.keyboardSessionExpiryTime)
        defaults.set(Date().timeIntervalSince1970, forKey: UserDefaultsKeys.lastRecordingTimestamp)
        if timeoutSeconds == Self.sessionTimeoutNever {
            logger.logError("🔁 Keyboard session expiry refreshed with no timeout")
        } else {
            logger.logError("🔁 Keyboard session expiry refreshed for \(timeoutSeconds) seconds")
        }
    }

    // MARK: - Keyboard Clipboard Context

    /// Stores clipboard text captured by the keyboard extension for AI context.
    public func setKeyboardClipboardContext(_ text: String?) {
        if let text {
            sharedDefaults?.set(text, forKey: UserDefaultsKeys.keyboardClipboardContext)
        } else {
            sharedDefaults?.removeObject(forKey: UserDefaultsKeys.keyboardClipboardContext)
        }
        // 桥模式：上下文要赶在随后开始录音的通知之前到达主 App，走剪贴板
        if LocalBridge.isEnabled, !LocalBridge.isMainAppProcess {
            BridgePasteboard.send(kind: .clipboardContext, fields: [
                "present": text == nil ? "0" : "1",
                "text": text ?? "",
            ])
        }
    }

    /// Retrieves and clears the keyboard-captured clipboard context.
    public func getAndConsumeKeyboardClipboardContext() -> String? {
        guard let defaults = sharedDefaults else { return nil }
        let text = defaults.string(forKey: UserDefaultsKeys.keyboardClipboardContext)
        if text != nil {
            defaults.removeObject(forKey: UserDefaultsKeys.keyboardClipboardContext)
        }
        return text
    }

    // MARK: - Text Processing (Keyboard Rewrite)

    /// Sends text, mode name, and optional preset ID from the keyboard extension to the main app for AI processing.
    public func requestTextProcessing(text: String, modeName: String, presetId: String? = nil) {
        sharedDefaults?.set(text, forKey: UserDefaultsKeys.textProcessingInput)
        sharedDefaults?.set(modeName, forKey: UserDefaultsKeys.textProcessingModeName)
        if let presetId {
            sharedDefaults?.set(presetId, forKey: UserDefaultsKeys.textProcessingPresetId)
        } else {
            sharedDefaults?.removeObject(forKey: UserDefaultsKeys.textProcessingPresetId)
        }
        sharedDefaults?.synchronize()
        // 桥模式：共享存储跨不了进程，同一份载荷同步经剪贴板送出（必须赶在通知之前）
        if LocalBridge.isEnabled, !LocalBridge.isMainAppProcess {
            BridgePasteboard.send(kind: .textProcessing, fields: [
                "text": text,
                "modeName": modeName,
                "presetId": presetId ?? "",
            ])
        }
        postDarwinNotification(NotificationNames.requestTextProcessing)
        logger.logError("📝 Keyboard requested text processing with mode: \(modeName), preset: \(presetId ?? "nil"), text length: \(text.count)")
    }

    /// Retrieves and clears the pending text processing request (called by main app).
    public func getAndConsumePendingTextProcessing() -> (text: String, modeName: String, presetId: String?)? {
        guard let defaults = sharedDefaults,
              let text = defaults.string(forKey: UserDefaultsKeys.textProcessingInput),
              let modeName = defaults.string(forKey: UserDefaultsKeys.textProcessingModeName),
              !text.isEmpty else {
            return nil
        }
        let presetId = defaults.string(forKey: UserDefaultsKeys.textProcessingPresetId)
        defaults.removeObject(forKey: UserDefaultsKeys.textProcessingInput)
        defaults.removeObject(forKey: UserDefaultsKeys.textProcessingModeName)
        defaults.removeObject(forKey: UserDefaultsKeys.textProcessingPresetId)
        return (text, modeName, presetId)
    }

    // MARK: - Voice Instruction (Keyboard "Speak to Edit")

    /// Requests the main app to record a spoken rewrite instruction for `targetText`.
    ///
    /// Parks the payload first, then posts the ordinary start-recording notification.
    /// The main app consumes the payload in its start handler, which is what routes
    /// the recording to the instruction path (no AI enhancement, nothing persisted)
    /// instead of the usual new-note path. The rewritten text comes back over the
    /// existing `textProcessingCompleted` / `textProcessingError` notifications.
    public func requestVoiceInstructionRecording(targetText: String, modeName: String) {
        sharedDefaults?.set(targetText, forKey: UserDefaultsKeys.voiceInstructionTargetText)
        sharedDefaults?.set(modeName, forKey: UserDefaultsKeys.voiceInstructionModeName)
        sharedDefaults?.synchronize()
        // 桥模式：载荷先经剪贴板送出，随后 requestStartRecording 的通知才发
        if LocalBridge.isEnabled, !LocalBridge.isMainAppProcess {
            BridgePasteboard.send(kind: .voiceInstruction, fields: [
                "targetText": targetText,
                "modeName": modeName,
            ])
        }
        logger.logError("🗣️ Keyboard requested voice instruction recording with mode: \(modeName), target length: \(targetText.count)")
        requestStartRecording()
    }

    /// Retrieves and clears the pending voice instruction target (called by main app).
    public func getAndConsumePendingVoiceInstruction() -> (targetText: String, modeName: String)? {
        guard let defaults = sharedDefaults,
              let targetText = defaults.string(forKey: UserDefaultsKeys.voiceInstructionTargetText),
              let modeName = defaults.string(forKey: UserDefaultsKeys.voiceInstructionModeName),
              !targetText.isEmpty else {
            clearPendingVoiceInstruction()
            return nil
        }
        clearPendingVoiceInstruction()
        return (targetText, modeName)
    }

    /// Drops any parked voice instruction payload without consuming it.
    ///
    /// Called when the keyboard abandons the request before the main app picked
    /// it up, so a later ordinary dictation is not mistaken for an instruction.
    public func clearPendingVoiceInstruction() {
        sharedDefaults?.removeObject(forKey: UserDefaultsKeys.voiceInstructionTargetText)
        sharedDefaults?.removeObject(forKey: UserDefaultsKeys.voiceInstructionModeName)
    }

    /// Shares the AI-processed text result back to the keyboard extension (called by main app).
    public func shareTextProcessingResult(_ text: String) {
        sharedDefaults?.set(text, forKey: UserDefaultsKeys.textProcessingResult)
        sharedDefaults?.synchronize()
        // 桥模式：结果经剪贴板回传 + 暂存进本地服务的结果槽（赶在完成通知之前）。
        // 槽是 fork5 的主通道：剪贴板在自签环境跨进程读不到。
        if LocalBridge.isEnabled, LocalBridge.isMainAppProcess {
            BridgePasteboard.send(kind: .textResult, fields: ["text": text])
            bridgeServer?.stashResult(kind: BridgePayloadKind.textResult.rawValue, value: text)
        }
        postDarwinNotification(NotificationNames.textProcessingCompleted)
        logger.logError("📝 Shared text processing result, length: \(text.count)")
    }

    /// Shares a text processing error message with the keyboard extension (called by main app).
    public func shareTextProcessingError(_ message: String) {
        sharedDefaults?.set(message, forKey: UserDefaultsKeys.textProcessingErrorMessage)
        sharedDefaults?.synchronize()
        // 桥模式：错误经剪贴板回传 + 暂存结果槽（同 shareTextProcessingResult）
        if LocalBridge.isEnabled, LocalBridge.isMainAppProcess {
            BridgePasteboard.send(kind: .textError, fields: ["message": message])
            bridgeServer?.stashResult(kind: BridgePayloadKind.textError.rawValue, value: message)
        }
        postDarwinNotification(NotificationNames.textProcessingError)
        logger.logError("📝 Shared text processing error: \(message)")
    }

    /// Retrieves and clears the text processing result (called by keyboard extension).
    public func getAndConsumeTextProcessingResult() -> String? {
        guard let defaults = sharedDefaults else { return nil }
        let text = defaults.string(forKey: UserDefaultsKeys.textProcessingResult)
        if text != nil {
            defaults.removeObject(forKey: UserDefaultsKeys.textProcessingResult)
        }
        return text
    }

    /// Retrieves and clears the text processing error message (called by keyboard extension).
    public func getAndConsumeTextProcessingError() -> String? {
        guard let defaults = sharedDefaults else { return nil }
        let message = defaults.string(forKey: UserDefaultsKeys.textProcessingErrorMessage)
        if message != nil {
            defaults.removeObject(forKey: UserDefaultsKeys.textProcessingErrorMessage)
        }
        return message
    }

    // MARK: - Keyboard Success Tracking

    /// Called from keyboard extension after first successful transcription insertion.
    /// The main app checks this flag on launch to trigger a deferred rating request.
    public func recordKeyboardSuccessfulUse() {
        guard sharedDefaults?.bool(forKey: AppGroupCoordinator.kKeyboardFirstSuccessfulUse) != true else { return }
        sharedDefaults?.set(true, forKey: AppGroupCoordinator.kKeyboardFirstSuccessfulUse)
        sharedDefaults?.synchronize()
    }

    /// Returns true if keyboard was used successfully and clears the flag.
    /// Call from main app on launch to trigger a deferred rating request.
    public func consumeKeyboardSuccessFlag() -> Bool {
        guard sharedDefaults?.bool(forKey: AppGroupCoordinator.kKeyboardFirstSuccessfulUse) == true else { return false }
        sharedDefaults?.set(false, forKey: AppGroupCoordinator.kKeyboardFirstSuccessfulUse)
        sharedDefaults?.synchronize()
        return true
    }

    // MARK: - Transcribed Text Sharing

    /// Shares transcribed text with extensions and updates status to completed.
    ///
    /// - Parameter text: The transcribed (and optionally enhanced) text.
    public func shareTranscribedText(_ text: String) {
        sharedDefaults?.set(text, forKey: UserDefaultsKeys.transcribedText)
        updateTranscriptionStatus(.completed)
        // 桥模式：转写文本经剪贴板回传 + 暂存进本地服务的结果槽（赶在完成通知之前）。
        // 槽是 fork5 的主通道：命名剪贴板在自签环境跨进程读不到，曾导致
        // 主 App 里有转写记录、宿主输入框里永远没字。
        if LocalBridge.isEnabled, LocalBridge.isMainAppProcess {
            BridgePasteboard.send(kind: .transcribedText, fields: ["text": text])
            bridgeServer?.stashResult(kind: BridgePayloadKind.transcribedText.rawValue, value: text)
        }
        postDarwinNotification(NotificationNames.transcriptionCompleted)
        logger.logError("📝 Shared transcribed text: \(text.prefix(50))...")
    }

    /// Publishes an Obsidian URL and the clipboard payload Obsidian should
    /// read when the URL opens. Used only when the transcription originates
    /// from the keyboard extension, so the extension can open the URL and
    /// write the clipboard from a foregrounded host-app context.
    public func setPendingObsidianHandoff(url: URL, clipboardText: String) {
        sharedDefaults?.set(url.absoluteString, forKey: UserDefaultsKeys.pendingObsidianURL)
        sharedDefaults?.set(clipboardText, forKey: UserDefaultsKeys.pendingObsidianClipboard)
    }

    /// Consumes a pending Obsidian hand-off, clearing both keys. Returns nil
    /// if the main app did not delegate on this transcription (e.g. a main-app
    /// recording where the main app opened `obsidian://` directly).
    public func consumePendingObsidianHandoff() -> (url: URL, clipboardText: String)? {
        guard let defaults = sharedDefaults,
              let raw = defaults.string(forKey: UserDefaultsKeys.pendingObsidianURL),
              let url = URL(string: raw)
        else { return nil }
        let clipboardText = defaults.string(forKey: UserDefaultsKeys.pendingObsidianClipboard) ?? ""
        defaults.removeObject(forKey: UserDefaultsKeys.pendingObsidianURL)
        defaults.removeObject(forKey: UserDefaultsKeys.pendingObsidianClipboard)
        return (url, clipboardText)
    }

    /// Retrieves and clears the shared transcribed text.
    ///
    /// - Returns: The transcribed text, or `nil` if none is available.
    public func getAndConsumeTranscribedText() -> String? {
        guard let defaults = sharedDefaults else { return nil }

        let text = defaults.string(forKey: UserDefaultsKeys.transcribedText)
        if text != nil {
            defaults.removeObject(forKey: UserDefaultsKeys.transcribedText)
            updateTranscriptionStatus(.idle)
        }

        return text
    }

    public func updateTranscriptionStatus(_ status: TranscriptionStatus) {
        sharedDefaults?.set(status.rawValue, forKey: UserDefaultsKeys.transcriptionStatus)
        sharedDefaults?.set(Date().timeIntervalSince1970, forKey: UserDefaultsKeys.lastRecordingTimestamp)

        logger.logError("📊 Transcription status: \(status.rawValue)")

        switch status {
        case .transcribing:
            postDarwinNotification(NotificationNames.transcriptionTranscribing)
        case .enhancing:
            postDarwinNotification(NotificationNames.transcriptionEnhancing)
        case .error:
            postDarwinNotification(NotificationNames.transcriptionError)
        case .completed:
            break
        case .idle:
            postDarwinNotification(NotificationNames.transcriptionCancelled)
        case .recording:
            break
        }
    }

    /// Convenience to set an error message and notify listeners of an error state.
    public func updateTranscriptionError(_ message: String) {
        sharedDefaults?.set(message, forKey: UserDefaultsKeys.transcriptionErrorMessage)
        // 桥模式：错误信息经剪贴板回传 + 暂存结果槽（赶在状态通知之前）
        if LocalBridge.isEnabled, LocalBridge.isMainAppProcess {
            BridgePasteboard.send(kind: .transcriptionError, fields: ["message": message])
            bridgeServer?.stashResult(kind: BridgePayloadKind.transcriptionError.rawValue, value: message)
        }
        updateTranscriptionStatus(.error)
    }

    public var transcriptionStatus: TranscriptionStatus {
        guard let defaults = sharedDefaults,
              let statusString = defaults.string(forKey: UserDefaultsKeys.transcriptionStatus),
              let status = TranscriptionStatus(rawValue: statusString) else {
            return .idle
        }
        return status
    }

    public func getAndConsumeTranscriptionErrorMessage() -> String? {
        guard let defaults = sharedDefaults else { return nil }
        let message = defaults.string(forKey: UserDefaultsKeys.transcriptionErrorMessage)
        if message != nil {
            defaults.removeObject(forKey: UserDefaultsKeys.transcriptionErrorMessage)
        }
        return message
    }

    // MARK: - VivaMode Management

    public func setSelectedVivaMode(_ modeName: String) {
        sharedDefaults?.set(modeName, forKey: AppGroupCoordinator.selectedVivaModeKey)
        sharedDefaults?.synchronize()
        // 桥模式：模式选择同步经剪贴板告知主 App（其本地存储随后 ingest 落地）
        if LocalBridge.isEnabled, !LocalBridge.isMainAppProcess {
            BridgePasteboard.send(kind: .selectedMode, fields: ["name": modeName])
        }
        postDarwinNotification(NotificationNames.vivaModeChanged)
        logger.logInfo("📱 Keyboard Extension set selected VivaMode: \(modeName)")
    }

    // MARK: - Smart Formatting Setting

    /// Whether to apply smart formatting (spacing, capitalization) when pasting transcription
    /// Defaults to true if not set
    public var isSmartFormattingOnPasteEnabled: Bool {
        get {
            // Return true by default if the key doesn't exist
            if sharedDefaults?.object(forKey: AppGroupCoordinator.kSmartFormattingOnPaste) == nil {
                return true
            }
            return sharedDefaults?.bool(forKey: AppGroupCoordinator.kSmartFormattingOnPaste) ?? true
        }
        set {
            sharedDefaults?.set(newValue, forKey: AppGroupCoordinator.kSmartFormattingOnPaste)
            sharedDefaults?.synchronize()
        }
    }

    /// Whether to copy transcription to clipboard after inserting
    /// Defaults to false if not set
    public var isKeepTranscriptInClipboardEnabled: Bool {
        get {
            return sharedDefaults?.bool(forKey: AppGroupCoordinator.kKeepTranscriptInClipboard) ?? false
        }
        set {
            sharedDefaults?.set(newValue, forKey: AppGroupCoordinator.kKeepTranscriptInClipboard)
            sharedDefaults?.synchronize()
        }
    }

    /// Legacy global speaker-label switch, superseded by `VivaMode.speakerLabelsEnabled`.
    ///
    /// Nothing writes it any more - it survives only as the value a mode saved
    /// before the per-mode move inherits when it decodes. Once every mode has
    /// been re-encoded with its own flag this is dead and can go.
    /// Defaults to false if not set.
    public var isSpeakerDiarizationEnabled: Bool {
        get {
            sharedDefaults?.bool(forKey: AppGroupCoordinator.kIsSpeakerDiarizationEnabled) ?? false
        }
        set {
            sharedDefaults?.set(newValue, forKey: AppGroupCoordinator.kIsSpeakerDiarizationEnabled)
            sharedDefaults?.synchronize()
        }
    }

    /// How much Gemini's general-purpose models may reason before answering a
    /// transcription request - "low", "medium" or "high".
    ///
    /// Stored as a raw string rather than an enum so the AppGroup module stays
    /// free of a CloudTranscription dependency; the transcription layer maps it
    /// onto `GeminiTranscriptionService.ThinkingLevel` and falls back to "low"
    /// on anything it does not recognise. Not read by the dedicated
    /// `gemini-3.5-transcribe` model, which rejects the field.
    public var geminiTranscriptionThinkingLevel: String {
        get {
            sharedDefaults?.string(forKey: AppGroupCoordinator.kGeminiTranscriptionThinkingLevel) ?? "low"
        }
        set {
            sharedDefaults?.set(newValue, forKey: AppGroupCoordinator.kGeminiTranscriptionThinkingLevel)
            sharedDefaults?.synchronize()
        }
    }

    /// A user-written instruction sent alongside the audio to Gemini's
    /// general-purpose models. Empty means the built-in instruction is used.
    public var geminiTranscriptionPrompt: String {
        get {
            sharedDefaults?.string(forKey: AppGroupCoordinator.kGeminiTranscriptionPrompt) ?? ""
        }
        set {
            sharedDefaults?.set(newValue, forKey: AppGroupCoordinator.kGeminiTranscriptionPrompt)
            sharedDefaults?.synchronize()
        }
    }

    /// Whether haptic feedback is enabled for keyboard key presses
    /// Defaults to true if not set
    public var isKeyboardHapticFeedbackEnabled: Bool {
        get {
            if sharedDefaults?.object(forKey: AppGroupCoordinator.kIsKeyboardHapticFeedbackEnabled) == nil {
                return true
            }
            return sharedDefaults?.bool(forKey: AppGroupCoordinator.kIsKeyboardHapticFeedbackEnabled) ?? true
        }
        set {
            sharedDefaults?.set(newValue, forKey: AppGroupCoordinator.kIsKeyboardHapticFeedbackEnabled)
            sharedDefaults?.synchronize()
        }
    }
    
    /// Whether sound feedback is enabled for keyboard key presses
    /// Defaults to true if not set
    public var isKeyboardSoundFeedbackEnabled: Bool {
        get {
            if sharedDefaults?.object(forKey: AppGroupCoordinator.kIsKeyboardSoundFeedbackEnabled) == nil {
                return true
            }
            return sharedDefaults?.bool(forKey: AppGroupCoordinator.kIsKeyboardSoundFeedbackEnabled) ?? true
        }
        set {
            sharedDefaults?.set(newValue, forKey: AppGroupCoordinator.kIsKeyboardSoundFeedbackEnabled)
            sharedDefaults?.synchronize()
        }
    }

    /// The set of languages the user has enabled for the custom keyboard.
    ///
    /// English is the implicit floor: if the persisted set is empty (first run,
    /// corrupted defaults, or the user tries to disable everything), this
    /// returns `[.english]`. The setter coerces an empty new value back to
    /// English for the same reason.
    ///
    /// Stored as a comma-separated list of raw values in shared UserDefaults.
    public var enabledKeyboardLanguages: Set<KeyboardLanguage> {
        get {
            ensureLanguageSettingsUpToDate()
            let langs = AppGroupCoordinator.parseLanguages(
                sharedDefaults?.string(forKey: AppGroupCoordinator.kEnabledKeyboardLanguages)
            )
            return langs.isEmpty ? [.english] : langs
        }
        set {
            // Run migration and seeding before persisting so a write that beats
            // any read (e.g. a future code path that calls the setter first)
            // cannot leave the markers unset and have the next getter overwrite
            // the user's value with the derived seed.
            ensureLanguageSettingsUpToDate()
            let safe = newValue.isEmpty ? Set([KeyboardLanguage.english]) : newValue
            let raw = AppGroupCoordinator.serializeLanguages(safe)
            sharedDefaults?.set(raw, forKey: AppGroupCoordinator.kEnabledKeyboardLanguages)
            // If the currently active language was just disabled, snap to the
            // first enabled language so the keyboard never points at a missing one.
            if let current = sharedDefaults?.string(forKey: AppGroupCoordinator.kCurrentKeyboardLanguage),
               let lang = KeyboardLanguage(rawValue: current),
               !safe.contains(lang) {
                let fallback = KeyboardLanguage.allCases.first(where: { safe.contains($0) }) ?? .english
                sharedDefaults?.set(fallback.rawValue, forKey: AppGroupCoordinator.kCurrentKeyboardLanguage)
            }
            sharedDefaults?.synchronize()
        }
    }

    /// The language the keyboard is currently typing in.
    ///
    /// Always one of `enabledKeyboardLanguages`; the getter clamps to the first
    /// enabled language if the persisted value is missing or no longer enabled.
    public var currentKeyboardLanguage: KeyboardLanguage {
        get {
            ensureLanguageSettingsUpToDate()
            let enabled = enabledKeyboardLanguages
            guard let raw = sharedDefaults?.string(forKey: AppGroupCoordinator.kCurrentKeyboardLanguage),
                  let lang = KeyboardLanguage(rawValue: raw),
                  enabled.contains(lang) else {
                return KeyboardLanguage.allCases.first(where: { enabled.contains($0) }) ?? .english
            }
            return lang
        }
        set {
            ensureLanguageSettingsUpToDate()
            sharedDefaults?.set(newValue.rawValue, forKey: AppGroupCoordinator.kCurrentKeyboardLanguage)
            sharedDefaults?.synchronize()
        }
    }

    /// One-shot migration from the old layout-style/Russian-toggle pair to the
    /// new enabled-languages set. Idempotent via a marker key.
    ///
    /// Seeding sources, all unioned together:
    /// - English (always - the baseline fallback).
    /// - Legacy `keyboardLayoutStyle == "azerty"` -> `.french` (existing testers).
    /// - Legacy `isRussianLayoutEnabled == true`   -> `.russian` (existing testers).
    /// - `KeyboardLanguage.preferredFromSystem()` -> auto-enable any language
    ///   the user has set in iOS Settings -> General -> Language & Region.
    ///   This is the "just works on first launch" hint - user can toggle off
    ///   anything they don't want.
    ///
    /// Current language: `.russian` if the legacy toggle was on Russian and
    /// Russian is in the enabled set, otherwise `.english`.
    private func ensureLanguageSettingsMigrated() {
        guard let defaults = sharedDefaults,
              !defaults.bool(forKey: AppGroupCoordinator.kDidMigrateLanguageSettings) else {
            return
        }

        var enabled: Set<KeyboardLanguage> = [.english]
        if defaults.string(forKey: AppGroupCoordinator.kLegacyKeyboardLayoutStyle) == "azerty" {
            enabled.insert(.french)
        }
        if defaults.bool(forKey: AppGroupCoordinator.kLegacyIsRussianLayoutEnabled) {
            enabled.insert(.russian)
        }
        enabled.formUnion(KeyboardLanguage.preferredFromSystem())

        // Carry forward whichever language the user was actively typing in on
        // 3.2.0/3.2.x: Russian if the toggle was on Russian, otherwise French if
        // they had AZERTY selected (since AZERTY = French and that picker was
        // their active layout). Otherwise default to English.
        let current: KeyboardLanguage
        if defaults.bool(forKey: AppGroupCoordinator.kLegacyIsCurrentlyRussian), enabled.contains(.russian) {
            current = .russian
        } else if defaults.string(forKey: AppGroupCoordinator.kLegacyKeyboardLayoutStyle) == "azerty",
                  enabled.contains(.french) {
            current = .french
        } else {
            current = .english
        }

        defaults.set(
            AppGroupCoordinator.serializeLanguages(enabled),
            forKey: AppGroupCoordinator.kEnabledKeyboardLanguages
        )
        defaults.set(current.rawValue, forKey: AppGroupCoordinator.kCurrentKeyboardLanguage)
        // This install has now been offered every language that exists today,
        // so `ensureNewLanguagesSeeded()` has nothing left to do until a new
        // case is added.
        defaults.set(
            AppGroupCoordinator.serializeLanguages(Set(KeyboardLanguage.allCases)),
            forKey: AppGroupCoordinator.kSeededLanguages
        )

        defaults.removeObject(forKey: AppGroupCoordinator.kLegacyKeyboardLayoutStyle)
        defaults.removeObject(forKey: AppGroupCoordinator.kLegacyIsRussianLayoutEnabled)
        defaults.removeObject(forKey: AppGroupCoordinator.kLegacyIsCurrentlyRussian)
        defaults.set(true, forKey: AppGroupCoordinator.kDidMigrateLanguageSettings)
        defaults.synchronize()
    }

    /// The languages that had already been offered to users before per-language
    /// seeding existed, used to backfill `kSeededLanguages` for installs that
    /// ran the one-shot migration under an older build.
    ///
    /// This is a frozen historical fact - the set that shipped on the App Store
    /// before this key was introduced. **Do not add new cases here.** A new
    /// language belongs in `KeyboardLanguage` only; leaving it out of this set
    /// is precisely what lets `ensureNewLanguagesSeeded()` pick it up.
    private static let preSeedingLanguages: Set<KeyboardLanguage> = [
        .english, .french, .german, .spanish, .russian
    ]

    /// Runs the language-settings migration, then auto-enables any language
    /// added since this install last looked.
    private func ensureLanguageSettingsUpToDate() {
        ensureLanguageSettingsMigrated()
        ensureNewLanguagesSeeded()
    }

    /// Auto-enables any `KeyboardLanguage` case that this install has never been
    /// offered, when it matches one of the user's iOS system languages.
    ///
    /// `ensureLanguageSettingsMigrated()` consults `preferredFromSystem()` only
    /// once, behind a boolean marker, so a language shipped in a later release
    /// would never auto-enable for anyone who had already migrated - a Czech
    /// user updating the app would have to find the toggle by hand. This runs
    /// on every access and closes that gap for every future language too.
    ///
    /// Each language is considered **exactly once**: `kSeededLanguages` records
    /// what has been offered, whether or not it was enabled. So a language the
    /// user deliberately switched off is never switched back on, and one that
    /// did not match their locales is not re-evaluated if they later change
    /// them. Seeding only ever adds, so the English floor is unaffected.
    ///
    /// - Parameter systemPreferred: The languages matching the user's iOS
    ///   language list. A parameter so the seeding is testable without touching
    ///   `Locale.preferredLanguages`, and an `@autoclosure` so that list is not
    ///   read on the common path where there is nothing new to seed - this runs
    ///   on every language read, including from the keyboard extension.
    func ensureNewLanguagesSeeded(
        systemPreferred: @autoclosure () -> Set<KeyboardLanguage> = KeyboardLanguage.preferredFromSystem()
    ) {
        guard let defaults = sharedDefaults else { return }

        let seeded: Set<KeyboardLanguage>
        if let raw = defaults.string(forKey: AppGroupCoordinator.kSeededLanguages) {
            seeded = AppGroupCoordinator.parseLanguages(raw)
        } else {
            seeded = AppGroupCoordinator.preSeedingLanguages
        }

        let unseen = Set(KeyboardLanguage.allCases).subtracting(seeded)
        guard !unseen.isEmpty else { return }

        let toEnable = unseen.intersection(systemPreferred())
        if !toEnable.isEmpty {
            let enabled = AppGroupCoordinator.parseLanguages(
                defaults.string(forKey: AppGroupCoordinator.kEnabledKeyboardLanguages)
            )
            let updated = (enabled.isEmpty ? [.english] : enabled).union(toEnable)
            defaults.set(
                AppGroupCoordinator.serializeLanguages(updated),
                forKey: AppGroupCoordinator.kEnabledKeyboardLanguages
            )
            logger.logInfo("Auto-enabled new keyboard languages: \(AppGroupCoordinator.serializeLanguages(toEnable))")
        }

        defaults.set(
            AppGroupCoordinator.serializeLanguages(Set(KeyboardLanguage.allCases)),
            forKey: AppGroupCoordinator.kSeededLanguages
        )
        defaults.synchronize()
    }

    /// Parses the comma-separated raw-value list used to persist a language set.
    /// Unknown raw values (a language removed in a later build) are dropped.
    static func parseLanguages(_ raw: String?) -> Set<KeyboardLanguage> {
        guard let raw, !raw.isEmpty else { return [] }
        return Set(raw.split(separator: ",").compactMap { KeyboardLanguage(rawValue: String($0)) })
    }

    /// Serializes a language set in canonical `allCases` order, so storage is
    /// deterministic and diffable regardless of `Set` iteration order.
    static func serializeLanguages(_ languages: Set<KeyboardLanguage>) -> String {
        KeyboardLanguage.allCases
            .filter { languages.contains($0) }
            .map(\.rawValue)
            .joined(separator: ",")
    }

    // MARK: - Share Extension Audio Handling

    /// Returns the shared container URL for storing audio files shared between app and extensions
    public var sharedAudioDirectory: URL? {
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId) else {
            return nil
        }
        let audioDir = containerURL.appendingPathComponent("SharedAudio")

        // Create directory if it doesn't exist
        if !FileManager.default.fileExists(atPath: audioDir.path) {
            try? FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
        }

        return audioDir
    }

    /// Saves the filename of a shared audio file pending transcription
    public func setPendingSharedAudioFileName(_ fileName: String) {
        sharedDefaults?.set(fileName, forKey: AppGroupCoordinator.kPendingSharedAudioFileName)
        sharedDefaults?.synchronize()
        logger.logInfo("📁 Saved pending shared audio file: \(fileName)")
    }

    /// Retrieves and clears the pending shared audio filename
    public func getAndConsumePendingSharedAudioFileName() -> String? {
        guard let fileName = sharedDefaults?.string(forKey: AppGroupCoordinator.kPendingSharedAudioFileName) else {
            return nil
        }
        sharedDefaults?.removeObject(forKey: AppGroupCoordinator.kPendingSharedAudioFileName)
        sharedDefaults?.synchronize()
        logger.logInfo("📁 Consumed pending shared audio file: \(fileName)")
        return fileName
    }

    /// Checks if there's a pending shared audio file
    public var hasPendingSharedAudio: Bool {
        sharedDefaults?.string(forKey: AppGroupCoordinator.kPendingSharedAudioFileName) != nil
    }

    /// Saves a language override for the pending shared audio transcription
    public func setPendingLanguageOverride(_ language: String?) {
        if let language = language {
            sharedDefaults?.set(language, forKey: AppGroupCoordinator.kPendingLanguageOverride)
        } else {
            sharedDefaults?.removeObject(forKey: AppGroupCoordinator.kPendingLanguageOverride)
        }
        sharedDefaults?.synchronize()
        logger.logInfo("📁 Saved pending language override: \(language ?? "nil")")
    }

    /// Retrieves and clears the pending language override
    public func getAndConsumePendingLanguageOverride() -> String? {
        guard let language = sharedDefaults?.string(forKey: AppGroupCoordinator.kPendingLanguageOverride) else {
            return nil
        }
        sharedDefaults?.removeObject(forKey: AppGroupCoordinator.kPendingLanguageOverride)
        sharedDefaults?.synchronize()
        logger.logInfo("📁 Consumed pending language override: \(language)")
        return language
    }

    /// Saves the source tag for a pending shared audio transcription
    public func setPendingSourceTag(_ tag: String) {
        sharedDefaults?.set(tag, forKey: AppGroupCoordinator.kPendingSourceTag)
        sharedDefaults?.synchronize()
        logger.logInfo("🏷️ Saved pending source tag: \(tag)")
    }

    /// Retrieves and clears the pending source tag
    public func getAndConsumePendingSourceTag() -> String? {
        guard let tag = sharedDefaults?.string(forKey: AppGroupCoordinator.kPendingSourceTag) else {
            return nil
        }
        sharedDefaults?.removeObject(forKey: AppGroupCoordinator.kPendingSourceTag)
        sharedDefaults?.synchronize()
        logger.logInfo("🏷️ Consumed pending source tag: \(tag)")
        return tag
    }

    // MARK: - Darwin Notifications (Real-time Communication)

    private func setupNotificationObservers() {
        guard let center = notificationCenter else { return }

        CFNotificationCenterAddObserver(
            center,
            Unmanaged.passUnretained(self).toOpaque(),
            { (center, observer, name, object, userInfo) in
                guard let observer = observer else { return }
                let coordinator = Unmanaged<AppGroupCoordinator>.fromOpaque(observer).takeUnretainedValue()
                coordinator.handleStartRecordingNotification()
            },
            NotificationNames.startRecording as CFString,
            nil,
            .deliverImmediately
        )

        CFNotificationCenterAddObserver(
            center,
            Unmanaged.passUnretained(self).toOpaque(),
            { (center, observer, name, object, userInfo) in
                guard let observer = observer else { return }
                let coordinator = Unmanaged<AppGroupCoordinator>.fromOpaque(observer).takeUnretainedValue()
                coordinator.handleStopRecordingNotification()
            },
            NotificationNames.stopRecording as CFString,
            nil,
            .deliverImmediately
        )

        CFNotificationCenterAddObserver(
            center,
            Unmanaged.passUnretained(self).toOpaque(),
            { (center, observer, name, object, userInfo) in
                guard let observer = observer else { return }
                let coordinator = Unmanaged<AppGroupCoordinator>.fromOpaque(observer).takeUnretainedValue()
                coordinator.handleCancelRecordingNotification()
            },
            NotificationNames.cancelRecording as CFString,
            nil,
            .deliverImmediately
        )

        CFNotificationCenterAddObserver(
            center,
            Unmanaged.passUnretained(self).toOpaque(),
            { (center, observer, name, object, userInfo) in
                guard let observer = observer else { return }
                let coordinator = Unmanaged<AppGroupCoordinator>.fromOpaque(observer).takeUnretainedValue()
                coordinator.handlePauseRecordingNotification()
            },
            NotificationNames.pauseRecording as CFString,
            nil,
            .deliverImmediately
        )

        CFNotificationCenterAddObserver(
            center,
            Unmanaged.passUnretained(self).toOpaque(),
            { (center, observer, name, object, userInfo) in
                guard let observer = observer else { return }
                let coordinator = Unmanaged<AppGroupCoordinator>.fromOpaque(observer).takeUnretainedValue()
                coordinator.handleResumeRecordingNotification()
            },
            NotificationNames.resumeRecording as CFString,
            nil,
            .deliverImmediately
        )

        CFNotificationCenterAddObserver(
            center,
            Unmanaged.passUnretained(self).toOpaque(),
            { (center, observer, name, object, userInfo) in
                guard let observer = observer else { return }
                let coordinator = Unmanaged<AppGroupCoordinator>.fromOpaque(observer).takeUnretainedValue()
                coordinator.handleTranscriptionTranscribingNotification()
            },
            NotificationNames.transcriptionTranscribing as CFString,
            nil,
            .deliverImmediately
        )

        CFNotificationCenterAddObserver(
            center,
            Unmanaged.passUnretained(self).toOpaque(),
            { (center, observer, name, object, userInfo) in
                guard let observer = observer else { return }
                let coordinator = Unmanaged<AppGroupCoordinator>.fromOpaque(observer).takeUnretainedValue()
                coordinator.handleTranscriptionEnhancingNotification()
            },
            NotificationNames.transcriptionEnhancing as CFString,
            nil,
            .deliverImmediately
        )

        CFNotificationCenterAddObserver(
            center,
            Unmanaged.passUnretained(self).toOpaque(),
            { (center, observer, name, object, userInfo) in
                guard let observer = observer else { return }
                let coordinator = Unmanaged<AppGroupCoordinator>.fromOpaque(observer).takeUnretainedValue()
                coordinator.handleTranscriptionCompletedNotification()
            },
            NotificationNames.transcriptionCompleted as CFString,
            nil,
            .deliverImmediately
        )

        CFNotificationCenterAddObserver(
            center,
            Unmanaged.passUnretained(self).toOpaque(),
            { (center, observer, name, object, userInfo) in
                guard let observer = observer else { return }
                let coordinator = Unmanaged<AppGroupCoordinator>.fromOpaque(observer).takeUnretainedValue()
                coordinator.handleTranscriptionErrorNotification()
            },
            NotificationNames.transcriptionError as CFString,
            nil,
            .deliverImmediately
        )

        CFNotificationCenterAddObserver(
            center,
            Unmanaged.passUnretained(self).toOpaque(),
            { (center, observer, name, object, userInfo) in
                guard let observer = observer else { return }
                let coordinator = Unmanaged<AppGroupCoordinator>.fromOpaque(observer).takeUnretainedValue()
                coordinator.handleTranscriptionCancelledNotification()
            },
            NotificationNames.transcriptionCancelled as CFString,
            nil,
            .deliverImmediately
        )

        CFNotificationCenterAddObserver(
            center,
            Unmanaged.passUnretained(self).toOpaque(),
            { (center, observer, name, object, userInfo) in
                guard let observer = observer else { return }
                let coordinator = Unmanaged<AppGroupCoordinator>.fromOpaque(observer).takeUnretainedValue()
                coordinator.handleAudioLevelUpdatedNotification()
            },
            NotificationNames.audioLevelUpdated as CFString,
            nil,
            .deliverImmediately
        )

        CFNotificationCenterAddObserver(
            center,
            Unmanaged.passUnretained(self).toOpaque(),
            { (center, observer, name, object, userInfo) in
                guard let observer = observer else { return }
                let coordinator = Unmanaged<AppGroupCoordinator>.fromOpaque(observer).takeUnretainedValue()
                coordinator.handleRecordingStateChangedNotification()
            },
            NotificationNames.recordingStateChanged as CFString,
            nil,
            .deliverImmediately
        )

        CFNotificationCenterAddObserver(
            center,
            Unmanaged.passUnretained(self).toOpaque(),
            { (center, observer, name, object, userInfo) in
                guard let observer = observer else { return }
                let coordinator = Unmanaged<AppGroupCoordinator>.fromOpaque(observer).takeUnretainedValue()
                coordinator.handleKeyboardSessionActivatedNotification()
            },
            NotificationNames.keyboardSessionActivated as CFString,
            nil,
            .deliverImmediately
        )

        CFNotificationCenterAddObserver(
            center,
            Unmanaged.passUnretained(self).toOpaque(),
            { (center, observer, name, object, userInfo) in
                guard let observer = observer else { return }
                let coordinator = Unmanaged<AppGroupCoordinator>.fromOpaque(observer).takeUnretainedValue()
                coordinator.handleKeyboardSessionExpiredNotification()
            },
            NotificationNames.keyboardSessionExpired as CFString,
            nil,
            .deliverImmediately
        )

        CFNotificationCenterAddObserver(
            center,
            Unmanaged.passUnretained(self).toOpaque(),
            { (center, observer, name, object, userInfo) in
                guard let observer = observer else { return }
                let coordinator = Unmanaged<AppGroupCoordinator>.fromOpaque(observer).takeUnretainedValue()
                coordinator.handleStartRecordingFromControlNotification()
            },
            NotificationNames.startRecordingFromControl as CFString,
            nil,
            .deliverImmediately
        )

        CFNotificationCenterAddObserver(
            center,
            Unmanaged.passUnretained(self).toOpaque(),
            { (center, observer, name, object, userInfo) in
                guard let observer = observer else { return }
                let coordinator = Unmanaged<AppGroupCoordinator>.fromOpaque(observer).takeUnretainedValue()
                coordinator.handleTerminateSessionFromLiveActivityNotification()
            },
            NotificationNames.terminateSessionFromLiveActivity as CFString,
            nil,
            .deliverImmediately
        )

        CFNotificationCenterAddObserver(
            center,
            Unmanaged.passUnretained(self).toOpaque(),
            { (center, observer, name, object, userInfo) in
                guard let observer = observer else { return }
                let coordinator = Unmanaged<AppGroupCoordinator>.fromOpaque(observer).takeUnretainedValue()
                coordinator.handleVivaModeChangedNotification()
            },
            NotificationNames.vivaModeChanged as CFString,
            nil,
            .deliverImmediately
        )

        // Text processing (keyboard rewrite)
        CFNotificationCenterAddObserver(
            center,
            Unmanaged.passUnretained(self).toOpaque(),
            { (center, observer, name, object, userInfo) in
                guard let observer = observer else { return }
                let coordinator = Unmanaged<AppGroupCoordinator>.fromOpaque(observer).takeUnretainedValue()
                coordinator.handleTextProcessingRequestedNotification()
            },
            NotificationNames.requestTextProcessing as CFString,
            nil,
            .deliverImmediately
        )

        CFNotificationCenterAddObserver(
            center,
            Unmanaged.passUnretained(self).toOpaque(),
            { (center, observer, name, object, userInfo) in
                guard let observer = observer else { return }
                let coordinator = Unmanaged<AppGroupCoordinator>.fromOpaque(observer).takeUnretainedValue()
                coordinator.handleTextProcessingCompletedNotification()
            },
            NotificationNames.textProcessingCompleted as CFString,
            nil,
            .deliverImmediately
        )

        CFNotificationCenterAddObserver(
            center,
            Unmanaged.passUnretained(self).toOpaque(),
            { (center, observer, name, object, userInfo) in
                guard let observer = observer else { return }
                let coordinator = Unmanaged<AppGroupCoordinator>.fromOpaque(observer).takeUnretainedValue()
                coordinator.handleTextProcessingErrorNotification()
            },
            NotificationNames.textProcessingError as CFString,
            nil,
            .deliverImmediately
        )
    }

    private func removeNotificationObservers() {
        guard let center = notificationCenter else { return }
        CFNotificationCenterRemoveEveryObserver(center, Unmanaged.passUnretained(self).toOpaque())
    }

    private func postDarwinNotification(_ name: String) {
        guard let center = notificationCenter else { return }
        CFNotificationCenterPostNotification(
            center,
            CFNotificationName(name as CFString),
            nil,
            nil,
            true
        )
    }

    // MARK: - Notification Handlers

    private func handleStartRecordingNotification() {
        // 桥模式：先把键盘经剪贴板送来的载荷（语音指令/剪贴板上下文/模式）落地，
        // 业务回调随后读取本地存储时才能拿到
        ingestBridgePayloads()
        Task { @MainActor in
            onStartRecordingRequested?()
        }
    }

    private func handleStopRecordingNotification() {
        Task { @MainActor in
            onStopRecordingRequested?()
        }
    }

    private func handleCancelRecordingNotification() {
        Task { @MainActor in
            onCancelRecordingRequested?()
        }
    }

    private func handlePauseRecordingNotification() {
        Task { @MainActor in
            onPauseRecordingRequested?()
        }
    }

    private func handleResumeRecordingNotification() {
        Task { @MainActor in
            onResumeRecordingRequested?()
        }
    }

    private func handleTranscriptionTranscribingNotification() {
        Task { @MainActor in
            onTranscriptionTranscribing?()
        }
    }

    private func handleTranscriptionEnhancingNotification() {
        Task { @MainActor in
            onTranscriptionEnhancing?()
        }
    }

    private func handleTranscriptionCompletedNotification() {
        Task { @MainActor in
            await ingestBridgeResult(kind: .transcribedText, defaultsKey: UserDefaultsKeys.transcribedText, field: "text")
            let text = getAndConsumeTranscribedText() ?? ""
            onTranscriptionCompleted?(text)
        }
    }

    private func handleTranscriptionErrorNotification() {
        Task { @MainActor in
            await ingestBridgeResult(kind: .transcriptionError, defaultsKey: UserDefaultsKeys.transcriptionErrorMessage, field: "message")
            let message = getAndConsumeTranscriptionErrorMessage() ?? ""
            onTranscriptionError?()
            if !message.isEmpty {
                onTranscriptionErrorMessage?(message)
            }
        }
    }

    private func handleTranscriptionCancelledNotification() {
        Task { @MainActor in
            onTranscriptionCancelled?()
        }
    }

    private func handleAudioLevelUpdatedNotification() {
        Task { @MainActor in
            // 桥模式：电平值在主 App 进程里，先拉一次状态快照刷新缓存
            let pulled = await pullBridgeStateIntoCache()
            let level = currentAudioLevel
            onAudioLevelUpdated?(level)
            // 对账：录音进行中电平一直在流。即使录音状态通知那次拉取
            // 失败导致键盘 UI 没翻到录音态，这里也能在下一次电平 tick
            // 把它纠回来，而不是整场都停留在普通键盘界面。
            if isRecording != lastDeliveredRecordingState {
                deliverRecordingState()
            }
            if !pulled {
                // 拉取失败时上面按旧缓存的比对可能静默无动作；照录音
                // 状态通知的样子 1 秒后重试一次再对账，不让单次失败
                // 成为整场不翻红的最后一根稻草。
                try? await Task.sleep(for: .seconds(1))
                if await pullBridgeStateIntoCache(),
                   isRecording != lastDeliveredRecordingState {
                    deliverRecordingState()
                }
            }
        }
    }

    private func handleRecordingStateChangedNotification() {
        Task { @MainActor in
            let pulled = await pullBridgeStateIntoCache()
            deliverRecordingState()
            if !pulled {
                // 拉取失败时缓存还是旧值，上面递交的可能是错的；而且
                // 录音状态通知整场只发一次，不补一次就永远错下去。
                // 1 秒后重拉一次并重新递交，覆盖掉这次错误递交。
                try? await Task.sleep(for: .seconds(1))
                if await pullBridgeStateIntoCache() {
                    deliverRecordingState()
                }
            }
        }
    }

    private func handleKeyboardSessionActivatedNotification() {
        Task { @MainActor in
            await pullBridgeStateIntoCache()
            onKeyboardSessionActivated?()
        }
    }

    private func handleKeyboardSessionExpiredNotification() {
        Task { @MainActor in
            await pullBridgeStateIntoCache()
            onKeyboardSessionExpired?()
        }
    }

    private func handleStartRecordingFromControlNotification() {
        Task { @MainActor in
            onStartRecordingFromControl?()
        }
    }

    private func handleTerminateSessionFromLiveActivityNotification() {
        Task { @MainActor in
            onTerminateSessionFromLiveActivity?()
        }
    }

    private func handleVivaModeChangedNotification() {
        // 桥模式：先把键盘经剪贴板送来的 selectedMode 落地到主 App 本地存储，
        // 再让业务回调读取——否则 reloadSelectedModeFromExtension 读到的还是旧模式。
        // （之前漏了这一行：键盘点 Default，主 App 的 selectedVivaModeKey 仍是旧值，
        //  听写处理继续用旧模式，这正是“键盘切了模式、后台还是日语翻译”的根因。）
        ingestBridgePayloads()
        Task { @MainActor in
            onVivaModeChanged?()
        }
    }

    // Text processing (keyboard rewrite)

    private func handleTextProcessingRequestedNotification() {
        ingestBridgePayloads()
        Task { @MainActor in
            onTextProcessingRequested?()
        }
    }

    private func handleTextProcessingCompletedNotification() {
        Task { @MainActor in
            await ingestBridgeResult(kind: .textResult, defaultsKey: UserDefaultsKeys.textProcessingResult, field: "text")
            // Only consume the result if a callback is set — prevents the main app
            // from racing with the keyboard extension and deleting the result first.
            guard let callback = onTextProcessingCompleted else { return }
            let text = getAndConsumeTextProcessingResult() ?? ""
            callback(text)
        }
    }

    private func handleTextProcessingErrorNotification() {
        Task { @MainActor in
            await ingestBridgeResult(kind: .textError, defaultsKey: UserDefaultsKeys.textProcessingErrorMessage, field: "message")
            guard let callback = onTextProcessingError else { return }
            let message = getAndConsumeTextProcessingError() ?? "Text processing failed"
            callback(message)
        }
    }
}
