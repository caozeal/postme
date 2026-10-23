import SwiftUI
import Foundation

/// 「Cookie」分页：手动 Cookie 行 + 会话 Cookie Jar。
struct CookiePane: View {
    @Environment(AppState.self) private var app
    let l10n: Localizer
    @Binding var cookies: [KeyValueItem]

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            manualHeader
            Divider()
            KeyValueEditor(
                items: $cookies,
                keyPlaceholder: l10n(.cookieNamePlaceholder),
                valuePlaceholder: l10n(.cookieValuePlaceholder)
            )
            .frame(maxHeight: 200)
            Divider()
            sessionHeader
            Divider()
            sessionList
            Spacer(minLength: 0)
        }
    }

    // MARK: - 开关

    private var controls: some View {
        VStack(alignment: .leading, spacing: 6) {
            CookieJarToggle(title: l10n(.cookieJarEnabledLabel))

            Text(l10n(.cookieJarHint))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - 手动 Cookie

    private var manualHeader: some View {
        HStack(spacing: 6) {
            Text(l10n(.cookieManualHeader))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - 会话 Cookie

    private var sessionHeader: some View {
        HStack(spacing: 8) {
            Text(l10n(.cookieSessionHeader))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(l10n(.cookieSessionCount, app.sessionCookieCount))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .monospacedDigit()

            if !app.draft.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(l10n(.cookieSessionMatching, app.cookiesForCurrentDraft.count))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }

            Spacer()

            Button(l10n(.cookieSessionClear)) {
                app.clearCookieJar()
            }
            .font(.system(size: 11))
            .disabled(app.sessionCookieCount == 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var sessionList: some View {
        let items = app.cookieJar.all
        if items.isEmpty {
            HStack {
                Text(l10n(.cookieSessionEmpty))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(items, id: \.self) { cookie in
                        row(cookie)
                        Divider()
                    }
                }
            }
            .frame(maxHeight: 170)
        }
    }

    private func row(_ cookie: HTTPCookie) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: cookie.isSecure ? "lock.fill" : "globe")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                Text("\(cookie.name)=\(cookie.value)")
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(2)

                HStack(spacing: 8) {
                    Text("\(l10n(.cookieDomainLabel)): \(cookie.domain)")
                    Text("\(l10n(.cookiePathLabel)): \(cookie.path)")
                    Text("\(l10n(.cookieExpiresLabel)): \(expiryText(cookie))")
                }
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }

    private func expiryText(_ cookie: HTTPCookie) -> String {
        guard let date = cookie.expiresDate else { return l10n(.cookieExpiresSession) }
        return DateFormatter.localizedString(from: date, dateStyle: .short, timeStyle: .short)
    }
}


/// 独立成小视图：`@Bindable` 放在 `body` 里，绑定身份稳定，
/// 也不需要在每次渲染时重新构造一个 `Binding`。
private struct CookieJarToggle: View {
    @Environment(AppState.self) private var app
    let title: String

    var body: some View {
        @Bindable var app = app
        Toggle(title, isOn: $app.cookieJarEnabled)
            .toggleStyle(.switch)
    }
}
