#!/bin/bash
# 编译并运行九宫格整句解码器的独立验收脚本（macOS，无需模拟器/Xcode 工程）
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$(mktemp -d)/verify_decoder"

xcrun swiftc -O -o "$OUT" \
  "$ROOT/VivaDictaKeyboard/PinyinData.swift" \
  "$ROOT/VivaDictaKeyboard/PinyinEngine.swift" \
  "$ROOT/VivaDictaKeyboard/PinyinLanguageModel.swift" \
  "$ROOT/VivaDictaKeyboard/PinyinSentenceDecoder.swift" \
  "$ROOT/scripts/pinyin/verify_decoder.swift"

"$OUT"
