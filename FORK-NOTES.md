# Fork notes

This repository is a **replica of [n0an/VivaDicta](https://github.com/n0an/VivaDicta)**,
kept at the upstream commit it was cloned from, plus one added feature.

- **Upstream**: https://github.com/n0an/VivaDicta (MIT, © Anton Novoselov)
- **Replica base**: `ac521eab3` ("Merge release/3.12.1", tag `v3.12.1`)
- **License**: unchanged — see [`LICENSE`](LICENSE). All upstream copyright and
  attribution stays as it is; this fork adds no restrictions.

## Added feature: "Let the Model Think" toggle

**Where**: Settings → AI Settings → *Let the Model Think*

**What it does**
- **Off (default, upstream behaviour)**: `ReasoningConfig` keeps asking reasoning
  models for the lowest thinking level their family allows (`none` / `minimal` /
  `low`, or `disable_reasoning` on Cerebras GLM). This is why dictation cleanup
  comes back fast.
- **On**: no reasoning parameter is sent at all, so each model falls back to
  whatever it ships with. Slower, and can be better on tricky text.

**Files touched**
- `Modules/AICore/Sources/AICore/ModelThinkingPreference.swift` *(new)* — the
  preference itself, stored in `UserDefaults.standard` under
  `isModelThinkingEnabled`.
- `Modules/AICore/Sources/AICore/ReasoningConfig.swift` — both
  `getReasoningParameter(for:thinkingEnabled:)` and
  `getExtraBodyParameters(for:thinkingEnabled:)` take the flag (defaulting to
  the stored preference) and return `nil` when thinking is enabled.
- `VivaDicta/Views/SettingsScreen/SettingsView.swift` — `@AppStorage` binding and
  the toggle row in the AI Settings section.
- `Modules/AICore/Tests/AICoreTests/ReasoningConfigTests.swift` — covers both
  branches.

**Scope**: the toggle only affects providers that take a reasoning/thinking
parameter (OpenAI-compatible incl. GPT-5/6, Gemini's `thinkingConfig`, Cerebras
`disable_reasoning`). On-device models (WhisperKit, MLX, Apple Foundation Models)
have no such knob and are unaffected.

---

## fork3（2026-10-20）：畅言桥（无 App Group 听写）+ 拼音九宫格 + 自签瘦身

**改名**（先行于 fork3）：主 App 与键盘显示名已改为「畅言」（commit dd0d039），
与自有 App 同名是用户确认的选择。

### 1. 畅言桥 LocalBridge（Modules/AppGroup）

免费签名签不到原 App Group，共享 UserDefaults 不存在，键盘听写的
「指令—状态—结果」全链断裂。借鉴畅言 iOS（同为无 App Group 自签）的做法，
只换 AppGroupCoordinator 的数据底盘，公开 API 与两端业务代码不动：

- 事件信号：Darwin 通知原样保留（系统级跨进程，不依赖 App Group）。
- 扩展→主 App 的文本载荷（文本处理输入、语音指令、剪贴板上下文、模式
  选择）：同步写命名剪贴板 `com.vivadicta.bridge`（JSON 包，写完再发通知，
  时序与原 defaults 写法一致）。
- 主 App→扩展的结果（转写文本、错误、文本处理结果）：同样走命名剪贴板，
  扩展在对应通知 handler 开头 `ingestBridgeResults()` 落地本地缓存。
- 状态与配置（录音状态、电平、会话、模式/预设/设置项）：主 App 内嵌
  BridgeStateServer（NWListener，只绑 127.0.0.1:47821，/vd/state、
  /vd/config），扩展在状态类通知 handler 里先拉快照刷新本地缓存；
  VivaModeManager.refreshVivaModes 也会拉一次 config。
- 桥的启停判定：iOS 且 `containerURL(forSecurityApplicationGroupIdentifier:)`
  为 nil 才启用（`LocalBridge.isEnabled`）；正版/App Store 环境完全走原路径，
  macOS 不启用。进程角色以 Info.plist 是否含 NSExtension 区分。
- 桥模式下 Coordinator 与 UserDefaultsStorage.shared 都改用各自进程的
  .standard（一份权威/一份缓存），键盘侧读取点统一走
  `AppGroupCoordinator.shared.clientDefaults`。

### 2. 拼音九宫格（VivaDictaKeyboard）

- 新增 `PinyinT9View.swift` + 从畅言 iOS 移植的 `PinyinData.swift`（约
  4500 字）与 `PinyinEngine.swift`（含 T9 解码：一字母一键等长、选字扣减、
  连续多音节、同编码按常用度排序）。
- `KeyboardDictationState.isPinyinMode`（默认开，持久化）：开时闲置页显示
  「工具栏 + T9 输入面」，关时显示原 KeyboardKit 键盘；工具栏新增
  「拼/英」切换钮，九宫格底行有「英」键。未改 KeyboardKit 的布局注入，
  英文 Shift 的动态行为不受影响。
- 退格长按连删（点按删一、按住 0.4s 后 60ms 连发），DragGesture 实现。

### 3. IPA 瘦身（.github/workflows/build-ipa.yml）

打包前剔除 PlugIns 里除 VivaDictaKeyboard.appex 外的全部扩展与
Watch 目录，产物只含主 App + 键盘（40MB），Sideloadly 免费 Apple ID
可直接签装。iCloud 同步/推送在自签下不可用，其余主 App 功能不变。

## fork4（2026-10-21）：界面中文化 + 思考开关修复

- 界面中文化：设置与主界面 650 条文案（1054 处替换，84 个文件）译为简体中文，品牌名 VivaDicta 一律改「畅言」；另把 23 条用户可见的错误/状态提示（API Key 无效、转写超时等，约 66 处）一并中文化。保留英文的只有：给 AI 模型看的内部描述、服务商名（OpenAI/Gemini 等）和格式占位串。
- 思考开关修复：「让模型思考」开关原来只对写死的模型名单发降档参数，deepseek/glm/kimi 等名单外模型什么都不发、开关关了也带着思考链慢慢想（用户实测反馈润色慢）。开关关闭时，对名单外的 deepseek/glm/kimi/moonshot 模型补发 thinking.type=disabled（OpenCode 网关上实测过：思考 token 219→0）。
- 本地模型（Parakeet/Whisper）下载：模型在 HuggingFace 上，国内网络直连不通且 hf-mirror 会把文件请求跳回主站，App 内下载注定失败；后续走「电脑下载模型包拷进 App Documents」方案，不在本版内。
