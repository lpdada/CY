//
//  KeyboardReturnPromptView.swift
//  VivaDicta
//
//  Created by Anton Novoselov on 2026.06.05
//

import SwiftUI
import DesignSystem

/// Full-screen prompt shown when the keyboard dictation flow can't
/// automatically return the user to the host app (e.g. the host has no
/// URL scheme, or iOS didn't supply the host bundle id). It tells the
/// user to swipe back so dictation continues in the keyboard.
///
/// Dismisses when the user swipes back (the app resigns active - see
/// `VivaDictaApp` scene-phase handling), taps Dismiss, or after a timeout.
struct KeyboardReturnPromptView: View {
    @Environment(AppState.self) private var appState

    /// Auto-dismiss after this many seconds if the user doesn't swipe back.
    private static let autoDismissSeconds = 30

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            statusPill

            Text("滑动返回以继续")
                .font(.largeTitle)
                .bold()
                .foregroundStyle(Color.vivaAccent)

            Spacer()

            Image("VivaDictaIcon")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 120)
                .frame(maxWidth: .infinity)
                .accessibilityHidden(true)

            Spacer()

            VStack(spacing: 16) {
                Text("我们也不想让你为了用畅言切换 App，但 Apple 要求必须走这一步来激活麦克风。")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)

                Button("忽略", action: dismiss)
                    .font(.headline)
                    .padding(.top, 8)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task {
            HapticManager.mediumImpact()
            do {
                try await Task.sleep(for: .seconds(Self.autoDismissSeconds))
                dismiss()
            } catch {
                // Cancelled because the view is going away (swipe-back, Dismiss,
                // or scene-phase reset) - nothing to do.
            }
        }
    }

    private var statusPill: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(.green)
                .frame(width: 10, height: 10)
            Text("键盘已启用")
                .font(.subheadline)
                .fontWeight(.medium)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassEffectOrMaterial()
        .clipShape(.capsule)
    }

    private func dismiss() {
        // fullScreenCover uses the system modal-dismissal transition, so an
        // explicit withAnimation here would have no effect.
        appState.showKeyboardReturnPrompt = false
    }
}
