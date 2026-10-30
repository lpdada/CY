#!/usr/bin/env python3
"""
生成 PinyinLanguageModel.swift（T9 整句解码器的语言模型数据表）。

用法（macOS / Linux 均可）：
    python3 -m venv .venv && .venv/bin/pip install jieba
    .venv/bin/python scripts/pinyin/build_language_model.py

输入：
  - VivaDictaKeyboard/PinyinData.swift   （词表：词 → 词频 rank）
  - jieba dict.txt                      （词/字真实频度，首次运行自动下载）
  - Tatoeba cmn_sentences.tsv.bz2       （中文句库，首次运行自动下载 ~1MB）

输出：
  - VivaDictaKeyboard/PinyinLanguageModel.swift  (~830KB)

表结构：
  charFreqRaw  单字频度（"字:频度"，空格分隔）
  wordFreqRaw  词/字频度（每行 "token<TAB>频度"，**行号即 bigram 的词 id**）
  bigramRaw    二元组（每行 "prevID<TAB>nextID<TAB>次数"，只保留 count>=2）

为什么单字也要进 wordFreqRaw：bigram 的前一个 token 常常是「我/你/在/的」这类单字，
它们不在 2–4 字的词表里。若只对词表建 id，绝大多数上下文会丢，二元模型形同虚设。
"""

import bz2
import math
import os
import re
import sys
import urllib.request
from collections import Counter

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
PINYIN_DATA = os.path.join(ROOT, "VivaDictaKeyboard", "PinyinData.swift")
OUTPUT = os.path.join(ROOT, "VivaDictaKeyboard", "PinyinLanguageModel.swift")
CACHE = os.path.join(ROOT, ".lm-cache")

JIEBA_DICT_URL = "https://raw.githubusercontent.com/fxsjy/jieba/master/jieba/dict.txt"
TATOEBA_URL = "https://downloads.tatoeba.org/exports/per_language/cmn/cmn_sentences.tsv.bz2"

# jieba dict.txt 的总词频（脚本会自行重算，这里只是注释用）
BIGRAM_MIN_COUNT = 2
CJK = re.compile(r"^[\u4e00-\u9fff]+$")


def download(url: str, path: str) -> str:
    if not os.path.exists(path):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        print(f"下载 {os.path.basename(path)} …")
        urllib.request.urlretrieve(url, path)
    return path


def load_pinyin_data():
    with open(PINYIN_DATA, encoding="utf-8") as f:
        src = f.read()

    dictionary_block = re.search(r"static let dictionary: \[String: String\] = \[(.*?)\n    \]", src, re.S)
    syllables = {}
    for line in dictionary_block.group(1).splitlines():
        m = re.match(r'\s*"([^"]+)": "([^"]*)",?', line)
        if m:
            syllables[m.group(1)] = m.group(2)

    word_block = re.search(r'static let wordTableRaw = """\n(.*?)\n"""', src, re.S)
    words = {}
    for line in word_block.group(1).splitlines():
        parts = line.split(" ")
        if len(parts) < 2:
            continue
        for token in parts[1:]:
            word, _, rank = token.partition(":")
            if word and rank.isdigit():
                rank = int(rank)
                if word not in words or rank < words[word]:
                    words[word] = rank
    return syllables, words


def load_frequencies(path):
    freq = {}
    with open(path, encoding="utf-8") as f:
        for line in f:
            parts = line.split()
            if len(parts) >= 2:
                try:
                    freq[parts[0]] = int(parts[1])
                except ValueError:
                    pass
    return freq


def rank_curve(freq, total):
    """rank → 频度的幂律拟合，用来给不在 jieba 词表里的词兜底（当前用不到，留作保险）。"""
    pool = [(w, f) for w, f in freq.items() if 2 <= len(w) <= 4 and CJK.match(w)]
    pool.sort(key=lambda kv: -kv[1])
    points = [(math.log(i + 1), math.log(f)) for i, (_, f) in enumerate(pool) if i + 1 > 500]
    mx = sum(x for x, _ in points) / len(points)
    my = sum(y for _, y in points) / len(points)
    slope = sum((x - mx) * (y - my) for x, y in points) / sum((x - mx) ** 2 for x, _ in points)
    intercept = my - slope * mx
    return lambda rank: max(20, int(math.exp(intercept) * rank ** slope))


def build_bigrams(sentences_path, vocab):
    """对句库分词，统计 (prev, next) 次数；只保留两端都在词表里的对。"""
    bigrams = Counter()
    contexts = Counter()
    total_sentences = 0

    with bz2.open(sentences_path, "rt", encoding="utf-8") as f:
        for line in f:
            fields = line.rstrip("\n").split("\t")
            if len(fields) < 3:
                continue
            text = fields[2]
            tokens = [t for t in jieba.lcut(text) if t.strip() and t in vocab]
            if len(tokens) < 2:
                continue
            total_sentences += 1
            for a, b in zip(tokens, tokens[1:]):
                bigrams[(a, b)] += 1
                contexts[a] += 1
    print(f"句库有效句子 {total_sentences}，原始二元组 {len(bigrams)}")
    return {pair: count for pair, count in bigrams.items() if count >= BIGRAM_MIN_COUNT}, contexts


def main():
    global jieba
    try:
        import jieba  # noqa: F401
    except ImportError:
        sys.exit("缺少 jieba：python3 -m venv .venv && .venv/bin/pip install jieba")

    syllables, words = load_pinyin_data()
    print(f"词表 {len(words)} 条，音节表 {len(syllables)} 条")

    freq = load_frequencies(download(JIEBA_DICT_URL, os.path.join(CACHE, "jieba_dict.txt")))
    total = sum(freq.values())
    estimate = rank_curve(freq, total)

    word_freq = {w: freq.get(w) or estimate(r) for w, r in words.items()}
    chars = {w: f for w, f in freq.items() if len(w) == 1 and CJK.match(w) and f > 0}
    for pool in syllables.values():
        for ch in pool:
            chars.setdefault(ch, 200)

    vocab = dict(word_freq)
    for ch, f in chars.items():
        vocab.setdefault(ch, f)

    sentences = download(TATOEBA_URL, os.path.join(CACHE, "cmn_sentences.tsv.bz2"))
    bigrams, _ = build_bigrams(sentences, vocab)

    ids = {token: i for i, token in enumerate(vocab)}
    pairs = sorted(
        ((ids[a], ids[b], c) for (a, b), c in bigrams.items()),
        key=lambda t: -t[2],
    )
    print(f"词表 {len(vocab)}（词 {len(word_freq)} + 字 {len(chars)}），二元组 {len(pairs)}")

    def write_block(handle, lines, per_line):
        for i in range(0, len(lines), per_line):
            handle.write("\n".join(lines[i:i + per_line]) + "\n")

    with open(OUTPUT, "w", encoding="utf-8") as f:
        f.write("//\n//  PinyinLanguageModel.swift\n//  VivaDictaKeyboard\n//\n")
        f.write("//  GENERATED by scripts/pinyin/build_language_model.py — do not edit by hand.\n")
        f.write("//  Sources: jieba dict.txt (word/char frequency), Tatoeba cmn (word bigram).\n//\n")
        f.write("import Foundation\n\n")
        f.write("/// Static language-model tables for the T9 sentence decoder.\n")
        f.write("/// `wordFreqRaw` lines are `word<TAB>frequency`; line order defines the word id\n")
        f.write("/// used by `bigramRaw`. `bigramRaw` lines are `prevID<TAB>nextID<TAB>count`.\n")
        f.write("enum PinyinLanguageModel {\n")
        f.write(f"    static let totalTokens: Double = {total}\n\n")

        f.write('    static let charFreqRaw = """\n')
        ordered = sorted(chars.items(), key=lambda kv: -kv[1])
        write_block(f, [f"{ch}:{n}" for ch, n in ordered], 10)
        f.write('"""\n\n')

        f.write('    static let wordFreqRaw = """\n')
        write_block(f, [f"{w}\t{n}" for w, n in vocab.items()], 1)
        f.write('"""\n\n')

        f.write('    static let bigramRaw = """\n')
        write_block(f, [f"{a}\t{b}\t{c}" for a, b, c in pairs], 8)
        f.write('"""\n}\n')

    print(f"已写入 {OUTPUT} ({os.path.getsize(OUTPUT) / 1024:.0f} KB)")


if __name__ == "__main__":
    main()
