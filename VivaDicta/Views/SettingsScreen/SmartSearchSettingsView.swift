//
//  SmartSearchSettingsView.swift
//  VivaDicta
//
//  Created by Anton Novoselov on 2026.04.12
//

import SwiftUI
import SwiftData
import os

/// Settings screen for RAG Smart Search configuration.
struct SmartSearchSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @AppStorage(SmartSearchFeature.isEnabledKey) private var isSmartSearchEnabled = true

    @State private var isReindexing = false
    @State private var service = RAGIndexingService.shared

    private let logger = Logger(category: .ragIndexing)

    var body: some View {
        Form {
            Section {
                Toggle("启用智能搜索", isOn: $isSmartSearchEnabled)
            } footer: {
                Text("在搜索栏、智能对话和跨笔记搜索里，用 AI 语义搜索你的笔记。关闭后，智能搜索会停止为笔记建索引、删除本地语义索引，并隐藏这些入口。")
            }

            Section {
                HStack {
                    Text("已索引笔记")
                    Spacer()
                    if service.isIndexing || isReindexing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("\(service.indexedTranscriptionCount)")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .disabled(!isSmartSearchEnabled)

            Section {
                Button {
                    logger.logInfo("Smart Search settings requested manual reindex indexedNotes=\(service.indexedTranscriptionCount)")
                    isReindexing = true
                    Task {
                        await service.reindexAll(modelContext: modelContext)
                        logger.logInfo("Smart Search settings manual reindex finished indexedNotes=\(service.indexedTranscriptionCount)")
                        isReindexing = false
                    }
                } label: {
                    HStack {
                        Text("重新索引全部笔记")
                        Spacer()
                        if isReindexing {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                }
                .disabled(!isSmartSearchEnabled || isReindexing || service.isIndexing)
            } footer: {
                Text("从头重建搜索索引。如果搜索结果看起来不对，用这个。")
            }

            Section {
                Text("智能搜索用设备端 AI 模型在搜索栏、智能对话和跨笔记搜索里按语义理解你的笔记。模型会在第一次使用时自动下载。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("智能搜索")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: isSmartSearchEnabled) { _, isEnabled in
            logger.logInfo("Smart Search settings toggled enabled=\(isEnabled) indexedNotes=\(service.indexedTranscriptionCount)")
            isReindexing = true
            Task {
                if isEnabled {
                    await service.indexAllIfNeeded(modelContext: modelContext)
                } else {
                    await service.clearAll()
                }
                logger.logInfo("Smart Search settings toggle finished enabled=\(isEnabled) indexedNotes=\(service.indexedTranscriptionCount)")
                isReindexing = false
            }
        }
    }
}
