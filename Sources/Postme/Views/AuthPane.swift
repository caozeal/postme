import SwiftUI

/// 「认证」分页：Bearer / Basic / API Key。
///
/// 这里只编辑配置，不直接改 Header——物化发生在 `AuthApplier`，发送、最终 URL 预览、
/// cURL 导出共用同一条路径（见 `AppState.resolve`）。
struct AuthPane: View {
    let l10n: Localizer
    @Binding var auth: RequestAuth

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    typeRow
                    Divider()
                    fields
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()
            hint
        }
    }

    private var typeRow: some View {
        HStack(spacing: 10) {
            Text(l10n(.authKindLabel))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            Picker("", selection: $auth.kind) {
                ForEach(AuthKind.allCases) { kind in
                    Text(kind.displayName(l10n)).tag(kind)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 200)

            Spacer()
        }
    }

    @ViewBuilder
    private var fields: some View {
        switch auth.kind {
        case .none:
            Text(l10n(.authNoneHint))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.vertical, 4)

        case .bearer:
            SecretField(
                l10n: l10n,
                label: l10n(.authBearerTokenLabel),
                placeholder: l10n(.authBearerTokenPlaceholder),
                text: $auth.bearerToken
            )

        case .basic:
            VStack(alignment: .leading, spacing: 14) {
                LabeledField(
                    label: l10n(.authUsernameLabel),
                    placeholder: l10n(.authUsernamePlaceholder),
                    text: $auth.username
                )
                SecretField(
                    l10n: l10n,
                    label: l10n(.authPasswordLabel),
                    placeholder: l10n(.authPasswordPlaceholder),
                    text: $auth.password
                )
            }

        case .apiKey:
            VStack(alignment: .leading, spacing: 14) {
                LabeledField(
                    label: l10n(.authAPIKeyNameLabel),
                    placeholder: l10n(.authAPIKeyNamePlaceholder),
                    text: $auth.apiKeyName
                )
                SecretField(
                    l10n: l10n,
                    label: l10n(.authAPIKeyValueLabel),
                    placeholder: l10n(.authAPIKeyValuePlaceholder),
                    text: $auth.apiKeyValue
                )

                VStack(alignment: .leading, spacing: 6) {
                    Text(l10n(.authAPIKeyLocationLabel))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Picker("", selection: $auth.apiKeyLocation) {
                        ForEach(APIKeyLocation.allCases) { location in
                            Text(location.displayName(l10n)).tag(location)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 200)
                }
            }
        }
    }

    private var hint: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "info.circle")
            Text(l10n(.authHint))
            Spacer()
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

// MARK: - 字段

/// 普通文本字段（用户名、Key 名等）。
private struct LabeledField: View {
    let label: String
    let placeholder: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .frame(maxWidth: 460)
        }
    }
}

/// 敏感字段：默认掩码，可点眼睛临时显示。
///
/// 用 `SecureField` 而不是普通输入框，是为了避免 token 在共享屏幕 / 录屏时直接暴露；
/// 掩码状态不持久化，切页签回来仍是隐藏的。
private struct SecretField: View {
    let l10n: Localizer
    let label: String
    let placeholder: String
    @Binding var text: String

    @State private var revealed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            HStack(spacing: 6) {
                Group {
                    if revealed {
                        TextField(placeholder, text: $text)
                    } else {
                        SecureField(placeholder, text: $text)
                    }
                }
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))

                Button {
                    revealed.toggle()
                } label: {
                    Image(systemName: revealed ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
                .help(l10n(revealed ? .authHideSecretHelp : .authShowSecretHelp))
                .accessibilityLabel(l10n(revealed ? .authHideSecretHelp : .authShowSecretHelp))
            }
            .frame(maxWidth: 460)
        }
    }
}
