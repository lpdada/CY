//
//  OnboardingMicrophonePage.swift
//  VivaDicta
//
//  Created by Anton Novoselov on 2025.12.05
//

import SwiftUI

enum MicrophonePermissionState {
    case undetermined
    case granted
    case denied
}

struct OnboardingMicrophonePage: View {
    @Binding var permissionState: MicrophonePermissionState

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // Main Card
            OnboardingCard {
                HStack(spacing: 16) {
                    OnboardingAppIcon(size: 80, useSinebow: true)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("麦克风权限")
                            .font(.title2.weight(.bold))

                        Text("转写录音必需。")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                // Privacy Card
                OnboardingPrivacyCard(
                    title: "Privacy Guaranteed",
                    description: "Audio never leaves your device unless you choose cloud models."
                )
            }
            .padding(.horizontal, 24)

            Spacer()
        }
    }
}

#Preview {
    OnboardingMicrophonePage(permissionState: .constant(.undetermined))
        .background(Color(.systemGroupedBackground))
}
