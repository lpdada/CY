//
//  WordsDictionaryView.swift
//  VivaDicta
//
//  Created by Anton Novoselov on 2025.12.10
//

import SwiftUI
import AppGroup
import SwiftData

struct WordsDictionaryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \VocabularyWord.dateAdded, order: .reverse) private var words: [VocabularyWord]
    @State private var newWord: String = ""
    @State private var wordToEdit: VocabularyWord?

    @State private var editMode = false
    @State private var selectedWords: Set<PersistentIdentifier> = []
    @State private var showDeleteAlert = false

    @AppStorage(UserDefaultsStorage.Keys.isSpellingCorrectionsEnabled)
    private var isSpellingCorrectionsEnabled: Bool = true
    @AppStorage(UserDefaultsStorage.Keys.isParakeetVocabularyBoostingEnabled)
    private var isParakeetVocabularyBoostingEnabled: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            enableToggle
            parakeetVocabularyToggle

            if words.isEmpty {
                emptyStateView
            } else {
                if editMode {
                    editModeToolbar
                }
                wordsList
            }

            if !editMode {
                addWordBar
            }
        }
        .toolbar {
            if editMode {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        HapticManager.lightImpact()
                        selectedWords.removeAll()
                        editMode = false
                    }
                }
            } else {
                ToolbarItem(placement: .primaryAction) {
                    Button("编辑") {
                        HapticManager.lightImpact()
                        editMode = true
                    }
                    .disabled(words.isEmpty)
                }
            }
        }
        .navigationTitle("拼写纠正")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $wordToEdit) { item in
            EditVocabularySheet(word: item.word) { editedWord in
                var trimmed = editedWord.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.count > CustomVocabularyService.maxWordLength {
                    trimmed = String(trimmed.prefix(CustomVocabularyService.maxWordLength))
                }
                guard !trimmed.isEmpty else { return }
                item.word = trimmed
                wordToEdit = nil
            }
            .presentationDetents(.sizeToFit)
        }
        .alert("删除词语", isPresented: $showDeleteAlert) {
            Button("删除", role: .destructive) {
                deleteSelectedWords()
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text("确定要删除这 \(selectedWords.count) 个词语吗？此操作无法撤销。")
        }
    }

    private var enableToggle: some View {
        Toggle("启用拼写纠正", isOn: $isSpellingCorrectionsEnabled)
            .padding(.horizontal)
            .padding(.vertical, 8)
            .onChange(of: isSpellingCorrectionsEnabled) { _, isEnabled in
                if !isEnabled {
                    isParakeetVocabularyBoostingEnabled = false
                }
                HapticManager.selectionChanged()
            }
    }

    private var parakeetVocabularyToggle: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("配合 Parakeet 转写使用", isOn: $isParakeetVocabularyBoostingEnabled)
                .disabled(!isSpellingCorrectionsEnabled)
                .onChange(of: isParakeetVocabularyBoostingEnabled) { _, _ in
                    HapticManager.selectionChanged()
                }

            Text("实验功能。把这个列表里的词语用作本地 Parakeet 转写的自定义词汇。可能会下载额外的模型文件并占用更多内存。默认关闭。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    private var emptyStateView: some View {
        ContentUnavailableView {
            Label("没有词语", systemImage: "text.book.closed")
        } description: {
            Text("添加转写时应正确识别的词语")
        }
        .frame(maxHeight: .infinity)
    }

    private var editModeToolbar: some View {
        HStack {
            Button(allWordsSelected ? "Deselect All" : "Select All") {
                if allWordsSelected {
                    HapticManager.selectionChanged()
                    selectedWords.removeAll()
                } else {
                    HapticManager.selectionChanged()
                    selectedWords = Set(words.map(\.persistentModelID))
                }
            }

            Spacer()

            if !selectedWords.isEmpty {
                Button("删除", role: .destructive) {
                    HapticManager.warning()
                    showDeleteAlert = true
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var allWordsSelected: Bool {
        !words.isEmpty && selectedWords.count == words.count
    }

    private var wordsList: some View {
        List {
            ForEach(words) { word in
                Button {
                    if editMode {
                        toggleSelection(word)
                    } else {
                        wordToEdit = word
                    }
                } label: {
                    HStack {
                        if editMode {
                            Image(systemName: selectedWords.contains(word.persistentModelID) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selectedWords.contains(word.persistentModelID) ? .blue : .secondary)
                                .font(.title2)
                        }

                        Text(word.word)
                        Spacer()
                    }
                    .contentShape(.rect)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    if !editMode {
                        Button(role: .destructive) {
                            HapticManager.mediumImpact()
                            modelContext.delete(word)
                        } label: {
                            Label("删除", systemImage: "trash")
                        }

                        Button {
                            HapticManager.lightImpact()
                            wordToEdit = word
                        } label: {
                            Label("编辑", systemImage: "pencil")
                        }
                        .tint(.blue)
                    }
                }
            }
        }
        .listStyle(.plain)
    }

    private func toggleSelection(_ word: VocabularyWord) {
        HapticManager.selectionChanged()
        if selectedWords.contains(word.persistentModelID) {
            selectedWords.remove(word.persistentModelID)
        } else {
            selectedWords.insert(word.persistentModelID)
        }
    }

    private func deleteSelectedWords() {
        HapticManager.heavyImpact()
        for word in words where selectedWords.contains(word.persistentModelID) {
            modelContext.delete(word)
        }
        selectedWords.removeAll()

        if words.isEmpty {
            editMode = false
        }
    }

    private var addWordBar: some View {
        VStack(spacing: 4) {
            HStack {
                TextField("输入词语", text: $newWord)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .padding(8)
                    .background {
                        Capsule()
                            .stroke(.gray, lineWidth: 0.5)
                    }
                    .onSubmit {
                        addWord()
                    }
                    .onChange(of: newWord) { _, newValue in
                        if newValue.count > CustomVocabularyService.maxWordLength {
                            newWord = String(newValue.prefix(CustomVocabularyService.maxWordLength))
                        }
                    }

                Button("添加", action: addWord)
                    .buttonStyle(.borderedProminent)
                    .disabled(newWord.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if newWord.count > 0 {
                HStack {
                    Spacer()
                    Text("\(newWord.count)/\(CustomVocabularyService.maxWordLength)")
                        .font(.caption)
                        .foregroundStyle(newWord.count >= CustomVocabularyService.maxWordLength ? .orange : .secondary)
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private func addWord() {
        var trimmed = newWord.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if trimmed.count > CustomVocabularyService.maxWordLength {
            trimmed = String(trimmed.prefix(CustomVocabularyService.maxWordLength))
        }

        // Check for duplicates (case-insensitive)
        let isDuplicate = words.contains { $0.word.lowercased() == trimmed.lowercased() }
        guard !isDuplicate else { return }

        HapticManager.mediumImpact()
        let vocabWord = VocabularyWord(word: trimmed)
        modelContext.insert(vocabWord)
        newWord = ""
    }
}

// MARK: - Edit Vocabulary Word Sheet

private struct EditVocabularySheet: View {
    let word: String
    let onSave: (String) -> Void

    @State private var editedText: String
    @FocusState private var isTextFieldFocused: Bool

    init(word: String, onSave: @escaping (String) -> Void) {
        self.word = word
        self.onSave = onSave
        self._editedText = State(initialValue: word)
    }

    private var hasChanges: Bool {
        editedText.trimmingCharacters(in: .whitespacesAndNewlines) != word &&
        !editedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("编辑词语")
                .font(.headline)

            VStack(alignment: .trailing, spacing: 4) {
                TextField("词语", text: $editedText)
                    .focused($isTextFieldFocused)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .padding(12)
                    .background(Color(.systemGray5))
                    .clipShape(.rect(cornerRadius: 10))
                    .onChange(of: editedText) { _, newValue in
                        if newValue.count > CustomVocabularyService.maxWordLength {
                            editedText = String(newValue.prefix(CustomVocabularyService.maxWordLength))
                        }
                    }

                Text("\(editedText.count)/\(CustomVocabularyService.maxWordLength)")
                    .font(.caption)
                    .foregroundStyle(editedText.count >= CustomVocabularyService.maxWordLength ? .orange : .secondary)
            }

            Button("保存修改") {
                HapticManager.mediumImpact()
                onSave(editedText)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(hasChanges ? Color.blue : Color(.systemGray4))
            .foregroundStyle(hasChanges ? .white : .secondary)
            .clipShape(.rect(cornerRadius: 10))
            .disabled(!hasChanges)
        }
        .padding()
        .presentationDragIndicator(.hidden)
        .onAppear {
            isTextFieldFocused = true
        }
    }
}

#Preview {
    NavigationStack {
        WordsDictionaryView()
    }
}
