//
//  ReplacementsView.swift
//  VivaDicta
//
//  Created by Anton Novoselov on 2025.12.10
//

import SwiftUI
import AppGroup
import SwiftData

struct ReplacementsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \WordReplacement.dateAdded, order: .reverse) private var replacements: [WordReplacement]
    @State private var originalText: String = ""
    @State private var replacementText: String = ""
    @State private var replacementToEdit: WordReplacement?

    @State private var editMode = false
    @State private var selectedReplacements: Set<PersistentIdentifier> = []
    @State private var showDeleteAlert = false

    @AppStorage(UserDefaultsStorage.Keys.isReplacementsEnabled)
    private var isReplacementsEnabled: Bool = true

    var body: some View {
        VStack(spacing: 0) {
            enableToggle

            if replacements.isEmpty {
                emptyStateView
            } else {
                if editMode {
                    editModeToolbar
                }
                replacementsList
            }

            if !editMode {
                addReplacementBar
            }
        }
        .toolbar {
            if editMode {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        HapticManager.lightImpact()
                        selectedReplacements.removeAll()
                        editMode = false
                    }
                }
            } else {
                ToolbarItem(placement: .primaryAction) {
                    Button("编辑") {
                        HapticManager.lightImpact()
                        editMode = true
                    }
                    .disabled(replacements.isEmpty)
                }
            }
        }
        .navigationTitle("词语替换")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $replacementToEdit) { item in
            EditReplacementSheet(
                originalText: item.originalText,
                replacementText: item.replacementText
            ) { newOriginal, newReplacement in
                var trimmedOriginal = newOriginal.trimmingCharacters(in: .whitespacesAndNewlines)
                var trimmedReplacement = newReplacement.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmedOriginal.count > ReplacementsService.maxTextLength {
                    trimmedOriginal = String(trimmedOriginal.prefix(ReplacementsService.maxTextLength))
                }
                if trimmedReplacement.count > ReplacementsService.maxTextLength {
                    trimmedReplacement = String(trimmedReplacement.prefix(ReplacementsService.maxTextLength))
                }
                guard !trimmedOriginal.isEmpty, !trimmedReplacement.isEmpty else { return }
                item.originalText = trimmedOriginal
                item.replacementText = trimmedReplacement
                replacementToEdit = nil
            }
            .presentationDetents(.sizeToFit)
        }
        .alert("删除替换规则", isPresented: $showDeleteAlert) {
            Button("删除", role: .destructive) {
                deleteSelectedReplacements()
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text("确定要删除这 \(selectedReplacements.count) 条替换规则吗？此操作无法撤销。")
        }
    }

    private var enableToggle: some View {
        Toggle("启用替换规则", isOn: $isReplacementsEnabled)
            .padding(.horizontal)
            .padding(.vertical, 8)
            .onChange(of: isReplacementsEnabled) { _, _ in
                HapticManager.selectionChanged()
            }
    }

    private var emptyStateView: some View {
        ContentUnavailableView {
            Label("没有替换规则", systemImage: "arrow.left.arrow.right")
        } description: {
            VStack(alignment: .leading, spacing: 8) {
                Text("添加在转写时应用的文本替换规则")
                Text("""
                    For example:
                        "My website link" -> "https://vivadicta.com"
                        "Vivo dicte" -> "Changyan"
                    """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.leading)
        }
        .frame(maxHeight: .infinity)
    }

    private var editModeToolbar: some View {
        HStack {
            Button(allReplacementsSelected ? "Deselect All" : "Select All") {
                if allReplacementsSelected {
                    HapticManager.selectionChanged()
                    selectedReplacements.removeAll()
                } else {
                    HapticManager.selectionChanged()
                    selectedReplacements = Set(replacements.map(\.persistentModelID))
                }
            }

            Spacer()

            if !selectedReplacements.isEmpty {
                Button("删除", role: .destructive) {
                    HapticManager.warning()
                    showDeleteAlert = true
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var allReplacementsSelected: Bool {
        !replacements.isEmpty &&
        selectedReplacements.count == replacements.count
    }

    private var replacementsList: some View {
        List {
            ForEach(replacements) { replacement in
                Button {
                    if editMode {
                        toggleSelection(replacement)
                    } else {
                        replacementToEdit = replacement
                    }
                } label: {
                    HStack {
                        if editMode {
                            Image(systemName: selectedReplacements.contains(replacement.persistentModelID) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selectedReplacements.contains(replacement.persistentModelID) ? .blue : .secondary)
                                .font(.title2)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text(replacement.originalText)
                                .font(.body)
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.right")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(replacement.replacementText)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                    }
                    .contentShape(.rect)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    if !editMode {
                        Button(role: .destructive) {
                            HapticManager.mediumImpact()
                            modelContext.delete(replacement)
                        } label: {
                            Label("删除", systemImage: "trash")
                        }

                        Button {
                            HapticManager.lightImpact()
                            replacementToEdit = replacement
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

    private func toggleSelection(_ replacement: WordReplacement) {
        HapticManager.selectionChanged()
        if selectedReplacements.contains(replacement.persistentModelID) {
            selectedReplacements.remove(replacement.persistentModelID)
        } else {
            selectedReplacements.insert(replacement.persistentModelID)
        }
    }

    private func deleteSelectedReplacements() {
        HapticManager.heavyImpact()
        for replacement in replacements where selectedReplacements.contains(replacement.persistentModelID) {
            modelContext.delete(replacement)
        }
        selectedReplacements.removeAll()

        if replacements.isEmpty {
            editMode = false
        }
    }

    private var addReplacementBar: some View {
        VStack(spacing: 8) {
            VStack(spacing: 4) {
                TextField("原始文本", text: $originalText)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .padding(8)
                    .background {
                        Capsule()
                            .stroke(.gray, lineWidth: 0.5)
                    }
                    .onChange(of: originalText) { _, newValue in
                        if newValue.count > ReplacementsService.maxTextLength {
                            originalText = String(newValue.prefix(ReplacementsService.maxTextLength))
                        }
                    }

                if originalText.count > 0 {
                    HStack {
                        Spacer()
                        Text("\(originalText.count)/\(ReplacementsService.maxTextLength)")
                            .font(.caption)
                            .foregroundStyle(originalText.count >= ReplacementsService.maxTextLength ? .orange : .secondary)
                    }
                }
            }

            VStack(spacing: 4) {
                TextField("替换为", text: $replacementText)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .padding(8)
                    .background {
                        Capsule()
                            .stroke(.gray, lineWidth: 0.5)
                    }
                    .onSubmit {
                        addReplacement()
                    }
                    .onChange(of: replacementText) { _, newValue in
                        if newValue.count > ReplacementsService.maxTextLength {
                            replacementText = String(newValue.prefix(ReplacementsService.maxTextLength))
                        }
                    }

                if replacementText.count > 0 {
                    HStack {
                        Spacer()
                        Text("\(replacementText.count)/\(ReplacementsService.maxTextLength)")
                            .font(.caption)
                            .foregroundStyle(replacementText.count >= ReplacementsService.maxTextLength ? .orange : .secondary)
                    }
                }
            }

            Button("添加替换规则", action: addReplacement)
                .buttonStyle(.borderedProminent)
                .disabled(!canAddReplacement)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var canAddReplacement: Bool {
        !originalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !replacementText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func addReplacement() {
        var trimmedOriginal = originalText.trimmingCharacters(in: .whitespacesAndNewlines)
        var trimmedReplacement = replacementText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedOriginal.isEmpty, !trimmedReplacement.isEmpty else { return }

        if trimmedOriginal.count > ReplacementsService.maxTextLength {
            trimmedOriginal = String(trimmedOriginal.prefix(ReplacementsService.maxTextLength))
        }
        if trimmedReplacement.count > ReplacementsService.maxTextLength {
            trimmedReplacement = String(trimmedReplacement.prefix(ReplacementsService.maxTextLength))
        }

        // Check for duplicate original (case-insensitive)
        let isDuplicate = replacements.contains {
            $0.originalText.lowercased() == trimmedOriginal.lowercased()
        }
        guard !isDuplicate else { return }

        HapticManager.mediumImpact()
        let wordReplacement = WordReplacement(
            originalText: trimmedOriginal,
            replacementText: trimmedReplacement
        )
        modelContext.insert(wordReplacement)
        originalText = ""
        replacementText = ""
    }
}

// MARK: - Edit Replacement Sheet

private struct EditReplacementSheet: View {
    let originalText: String
    let replacementText: String
    let onSave: (String, String) -> Void

    @State private var editedOriginal: String
    @State private var editedReplacement: String
    @FocusState private var focusedField: Field?

    enum Field {
        case original, replacement
    }

    init(originalText: String, replacementText: String, onSave: @escaping (String, String) -> Void) {
        self.originalText = originalText
        self.replacementText = replacementText
        self.onSave = onSave
        self._editedOriginal = State(initialValue: originalText)
        self._editedReplacement = State(initialValue: replacementText)
    }

    private var hasChanges: Bool {
        let trimmedOriginal = editedOriginal.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedReplacement = editedReplacement.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmedOriginal.isEmpty &&
               !trimmedReplacement.isEmpty &&
               (trimmedOriginal != originalText || trimmedReplacement != replacementText)
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("编辑替换规则")
                .font(.headline)

            VStack(alignment: .trailing, spacing: 4) {
                TextField("原始文本", text: $editedOriginal)
                    .focused($focusedField, equals: .original)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .padding(12)
                    .background(Color(.systemGray5), in: .rect(cornerRadius: 10))
                    .onChange(of: editedOriginal) { _, newValue in
                        if newValue.count > ReplacementsService.maxTextLength {
                            editedOriginal = String(newValue.prefix(ReplacementsService.maxTextLength))
                        }
                    }

                Text("\(editedOriginal.count)/\(ReplacementsService.maxTextLength)")
                    .font(.caption)
                    .foregroundStyle(editedOriginal.count >= ReplacementsService.maxTextLength ? .orange : .secondary)
            }

            VStack(alignment: .trailing, spacing: 4) {
                TextField("替换为", text: $editedReplacement)
                    .focused($focusedField, equals: .replacement)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .padding(12)
                    .background(Color(.systemGray5))
                    .clipShape(.rect(cornerRadius: 10))
                    .onChange(of: editedReplacement) { _, newValue in
                        if newValue.count > ReplacementsService.maxTextLength {
                            editedReplacement = String(newValue.prefix(ReplacementsService.maxTextLength))
                        }
                    }

                Text("\(editedReplacement.count)/\(ReplacementsService.maxTextLength)")
                    .font(.caption)
                    .foregroundStyle(editedReplacement.count >= ReplacementsService.maxTextLength ? .orange : .secondary)
            }

            Button("保存修改") {
                HapticManager.mediumImpact()
                onSave(editedOriginal, editedReplacement)
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
            focusedField = .original
        }
    }
}

#Preview {
    NavigationStack {
        ReplacementsView()
    }
}
