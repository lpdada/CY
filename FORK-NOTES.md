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

## fork5（2026-10-21）：修听写不回插——结果回传改走本地 HTTP

- 用户实测：微信里点键盘话筒听写，主 App 里有转写记录，但宿主输入框里没字、也不报错。
- 根因：桥的结果回传靠命名剪贴板（com.vivadicta.bridge），在 iOS 27 免费自签环境下跨进程读不到——主 App 写得到、键盘永远读到空，于是键盘拿到空文本后静默放弃插入。与畅言 iOS v1.3.4 修的是同一类问题。
- 附带发现：主 App 在 VivaDictaApp.swift 里给 onTranscriptionCompleted 设了回调（更新 Live Activity），它收到自己的完成通知后会抢先 getAndConsume 把本地存储里的结果删掉；所以新通道不能现读存储里的结果键，必须独立暂存。
- 修法：BridgeStateServer 新增结果槽（按 kind 覆盖最新一份、带完成时刻、从不被消费删除）+ GET /vd/result?kind= 端点；四个 share 点（转写文本/文本处理结果/两类错误）在发通知前同步 stash 一份；键盘侧新增 ingestBridgeResult(kind:)——先试剪贴板，没货经 HTTP 拉槽，按完成时刻与本地消费水位（vdBridgeConsumedAt.<kind>）去重后落地，再走原有 getAndConsume 与回调。转写与文本处理两条链都覆盖。

## fork6（2026-10-21）：九宫格 v6 界面 + 连续输入 + 候选换页

- 界面（按用户确认的 v6 样板）：4 列键阵取代 3 列；玻璃质感键面（浅顶深底
  渐变 + 顶部高光 + 圆角 10pt，键高 56pt）；右列功能键加宽，双行高发送键
  （紫→青斜向渐变 + 发光，箭头 +“发送”）；底行左为“英文”键（点按切回
  英文键盘）、中间为全圆角胶囊空格；候选栏不再放静态“拼音”二字，
  只在输入时显示数字串；回车并入双行发送键。
- 连续输入修复：旧逻辑拿整串数字精确匹配单音节编码，连续输多音节
  （如“你好”=64426）时整串匹配不到任何单音节、候选栏空了，看起来
  就是“变成数字”。新增 `PinyinEngine.t9FirstCode` 贪心最长匹配切首段，
  选字后扣首段、剩余部分下次重切，自动成为下一音节；逐个音节选字
  一定准，整词连输时个别歧义（如西安/先）以最长匹配为准。
- 候选换页：候选字每页 6 个，候选栏加“换页”按钮（末页变“首页”点回
  第一页）；换数字串、切音节、选字后自动回第一页。
- 附带：^^ 键切符号页（9 个常用标点：，。？、；：（）！，删除键两页
  都在，再点 ABC 回字母页）；工具条的拼音/英文切换键只在英文模式下
  显示“拼”（拼音模式下藏起，因九宫格左下角已有英文键；英文模式下
  保留，否则切过去回不来）。

## fork7（2026-10-21）：九宫格四点修复——等宽列、工具条均分、收起空候选栏、整词候选

- 4 列等宽：右列不再加宽，4 列宽度完全一致（发送键仍双行高 + 渐变，
  只是宽度跟其他键一样）。
- 工具条平均分配：顶部图标各占等宽一段、居中放（拼音模式 3 段：
  ✨/模式/话筒；英文模式 4 段，多一个“拼”）。
- 空隙：空闲时候选栏收起（原来空栏也占 38pt 高，就是工具条与按键
  间那段空白）；连带修真 bug：页码改显式复位（只靠 onChange 时，
  栏消失那次变化未必触发，下次输入会停在旧页而不是回第 1 页）。
- 连续打字：用真实字库验算确认切分逻辑本身没问题（64426 → 64 +
  426），真正缺的是整词候选。新增：多段时首位出整词（每段首选字
  拼成，如 ni+hao → 你好），点词一次上屏整词；空格/发送有整词时
  直接上整词；单字流程不变，逐个音节选字本来就是通的。

## fork8（2026-10-21）：九宫格真输入法化——词库 + 全部切分 + marked text

- 词库：jieba 词频 + pypinyin 生成 3 万词（2–4 字，24660 个拼音 key），
  并进已有的 PinyinData.swift（不新增文件，不改 Xcode 工程）；词按全局
  词频排序，多词候选排在单字前面。fork7 只有一个运行时拼出来的词，
  没有真词库、多词候选和组字串，这版补齐。
- 切分：数字串 DFS 枚举全部切分（不再是贪心首段），9426 能同时走出
  xian、xi+an、yi+an 等，词库 key 真前缀剪枝，节点数在百以内。
- marked text：首选候选同步为文档里的组字串，宿主像真输入法一样
  显示正在组字的词；不支持的宿主忽略它，选字流程不受影响。点词
  一次上屏并清空整串；单字仍可逐个音节选。
- 备注：词频是静态语料，暂无用户输入学习；仓库私有，直链未登录时
  404 属正常，登录 GitHub 后可下。

## fork9（2026-10-21）：修键盘模式不同步——键盘点的模式主 App 跟不上

- 现象：主 App 选了日语翻译后，键盘上点 Default，处理出来还是日语翻译。
- 根因：桥里 selectedMode 通道本身是通的（键盘点模式 → 剪贴板载荷 +
  vivaModeChanged 通知），但主 App 的 handleVivaModeChangedNotification
  漏了 ingestBridgePayloads() 这一行——它是全文件唯一没在 handler 开头
  ingest 的模式相关 handler。于是主 App 的 selectedVivaModeKey 还是旧值，
  reloadSelectedModeFromExtension 读到的还是日语翻译，听写继续按旧模式跑。
- 修复：该 handler 开头补 ingestBridgePayloads()，与文本处理 handler 同款
  写法；桥模式外 / 键盘进程内 ingest 自带 guard，是 no-op。反向（主 App →
  键盘）本来就是通的：config 快照 stringKeys 里有 selectedVivaModeKey，
  键盘 start 时会拉取。

## fork10（2026-10-21）：图标换成电脑版畅言图标

- 来源：电脑版畅言 v0.1.8 图标（声波汇成钢笔尖，深蓝紫底），与 iOS
  畅言 v1.2.1 同图；CI 打 Release 用的正是 AppIcon3.icon。
- 改动：AppIcon3 图层 gpt1.png 换成电脑版图标（1024×1024），并把
  图层原下移 28.265625pt 的偏移归零（旧图是微调过位置的老 artwork，
  新图满幅设计，留偏移会被往下推）；App 内三处用的 VivaDictaIcon
  imageset（开屏/新功能/键盘返回提示）按 341/682/1024 重切了一套。
  Debug 的 AppIcon5 未动。

## fork11（2026-10-21）：图标换成白底重设计版

- 接 fork10 的深色电脑版图标：用户要求白底、不要暗色，遂在电脑版
  图标（声波汇成钢笔尖）基础上重设计一版：纯白底、青蓝渐变声波、
  银色钢笔尖带金边点缀、浅金与亮青星芒，构图不变。
- 改动：AppIcon3 图层 gpt1.png 与 VivaDictaIcon imageset 三档
  （341/682/1024）全部换成白底版；图层偏移 fork10 已归零，本次不动。

## fork12（2026-10-21）：IPA 文件名与界面文案改名

- IPA 文件名：workflow 打包改成 `changyan-unsigned.ipa`（产物名同步
  改）；附带修了打包后 `ls` 那行漏改的旧文件名（否则 CI 会在这步失败）。
- 界面文案（28 文件、纯改名，无逻辑改动）：快捷指令描述、开屏键盘
  开关（改成“畅言”，与设置里实际键盘名一致）、设置里“畅言的 Mac”、
  邮件主题与版本页脚、导出文件名、键盘报错、新功能页全文。
- 刻意未动：Bundle ID / App Group / iCloud 容器、桥通知名与剪贴板名、
  内部代码符号（VivaMode 等）、图标资源名、上游署名链接（n0an/VivaDicta）。
- 另：fork11 的 release 资产已直接改名重挂为 changyan-unsigned.ipa
  （同字节，无需重编），不在本次提交内。

## fork13（2026-10-21）：图标换成白底 v2 对比度优化版

- 接 fork11 的 v1 白底版：用户反馈图形颜色太浅、跟白底太近看不清，
  遂优化一版：白底与构图不变，声波加深为宝蓝→深青渐变、笔尖描边
  与墨孔加深、星芒更饱和，对比度明显上来。
- 改动：AppIcon3 图层 gpt1.png 与 VivaDictaIcon imageset 三档
  （341/682/1024）全部换成 v2；图层偏移已是 0，本次不动。

## fork14（2026-10-22）：键盘与主 App 模式双向同步

- 根因：键盘听写的 AI 处理在主 App，用主 App 的模式；键盘药丸改模式
  只写键盘本地 + 发剪贴板消息 + 系统通知，而命名剪贴板在自签 iOS 27
  环境跨进程读不到（fork5 已证实），主 App 收不到，继续用旧模式处理。
  fork9 只补了主 App handler 的 ingest，但 ingest 的源头本身是断的。
  反向也不完整：主 App 改模式只写自己本地、不通知键盘；键盘只在
  viewDidLoad 拉一次配置，会话内 stale。
- 键盘→后台走 HTTP：桥服务新增 POST /vd/mode；键盘药丸三个入口改走
  userDidSelectMode，除原有通知外再经 HTTP 把模式推给主 App；主 App
  接到后写本地键，再走已有 Darwin 链（handler→reload→selectedMode→
  onModeChange→handleModeChange→transcriptionManager），UI 与处理模式全跟上。
- 后台→键盘每次出现同步：键盘 viewWillAppear 时 refreshVivaModes，
  主 App 里改了模式，下次切到键盘药丸就是新的。刻意没接键盘侧 Darwin
  回调，避免自通知把刚点的模式又拉回旧值。
- 边界：主 App 没运行时键盘的推送会失败丢弃，主 App 随后仍显示自己的
  旧模式，直到下次键盘切模式再推。

## fork15（2026-10-22）：候选区置顶置换 + 左上 123 数字键盘

- 候选区置顶置换（2026-10-22 样板定稿）：PinyinT9View 改泛型，
  工具条由调用方作为中间段传入；顺序自上而下为候选区（永久置顶，
  两行：上行数字串 + 同码音节、下行候选字 + 换页，空闲时两行空白
  占位）→ 工具条（✨/模式药丸/话筒，紧贴按键）→ 按键。键盘总高度
  全程不变，首按键跳动与候选栏截断重叠两处问题一并解决；只影响
  九宫格分支，英文键盘不动。
- 左上 123 数字键盘：原 ，。？! 键只输 ，、键面却印四个符号，且
  ，。？ 在 ^^ 符号页里已有，两处标点重合，故换成 123。点 123 切
  数字页（与符号页同机制，互斥）：1–9、0 直接上屏数字本身，底行
  0 + 空格，第二行末尾 ABC 回字母页；进数字页前先把未完成组字上
  屏。标点统一收进 ^^ 符号页；快速 ，从一键变两键（^^ 再点 ，）。

## fork16（2026-10-22）：Whisper 模型导入按钮

- 模型卡片新增“导入”按钮（仅 Whisper、仅未下载状态）：点开系统文件
  选择器选模型文件夹，App 把它拷进 Documents 下 WhisperKit 期望的
  模型目录，拷完卡片直接变“已下载”，不再走网络下载。解决国内
  直连 HuggingFace 下不了模型的问题：电脑下好模型文件夹，经
  AirDrop / 网盘 / 微信（zip + 解压）弄到手机 Files 里，再点导入。
- 实现：ModelDownloadManager 新增 importWhisperKitModel（后台拷贝约
  600MB 不卡界面，空文件夹报错，已有目录先删后拷）；LocalModelCard
  加导入按钮、文件夹选择器与失败提示；ModelDownloadError 新增
  importFailed。导入只管放文件，不跑预热，第一次转写时预热。
- 未动：Parakeet 不加导入；下载、删除、预热逻辑不动；不改 Bundle ID
  与 App Group 等。

## fork17（2026-10-22）：自建服务器转写通道（SenseVoice + Qwen3-ASR）

- 新增 provider 自建服务器：模型目录出现两个新模型，SenseVoice
  Small（自建）与 Qwen3-ASR 0.6B（自建），转写走新加坡服务器
  https://asr.ysloving.com/v1/transcribe，不在手机上下载模型。
- 实现：CloudTranscription 模块新增 SelfHostedTranscriptionService
  （multipart 上传，form 字段 model + audio，Bearer 鉴权，超时 300
  秒对齐服务器端 nginx，401 映射为 key 无效）；TranscriptionKit
  的 TranscriptionProvider 与 DefaultTranscriptionEngine 各加
  selfHosted 一路；TranscriptionManager 的 makeProvider 加一路。
  目录、模式编辑的 provider 列表、卡片配置态都自动跟上。
- 配置：设置页自建服务器分支填服务器地址（默认
  asr.ysloving.com）+ API key；地址存 UserDefaults，key 存钥匙串
  （与云厂商的 mappedAIProvider 路径平行，不动 AIProvider 枚举）。
  保存后跑公开健康检查验证服务器可达，key 有效性在首次转写时见
  分晓。删除 key 只清 key 不动地址。
- SenseVoice 日语输出带词间空格（“抜群 の 運動 神経 …”），服务层
  在文本含假名时去掉全部空格；中文无此空格、英文需要空格，不受
  影响。Qwen3-ASR 输出无此问题。
- 未动：Whisper / Parakeet / 各云厂商路径不动；不改 Bundle ID 与
  App Group 等；1.7B 官方暂无 int8 包，本版不上。

## fork18（2026-10-22）：修模式编辑页自建服务器 key 判定

- 现象：模型卡片上自建模型的钥匙已是绿色（已配置），但模式编辑
  页选自建服务器仍提示要添加 API key，且没有入口可点，卡住。
- 根因：两处走了不同的 key 路径。模型卡片读 CloudModel.apiKey
  （fork17 已扩展到自建钥匙串），模式编辑页的
  isTranscriptionProviderConfigured 却直接读 mappedAIProvider，
  自建没有映射厂商，恒返回未配置；“添加 API Key”入口同样只认
  mappedAIProvider，自建下根本不渲染。
- 修：isTranscriptionProviderConfigured 加 selfHosted 分支，直接读
  自建钥匙串；模式编辑页未配置链上加自建分支，点“配置自建服务
  器”进自建配置页（地址 + key）；未配置提示文案改中文。
- 未动：转写通道、模型目录、钥匙串与地址存储均不动。

## fork19（2026-10-22）：自建服务器模型目录加 3 个

- 新增：Paraformer 中文、FireRedASR2、Whisper Turbo 三个自建
  模型条目（CloudModel，provider 自建），名字与服务器 /health
  一致：paraformer-zh、fire-red-asr2-ctc、whisper-turbo，发送时
  原样作 model 字段；地址、key、钥匙串走 fork17 的自建一路，
  不用每个模型单独配。
- 服务器侧已先行：Hermes 部署完成并公网实测（10 秒中文 2 线
  程热/冷：paraformer 0.51/1.99 秒最快无标点、fire-red
  3.67/5.50 秒、whisper-turbo 9.72/11.67 秒约 1 倍实时）。
- 注意包身份陷阱（说明文档曾写错，Hermes 实测纠正）：
  SenseVoice 2025-09-09 int8 是粤语微调、Paraformer
  2025-10-07 int8 是川渝方言微调，均不上；本版 sensevoice
  仍用 2024-07-17 包，paraformer 用通用包 2023-03-28。
  粤语包用户明确不要，不开 sensevoice-yue。
- 未动：转写通道、钥匙串、地址存储、fork18 的模式编辑修复
  均不动；本地 Whisper / Parakeet 路径不动。

## fork20（2026-10-23）：自建服务器模型目录加 4 个

- 新增：FunASR Nano、X-ASR 中英、Whisper Large V3、Paraformer
  中文 2024 四个自建模型条目（CloudModel，provider 自建），
  名字与服务器 /health 一致：funasr-nano、x-asr-punct、
  whisper-large-v3、paraformer-zh-2024，发送时原样作 model
  字段；地址、key 走 fork17 的自建一路。
- 服务器侧已先行：Hermes 第二批部署完成并同段音频对比
  （10 秒中英混说热：x-asr-punct 0.55 秒、paraformer-2024
  0.51 秒、funasr-nano 2.64 秒、large-v3 23.69 秒约 2.4 倍实时）。
- 注意：x-asr-punct 中英专用，不支持日语（日语输出罗马字
  乱码），描述里已标注；funasr-nano 混说英文全大写粘连、
  首次加载慢（冷 17.8 秒）；paraformer-2024 与 2023 版输出
  一致，属重复条目，用户坚持全加；large-v3 云端比 Turbo
  慢且同丢字，仅作备选。
- 未动：转写通道、钥匙串、地址存储、模式编辑修复均不动；
  本地 Whisper / Parakeet 路径不动。

## fork21（2026-10-23）：新增自建句子级翻译

- 新增：主界面工具栏“自建翻译”入口（translate 图标），进双语
  会话页：源语言/目标语言（中/日/英）、自建转写模型、朗读开关；
  说话时按静音自动分句，每句依次走自建 ASR 转写、AI 翻译，
  原文 + 译文对照滚动显示，可选系统语音朗读译文。
- 实现：复用 StreamingAudioCapture 的 16kHz PCM 流；新
  SentenceAudioChunker 按能量静音分句（0.9 秒静音成句、
  最长 30 秒强制成句），句音频写临时 WAV 走
  SelfHostedTranscriptionService；翻译走 AIService
  generateVariation（自建翻译 preset，复用当前模式的 AI
  服务商，不新增 key）；朗读走 AVSpeechSynthesizer 系统声音。
- 关键设计：分句任务只做同步计算不碰网络，处理任务串行
  消费成句队列——处理跟不上时只表现为延迟变大，不丢音频
  （capture 流本身只有约 1 秒缓冲，直接串行会丢尾巴）。
  单句失败不中断会话（转写失败记状态行，翻译失败挂在该句）。
- 范围：仅主 App，会话不存档；不支持键盘扩展；各模型本身
  的语言限制（如 x-asr-punct 不支持日语）以模型描述为准。
- 未动：Soniox 实时翻译、转写通道、模型目录、钥匙串均不动。
