import SwiftUI

/// 设置面板（macOS 标准「设置…」窗口，⌘,）。
struct SettingsView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        let settings = app.bindingForSettings()

        Form {
            Section("请求") {
                Stepper(value: settings.timeout, in: 1...3600, step: 5) {
                    HStack {
                        Text("超时时间")
                        Spacer()
                        Text("\(Int(settings.timeout.wrappedValue)) 秒")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }

                Toggle("跟随重定向", isOn: settings.followRedirects)

                Toggle("忽略 HTTPS 证书校验（自签证书）", isOn: settings.allowInsecureTLS)
                Text("仅在调试内网自签证书服务时开启。开启后 TLS 证书不再校验，存在中间人风险。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section("存储") {
                HStack(alignment: .top) {
                    Text("工作区文件")
                    Spacer()
                    Text(app.storagePath)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .multilineTextAlignment(.trailing)
                }
                Text("项目、环境、历史与设置都保存在这个 JSON 文件里，可直接用 git 备份。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section("快捷键") {
                shortcutRow("发送请求", "⌘ ↩")
                shortcutRow("保存到项目", "⌘ S")
                shortcutRow("新建请求", "⌘ N")
                shortcutRow("搜索请求", "⌘ F")
                shortcutRow("导入为项目", "⌘ ⇧ I")
                shortcutRow("导出项目", "⌘ ⇧ E")
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 520)
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
