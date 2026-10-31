//
//  Tip.swift
//  VivaDicta
//
//  Created by Anton Novoselov on 2025.08.16
//

import Foundation
import SwiftUI
import TipKit

struct SelectLanguageTip: Tip {
    var title: Text {
        Text("选择语言")
            .foregroundStyle(
                MeshGradient(
                    width: 2,
                    height: 2,
                    points: [
                        [0, 0], [1, 0],
                        [0, 1], [1, 1]
                    ],
                    colors: [
                        .blue, .green,
                        .indigo, .teal
                    ]
                )
            )
    }
    
    var message: Text? {
        Text("点这里选择语言，转写更准确")
    }

    var image: Image? {
        Image(systemName: "flag")
    }
    
}

struct SelectTranscriptionModelTipMainView: Tip {
    
    static let selectModelEvent = Event(id: "selectTranscriptionModel")
    
    @Parameter(.transient)
    static var isTranscriptionReady: Bool = false
    
    var title: Text {
        Text("选择转写模型")
            .foregroundStyle(
                MeshGradient(
                    width: 2,
                    height: 2,
                    points: [
                        [0, 0], [1, 0],
                        [0, 1], [1, 1]
                    ],
                    colors: [
                        .blue, .green,
                        .indigo, .teal
                    ]
                )
            )
    }
    
    var message: Text? {
        Text("点这里设置转写模型")
    }
    
    var image: Image? {
        Image(systemName: "waveform")
    }
    
    var actions: [Action] {
        [
            Tip.Action(id: "go-to-models", title: "Open Models")
        ]
    }
    
    var rules: [Rule] {
        #Rule(Self.selectModelEvent) { event in
            event.donations.count == 0
        }
    }
}

struct SelectTranscriptionModelTipSettingsView: Tip {
    
    static let selectModelEvent = Event(id: "selectTranscriptionModel")
    
    @Parameter(.transient)
    static var isTranscriptionReady: Bool = false
    
    
    var title: Text {
        Text("选择转写模型")
            .foregroundStyle(
                MeshGradient(
                    width: 2,
                    height: 2,
                    points: [
                        [0, 0], [1, 0],
                        [0, 1], [1, 1]
                    ],
                    colors: [
                        .blue, .green,
                        .indigo, .teal
                    ]
                )
            )
    }
    
    var message: Text? {
        Text("点这里设置转写模型")
    }

    var image: Image? {
        Image(systemName: "waveform")
    }
    
    var rules: [Rule] {
        #Rule(Self.selectModelEvent) { event in
            event.donations.count == 0
        }
    }

}

struct SelectAIEnhacementTip: Tip {
    var title: Text {
        Text("添加 AI 处理")
    }

    var message: Text? {
        Text("用 AI 提升转写质量")
    }

    var image: Image? {
        Image(systemName: "wand.and.sparkles")
    }

}

struct TranscriptTagsTip: Tip {
    static let promptEditOpenedEvent = Event(id: "promptEditOpened")

    var title: Text {
        Text("小提示：使用 <TRANSCRIPT> 标签")
            .foregroundStyle(
                MeshGradient(
                    width: 2,
                    height: 2,
                    points: [
                        [0, 0], [1, 0],
                        [0, 1], [1, 1]
                    ],
                    colors: [
                        .purple, .red,
                        .blue, .pink
                    ]
                )
            )
    }

    var message: Text? {
        Text("在指令里用 <TRANSCRIPT> 引用转写的文本")
    }

    var image: Image? {
        Image(systemName: "chevron.left.forwardslash.chevron.right")
    }

    var rules: [Rule] {
        #Rule(Self.promptEditOpenedEvent) { event in
            event.donations.count >= 3
        }
    }
}

// MARK: - 3.0 Feature Discovery Tips

private nonisolated func discoveryMeshGradient() -> MeshGradient {
    MeshGradient(
        width: 2,
        height: 2,
        points: [
            [0, 0], [1, 0],
            [0, 1], [1, 1]
        ],
        colors: [
            .blue, .purple,
            .indigo, .pink
        ]
    )
}

struct ChatsDiscoveryTip: Tip {
    static let transcriptionCreatedEvent = Event(id: "transcriptionCreated")
    static let chatsOpenedEvent = Event(id: "chatsOpened")

    var title: Text {
        Text("和你的笔记对话")
            .foregroundStyle(discoveryMeshGradient())
    }

    var message: Text? {
        Text("向任意笔记提问，或同时围绕多条笔记对话。")
    }

    var image: Image? {
        Image(systemName: "bubble.left.and.text.bubble.right.fill")
    }

    var rules: [Rule] {
        #Rule(Self.transcriptionCreatedEvent) { event in
            event.donations.count >= 3
        }
        #Rule(Self.chatsOpenedEvent) { event in
            event.donations.count == 0
        }
    }
}

struct SmartSearchDiscoveryTip: Tip {
    static let smartSearchPerformedEvent = Event(id: "smartSearchPerformed")

    var title: Text {
        Text("按语义搜索")
            .foregroundStyle(discoveryMeshGradient())
    }

    var message: Text? {
        Text("试着问「我关于定价说了什么？」，智能 AI 搜索不用原词也能找到。")
    }

    var image: Image? {
        Image(systemName: "magnifyingglass.circle.fill")
    }

    var rules: [Rule] {
        #Rule(ChatsDiscoveryTip.transcriptionCreatedEvent) { event in
            event.donations.count >= 5
        }
        #Rule(Self.smartSearchPerformedEvent) { event in
            event.donations.count == 0
        }
    }
}

struct AIVariationsDiscoveryTip: Tip {
    static let variationGeneratedEvent = Event(id: "variationGenerated")

    @Parameter(.transient)
    static var isAIConfigured: Bool = false

    var title: Text {
        Text("试试不同的 AI 版本")
            .foregroundStyle(discoveryMeshGradient())
    }

    var message: Text? {
        Text("生成摘要、改写或翻译。每个结果都会保存为一个版本，方便对比。")
    }

    var image: Image? {
        Image(systemName: "sparkles")
    }

    var rules: [Rule] {
        #Rule(Self.variationGeneratedEvent) { event in
            event.donations.count == 0
        }
        #Rule(Self.$isAIConfigured) { $0 == true }
    }
}

// MARK: - 3.2 Feature Discovery Tips

struct NativeTranslationTip: Tip {
    var title: Text {
        Text("一步翻译")
            .foregroundStyle(discoveryMeshGradient())
    }

    var message: Text? {
        Text("这个服务商在转写的同时翻译。选一个目标语言，转写回来就已经是翻译好的——不需要额外的 AI 处理步骤。")
    }

    var image: Image? {
        Image(systemName: "text.bubble.fill")
    }
}

struct SingleNoteChatDiscoveryTip: Tip {
    static let singleNoteChatOpenedEvent = Event(id: "singleNoteChatOpened")

    @Parameter(.transient)
    static var isAIConfigured: Bool = false

    var title: Text {
        Text("向这条笔记提问")
            .foregroundStyle(discoveryMeshGradient())
    }

    var message: Text? {
        Text("深入挖掘你录的内容——生成摘要、答疑或待办事项。")
    }

    var image: Image? {
        Image(systemName: "bubble.left.and.text.bubble.right")
    }

    var rules: [Rule] {
        #Rule(Self.singleNoteChatOpenedEvent) { event in
            event.donations.count == 0
        }
        #Rule(Self.$isAIConfigured) { $0 == true }
    }
}

