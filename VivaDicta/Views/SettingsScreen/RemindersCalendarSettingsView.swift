// Copyright © 2026 Anton Novoselov. All rights reserved.

import AppGroup
import SwiftUI

/// Automatic extraction of reminders and calendar events from saved notes.
///
/// The two switches are independent: the reminder switch gates the automatic
/// background pass after a note is saved, while the calendar switch decides
/// whether any extraction pass - automatic or run by hand from a note - also
/// looks for dated events.
struct RemindersCalendarSettingsView: View {
    @AppStorage(UserDefaultsStorage.Keys.isAutoReminderExtractionEnabled, store: UserDefaultsStorage.appPrivate)
    private var isAutoReminderExtractionEnabled = false

    @AppStorage(UserDefaultsStorage.Keys.isCalendarEventExtractionEnabled, store: UserDefaultsStorage.appPrivate)
    private var isCalendarEventExtractionEnabled = false

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $isAutoReminderExtractionEnabled) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("自动提取提醒建议")
                            .font(.body)
                        Text("保存新笔记后，在后台检测值得提醒的任务，供你确认。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .onChange(of: isAutoReminderExtractionEnabled) { _, _ in
                    HapticManager.selectionChanged()
                }
            } header: {
                Text("提醒事项")
            }

            Section {
                Toggle(isOn: $isCalendarEventExtractionEnabled) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("同时提取日历事件")
                            .font(.body)
                        Text("同时找出有明确时间的事情——晚餐、会议、约会——并建议添加为日历事件。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .onChange(of: isCalendarEventExtractionEnabled) { _, _ in
                    HapticManager.selectionChanged()
                }
            } header: {
                Text("日历")
            } footer: {
                Text("对你在笔记里手动发起的提取和上面的自动提取都生效。")
            }
        }
        .navigationTitle("提醒事项与日历")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        RemindersCalendarSettingsView()
    }
}
#endif
