import XCTest
@testable import Postme

/// 本地化基础设施：文案表完整性、格式占位符一致性、语言偏好、持久化。
@MainActor
final class LocalizationTests: XCTestCase {

    private func makeTempDirectory() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("postme-l10n-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - 1. 两张表覆盖全部 key

    func testEveryKeyExistsInBothTables() {
        for key in L10nKey.allCases {
            let zh = L10nTable.zhHans[key]
            let en = L10nTable.en[key]
            XCTAssertNotNil(zh, "zhHans 缺少 \(key)")
            XCTAssertNotNil(en, "en 缺少 \(key)")
            XCTAssertFalse(zh?.isEmpty ?? true, "zhHans 的 \(key) 为空")
            XCTAssertFalse(en?.isEmpty ?? true, "en 的 \(key) 为空")
        }
        XCTAssertEqual(L10nTable.zhHans.count, L10nKey.allCases.count, "zhHans 表有多余 key")
        XCTAssertEqual(L10nTable.en.count, L10nKey.allCases.count, "en 表有多余 key")
    }

    // MARK: - 2. 占位符序列一致

    /// 抽取完整形式的格式占位符（含 `%%`），按出现顺序比较。
    /// 覆盖 `%.1f`、`%@`、`%d`；只比「有没有、什么类型、什么顺序」——
    /// 参数类型错配会在这里暴露，而不会被运行时静默格式化掉。
    func testFormatPlaceholdersMatchAcrossLanguages() {
        let pattern = #"%(\d+\$)?[-+0-9.]*[hlq]*[@dDfFeEgGxXoOcs%]"#
        let regex = try! NSRegularExpression(pattern: pattern)

        func placeholders(_ value: String) -> [String] {
            let range = NSRange(value.startIndex..., in: value)
            return regex.matches(in: value, range: range).compactMap { match in
                guard let r = Range(match.range, in: value) else { return nil }
                return String(value[r])
            }
        }

        for key in L10nKey.allCases {
            let zh = placeholders(L10nTable.zhHans[key] ?? "")
            let en = placeholders(L10nTable.en[key] ?? "")
            XCTAssertEqual(zh, en, "\(key) 的占位符序列不一致：zh=\(zh) en=\(en)")
        }
    }

    // MARK: - 3. 英文表不含 CJK

    func testEnglishTableHasNoCJK() {
        let cjk = try! NSRegularExpression(pattern: #"[\u4e00-\u9fff]"#)
        for key in L10nKey.allCases {
            let value = L10nTable.en[key] ?? ""
            let range = NSRange(value.startIndex..., in: value)
            XCTAssertNil(cjk.firstMatch(in: value, range: range), "en 的 \(key) 仍含中文：\(value)")
        }
    }

    // MARK: - 4. AppSettings 容错

    func testAppSettingsToleratesMissingLanguage() throws {
        let json = #"{"timeout":30,"followRedirects":true,"allowInsecureTLS":false}"#
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        XCTAssertNil(settings.language, "缺 language 键应得到 nil（跟随系统）")
    }

    func testAppSettingsToleratesUnknownLanguage() throws {
        let json = #"{"timeout":30,"followRedirects":true,"allowInsecureTLS":false,"language":"fr"}"#
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        XCTAssertNil(settings.language, "未知语言值应退回 nil，而不是让整份设置解码失败")
    }

    func testAppSettingsLanguageRoundTrips() throws {
        for language in AppLanguage.allCases {
            var settings = AppSettings()
            settings.language = language
            let data = try JSONEncoder().encode(settings)
            let back = try JSONDecoder().decode(AppSettings.self, from: data)
            XCTAssertEqual(back.language, language)
        }
    }

    func testWorkspaceWithoutLanguageKeyStillLoads() throws {
        // 缺 language 键的老文件必须整份载入，不能因为新字段变空工作区。
        let json = """
        {"version":3,"projects":[{"id":"\(UUID().uuidString)","name":"P","children":[]}],
         "environments":[],"history":[],"settings":{"timeout":10,"followRedirects":true,"allowInsecureTLS":false}}
        """
        let workspace = try JSONDecoder().decode(Workspace.self, from: Data(json.utf8))
        XCTAssertEqual(workspace.projects.first?.name, "P")
        XCTAssertNil(workspace.settings.language)
    }

    // MARK: - 5. 系统语言偏好

    func testPreferredLanguageFromSystemTags() {
        XCTAssertEqual(AppLanguage.preferred(from: ["en-US"]), .en)
        XCTAssertEqual(AppLanguage.preferred(from: ["zh-Hans-CN"]), .zhHans)
        XCTAssertEqual(AppLanguage.preferred(from: ["fr-FR"]), .zhHans)
        // 繁体未支持：中文优先于英文回退
        XCTAssertEqual(AppLanguage.preferred(from: ["zh-Hant-TW"]), .zhHans)
        // 跳过不认识的语言，取第一个能识别的
        XCTAssertEqual(AppLanguage.preferred(from: ["fr-FR", "en-GB"]), .en)
        XCTAssertEqual(AppLanguage.preferred(from: []), .zhHans)
    }

    // MARK: - 6. 切换语言：即时生效 + 落盘

    func testSetLanguageUpdatesLocalizerAndPersists() {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let app = AppState(
            persistence: PersistenceService(fileName: "workspace.json", directory: dir),
            languageOverride: .zhHans
        )
        XCTAssertEqual(app.effectiveLanguage, .zhHans)
        XCTAssertEqual(app.t(.saveButton), "保存")

        app.setLanguage(.en)
        XCTAssertEqual(app.t(.saveButton), "Save", "切换后取词器立即变化")
        XCTAssertEqual(app.workspace.settings.language, .en, "选择写入 settings")

        // 读回磁盘：setLanguage 必须立即落盘，不依赖防抖计时。
        let reloaded = AppState(persistence: PersistenceService(fileName: "workspace.json", directory: dir))
        XCTAssertEqual(reloaded.workspace.settings.language, .en)
        XCTAssertEqual(reloaded.t(.saveButton), "Save")

        // 回到跟随系统
        reloaded.setLanguage(nil)
        XCTAssertNil(reloaded.workspace.settings.language)
        XCTAssertEqual(reloaded.effectiveLanguage, AppLanguage.systemDefault)
    }

    func testLanguageOverrideBeatsStoredSetting() {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let service = PersistenceService(fileName: "workspace.json", directory: dir)
        var workspace = service.load()
        workspace.settings.language = .en
        service.saveNow(workspace)

        let app = AppState(persistence: service, languageOverride: .zhHans)
        XCTAssertEqual(app.effectiveLanguage, .zhHans, "override 在 ensureActiveProject 之前写入")
    }

    func testLanguageChangeIsObservable() {
        // 菜单命令（.commands）在视图环境之外，只能靠 @Observable 触发重算。
        // 这里用与 SwiftUI 相同的 observation 机制验证：读 app.t 会登记依赖，
        // setLanguage 之后依赖必须被通知，否则菜单栏文案会停在旧语言。
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let app = AppState(
            persistence: PersistenceService(fileName: "workspace.json", directory: dir),
            languageOverride: .zhHans
        )

        var invalidated = false
        withObservationTracking {
            _ = app.t(.menuSendRequest)
        } onChange: {
            invalidated = true
        }

        app.setLanguage(.en)
        XCTAssertTrue(invalidated, "语言变化必须让读取 app.t 的观察者失效（菜单栏重算的前提）")
        XCTAssertEqual(app.t(.menuSendRequest), "Send Request")
    }

    func testSetLanguageRecomputesResponseBodyTextAndClearsMessages() {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let app = AppState(
            persistence: PersistenceService(fileName: "workspace.json", directory: dir),
            languageOverride: .zhHans
        )
        // 二进制响应：展示文本是本地化占位说明。
        let binary = APIResponse(
            statusCode: 200,
            headers: [],
            body: Data([0x00, 0xFF, 0xFE]),
            mimeType: "application/octet-stream",
            timing: RequestTiming()
        )
        app.response = binary
        app.setLanguage(.zhHans)
        XCTAssertTrue(app.responseBodyText.contains("二进制响应"))

        app.errorMessage = "旧语言错误"
        app.alertMessage = .init(text: "旧语言提示")

        app.setLanguage(.en)
        XCTAssertTrue(app.responseBodyText.contains("binary response"), "切换语言后响应体文本重算")
        XCTAssertNil(app.errorMessage, "已生成的旧语言错误文本被清掉")
        XCTAssertNil(app.alertMessage, "已生成的旧语言提示文本被清掉")
    }

    // MARK: - 8. 占位名双语判定（语义陷阱的持久防线）

    /// 占位名是创建时按当时语言落盘的：中文界面建的草稿切到英文后仍叫「未命名请求」。
    /// 只认当前语言的字面量，就会把占位名当用户输入，历史里堆满「未命名请求」。
    func testPlaceholderNameDetectionAcceptsBothLanguages() {
        for language in AppLanguage.allCases {
            let app = AppState(
                persistence: PersistenceService(fileName: "workspace.json", directory: makeTempDirectory()),
                languageOverride: language
            )
            let zh = L10nTable.zhHans[.untitledRequest]!
            let en = L10nTable.en[.untitledRequest]!

            for placeholder in [zh, en] {
                app.draft = APIRequest(name: placeholder, url: "https://api.example.com/v1/orders")
                XCTAssertEqual(app.suggestedName(), "orders", "\(language)：\(placeholder) 应回退到 URL 末段")

                let name = app.requestNameForHistory(app.draft)
                XCTAssertEqual(name, "orders", "\(language)：历史名同样回退到 URL 末段")
            }

            // 用户真起的名字必须原样保留。
            app.draft = APIRequest(name: "下单", url: "https://api.example.com/v1/orders")
            XCTAssertEqual(app.suggestedName(), "下单", "用户命名不得被覆盖")
        }
    }

    // MARK: - 9. 服务层文案与默认名随语言变化（AC3）

    func testCurlCodecWarningsAndDefaultNamesFollowLanguage() throws {
        // 同时触发多种提示：未识别参数、缺协议头、-k/-L/-m 全局项、文件字段。
        let command = #"curl -k -L -m 5 localhost:8080/x -F 'f=@/tmp/a.png' --bogus"#
        let zh = try CurlCodec.decode(command, l10n: .zhHans)
        let en = try CurlCodec.decode(command, l10n: .en)

        XCTAssertEqual(zh.requests.count, en.requests.count)
        XCTAssertFalse(zh.warnings.isEmpty, "该命令必须产生提示")
        XCTAssertEqual(zh.warnings.count, en.warnings.count, "提示条数不该随语言变化")
        for (zhText, enText) in zip(zh.warnings, en.warnings) {
            XCTAssertNotEqual(zhText, enText, "提示应随语言变化：\(zhText)")
            XCTAssertFalse(enText.contains("「"), "英文提示不该带中文引号：\(enText)")
        }

        // 文件字段占位值同样本地化。
        XCTAssertEqual(zh.requests[0].formFields.first?.value, "（文件字段，v1 不支持）")
        XCTAssertEqual(en.requests[0].formFields.first?.value, L10nTable.en[.curlFileFieldPlaceholder])

        // 无路径段时用主机名；无主机时兜底名走语言表。
        let bare = try CurlCodec.decode("curl -X POST 'https://'", l10n: .en)
        XCTAssertEqual(bare.requests[0].name, "cURL Import")
        let bareZH = try CurlCodec.decode("curl -X POST 'https://'", l10n: .zhHans)
        XCTAssertEqual(bareZH.requests[0].name, "cURL 导入")
    }

    func testCurlCodecErrorsFollowLanguage() {
        XCTAssertThrowsError(try CurlCodec.decode("  ", l10n: .en)) { error in
            guard let codec = error as? CurlCodec.CodecError else { return XCTFail("类型不符") }
            XCTAssertEqual(codec.message(.en), "Nothing to import")
            XCTAssertEqual(codec.message(.zhHans), "没有可导入的内容")
        }
    }

    func testPostmanCodecNamesAndWarningsFollowLanguage() throws {
        let json = """
        {"info":{"name":"演示"},"item":[
          {"name":"登录","request":{"method":"GET","url":{"raw":"https://a.demo/login"},
           "auth":{"type":"oauth2"}}}
        ],"variable":[{"key":"base","value":"https://a.demo"}]}
        """
        let zh = try PostmanCodec.decode(Data(json.utf8), l10n: .zhHans)
        let en = try PostmanCodec.decode(Data(json.utf8), l10n: .en)

        XCTAssertEqual(zh.environment?.name, "演示 变量")
        XCTAssertEqual(en.environment?.name, "演示 variables")
        XCTAssertEqual(zh.warnings.count, en.warnings.count)
        XCTAssertFalse(zh.warnings.isEmpty)
        XCTAssertNotEqual(zh.warnings[0], en.warnings[0], "认证警告应随语言变化")
        XCTAssertTrue(en.warnings[0].hasPrefix("Auth type oauth2"))
    }

    func testPostmanCodecFallbackNamesFollowLanguage() throws {
        // 缺 info.name 与条目 name：解码期写占位符，出口换成当前语言。
        let json = #"{"info":{},"item":[{"request":{"method":"GET","url":{"raw":"https://a.demo/x"}}}]}"#
        let zh = try PostmanCodec.decode(Data(json.utf8), l10n: .zhHans)
        let en = try PostmanCodec.decode(Data(json.utf8), l10n: .en)
        XCTAssertEqual(zh.collectionName, "未命名集合")
        XCTAssertEqual(en.collectionName, "Untitled Collection")
        XCTAssertEqual(zh.nodes.first?.name, "未命名")
        XCTAssertEqual(en.nodes.first?.name, "Untitled")
    }

    func testRequestFailureMessagesFollowLanguage() {
        XCTAssertEqual(RequestFailure.invalidURL("").message(.en), "URL is empty")
        XCTAssertEqual(RequestFailure.invalidURL("ht!tp").message(.en), "Invalid URL: ht!tp")
        XCTAssertEqual(RequestFailure.cancelled.message(.zhHans), "请求已取消")
        XCTAssertEqual(RequestFailure.unexpected.message(.en), "No valid HTTP response received")
    }

    func testBodyKindAndTabTitlesFollowLanguage() {
        XCTAssertEqual(BodyKind.json.displayName(.en), "JSON")
        XCTAssertEqual(BodyKind.formURLEncoded.displayName(.en), "Form URL Encoded")
        XCTAssertEqual(BodyKind.multipart.displayName(.zhHans), L10nTable.zhHans[.bodyKindMultipart])
        XCTAssertEqual(RequestTab.headers.title(.en), "Headers")
        XCTAssertEqual(RequestTab.headers.title(.zhHans), "Headers")
        XCTAssertEqual(ResponseTab.timing.title(.en), "Timing")
        XCTAssertEqual(ResponseTab.timing.title(.zhHans), "耗时")
    }
}
