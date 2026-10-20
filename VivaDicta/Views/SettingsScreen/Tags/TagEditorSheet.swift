//
//  TagEditorSheet.swift
//  VivaDicta
//
//  Created by Anton Novoselov on 2026.03.23
//

import SwiftUI

struct TagEditorSheet: View {
    /// The values the sheet hands back on save.
    struct Draft {
        var name: String
        var colorHex: String
        var icon: String
        var isExcludedFromAutoDelete: Bool
    }

    enum Mode {
        case create
        case edit(TranscriptionTag)

        var title: String {
            switch self {
            case .create: "New Tag"
            case .edit: "Edit Tag"
            }
        }
    }

    let mode: Mode
    let onSave: (Draft) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var selectedColorHex: String
    @State private var selectedIcon: String
    @State private var customColor: Color = .blue
    @State private var useCustomColor = false
    @State private var isExcludedFromAutoDelete: Bool
    @FocusState private var isNameFocused: Bool

    private static let colorPalette: [(name: String, hex: String)] = [
        ("Blue", "#007AFF"),
        ("Purple", "#AF52DE"),
        ("Pink", "#FF2D55"),
        ("Red", "#FF3B30"),
        ("Orange", "#FF9500"),
        ("Yellow", "#FFCC00"),
        ("Green", "#34C759"),
        ("Teal", "#5AC8FA"),
        ("Indigo", "#5856D6"),
        ("Gray", "#8E8E93"),
    ]

    private static let iconOptions: [String] = [
        "tag", "folder", "star", "heart", "bookmark",
        "flag", "bolt", "briefcase", "person", "building.2",
        "house", "airplane", "car", "phone", "envelope",
        "doc.text", "book", "graduationcap", "music.note", "camera",
        "mic", "brain.head.profile", "lightbulb", "wrench.and.screwdriver", "chart.bar",
    ]

    init(mode: Mode, onSave: @escaping (Draft) -> Void) {
        self.mode = mode
        self.onSave = onSave
        switch mode {
        case .create:
            _name = State(initialValue: "")
            _selectedColorHex = State(initialValue: "#007AFF")
            _selectedIcon = State(initialValue: "tag")
            _isExcludedFromAutoDelete = State(initialValue: false)
        case .edit(let tag):
            _name = State(initialValue: tag.name)
            _selectedColorHex = State(initialValue: tag.colorHex)
            _selectedIcon = State(initialValue: tag.icon)
            let isCustom = !Self.colorPalette.contains(where: { $0.hex == tag.colorHex })
            _useCustomColor = State(initialValue: isCustom)
            _customColor = State(initialValue: Color(hex: tag.colorHex) ?? .blue)
            _isExcludedFromAutoDelete = State(initialValue: tag.isExcludedFromAutoDelete)
        }
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("名称") {
                    TextField("标签名称", text: $name)
                        .focused($isNameFocused)
                }

                Section("颜色") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 12) {
                        ForEach(Self.colorPalette, id: \.hex) { color in
                            Button {
                                selectedColorHex = color.hex
                                useCustomColor = false
                            } label: {
                                Circle()
                                    .fill(Color(hex: color.hex) ?? .blue)
                                    .frame(width: 36, height: 36)
                                    .overlay {
                                        if !useCustomColor && selectedColorHex == color.hex {
                                            Image(systemName: "checkmark")
                                                .font(.caption.bold())
                                                .foregroundStyle(.white)
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(color.name)
                        }
                    }
                    .padding(.vertical, 4)

                    ColorPicker("自定义颜色", selection: $customColor, supportsOpacity: false)
                        .onChange(of: customColor) { _, newColor in
                            useCustomColor = true
                            selectedColorHex = newColor.hexString
                        }
                }

                Section("图标") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 12) {
                        ForEach(Self.iconOptions, id: \.self) { icon in
                            Button {
                                selectedIcon = icon
                            } label: {
                                Image(systemName: icon)
                                    .font(.body)
                                    .frame(width: 40, height: 40)
                                    .background(
                                        selectedIcon == icon
                                            ? (Color(hex: selectedColorHex) ?? .blue).opacity(0.2)
                                            : Color.clear
                                    )
                                    .foregroundStyle(
                                        selectedIcon == icon
                                            ? (Color(hex: selectedColorHex) ?? .blue)
                                            : .secondary
                                    )
                                    .clipShape(.rect(cornerRadius: 8))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .strokeBorder(
                                                selectedIcon == icon
                                                    ? (Color(hex: selectedColorHex) ?? .blue)
                                                    : .clear,
                                                lineWidth: 2
                                            )
                                    )
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(icon)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section {
                    Toggle(isOn: $isExcludedFromAutoDelete) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("不自动删除")
                                .font(.body)
                            Text("带有这个标签的笔记，无论多旧，都不会被自动清理笔记和音频。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("预览") {
                    HStack(spacing: 12) {
                        Image(systemName: selectedIcon)
                            .font(.body)
                            .foregroundStyle(.white)
                            .frame(width: 32, height: 32)
                            .background(Color(hex: selectedColorHex) ?? .blue)
                            .clipShape(.rect(cornerRadius: 8))

                        Text(name.isEmpty ? "Tag name" : name)
                            .foregroundStyle(name.isEmpty ? .secondary : .primary)
                    }
                }
            }
            .navigationTitle(mode.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if #available(iOS 26, *) {
                        Button("关闭", systemImage: "xmark") {
                            dismiss()
                        }
                        .labelStyle(.iconOnly)
                    } else {
                        Button("取消") {
                            dismiss()
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        onSave(
                            Draft(
                                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                                colorHex: selectedColorHex,
                                icon: selectedIcon,
                                isExcludedFromAutoDelete: isExcludedFromAutoDelete
                            )
                        )
                        dismiss()
                    }
                    .disabled(!canSave)
                }
            }
            .onAppear {
                if case .create = mode {
                    isNameFocused = true
                }
            }
        }
    }
}
