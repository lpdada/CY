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
