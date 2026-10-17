import SwiftUI

/// 设置面板（macOS 标准「设置…」窗口，⌘,）。
struct SettingsView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        let settings = app.bindingForSettings()

        Form {
            Section(app.t(.settingsLanguageSection)) {
                Picker(app.t(.settingsLanguageLabel), selection: languageBinding) {
                    Text(app.t(.settingsLanguageSystem)).tag(AppLanguage?.none)
                    ForEach(AppLanguage.allCases) { language in
                        // 语言自称永不翻译：英文界面下也要能认出「简体中文」。
                        Text(language.displayName).tag(AppLanguage?.some(language))
                    }
                }
                Text(app.t(.settingsLanguageHint))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section(app.t(.settingsRequestsSection)) {
                Stepper(value: settings.timeout, in: 1...3600, step: 5) {
                    HStack {
                        Text(app.t(.settingsTimeout))
                        Spacer()
                        Text(app.t(.settingsSeconds, Int(settings.timeout.wrappedValue)))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }

                Toggle(app.t(.settingsFollowRedirects), isOn: settings.followRedirects)

                Toggle(app.t(.settingsAllowInsecureTLS), isOn: settings.allowInsecureTLS)
                Text(app.t(.settingsAllowInsecureTLSHint))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section(app.t(.settingsStorageSection)) {
                HStack(alignment: .top) {
                    Text(app.t(.settingsWorkspaceFile))
                    Spacer()
                    Text(app.storagePath)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .multilineTextAlignment(.trailing)
                }
                Text(app.t(.settingsWorkspaceFileHint))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section(app.t(.settingsShortcutsSection)) {
                shortcutRow(app.t(.settingsShortcutSend), "⌘ ↩")
                shortcutRow(app.t(.settingsShortcutSave), "⌘ S")
                shortcutRow(app.t(.settingsShortcutNewRequest), "⌘ N")
                shortcutRow(app.t(.settingsShortcutSearch), "⌘ F")
                shortcutRow(app.t(.settingsShortcutImport), "⌘ ⇧ I")
                shortcutRow(app.t(.settingsShortcutExport), "⌘ ⇧ E")
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 600)
    }

    /// 语言 Picker 的绑定：写走 `setLanguage`（立即落盘 + 重算响应体文本 + 清掉旧语言提示），
    /// 不走 `bindingForSettings` 的通用路径——那条只保存，不会重算派生文本。
    private var languageBinding: Binding<AppLanguage?> {
        Binding(
            get: { [weak app] in app?.workspace.settings.language },
            set: { [weak app] in app?.setLanguage($0) }
        )
    }

    private func shortcutRow(_ label: String, _ keys: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(keys)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }
}
