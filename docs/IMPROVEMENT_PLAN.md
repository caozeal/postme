# postme 易用性与可靠性改进计划

基线：2026-11-05 对当前工作区的代码审查、现有测试和竞品公开文档。项目定位是轻量、原生、本地优先的 HTTP/SSE 调试工具；新增能力以不破坏现有工作区和请求语义为前提。优先级代表建议实施顺序，不代表问题已通过 GUI 复现。

## 第一阶段：保护数据和目标环境

- [x] 避免侧栏覆盖操作静默丢弃目标页签的未保存草稿；确认信息说明来源、目标和风险。待真实 GUI 点击验证。
- [x] 旧工作区迁移先安全写入页签和历史，再切换核心文件；已测试侧车写入失败后旧核心保留及重试。中途强杀仍待实测。
- [x] 工作区保存失败在界面可见，支持重试；退出前不能把失败当成成功。`SaveResult` 把防抖/立即/示例写入的结果回传主线程，工具栏常驻标记 + 单个弹窗提供重试；退出改走 `applicationShouldTerminate` + `.terminateLater`，失败时给「重试 / 仍要退出 / 取消」且 `NSApp.reply` 恰好一次。单元用例已写（本机未跑）；按钮点击、Cmd-Q、关最后一窗与 Dock 退出待真实 GUI 点击验证。
- [x] OpenAPI 导入在切换项目待确认期间不改变当前环境；取消切换不激活新环境。并入现有项目保留已选环境，无环境时才启用新环境，预览中说明。
- [x] GUI 和 CLI 并发写同一目录时防止静默覆盖，明确占用提示及失败退出码。短锁 + 四文件磁盘指纹 CAS，冲突时 CLI 以退出码 3 失败且不写任何文件（`--json` 带 `workspace_busy` / `workspace_conflict`）；GUI 重新激活时检测外部改动并重载，有未落盘编辑时先询问。CLI 端到端已实测；GUI 检测/重载的单元用例已写但本机未跑、人工点击待验证。

## 第二阶段：请求与结果可信

- [x] SSE 接收期间不展示上一次请求的响应；使用本地 SSE 服务验证切换到流式状态时旧响应已清除。
- [ ] 普通请求在途时清晰标记旧响应的归属。
- [x] multipart 手动 Content-Type 存在时阻止发送并提示删除请求头；已覆盖请求构造和禁用请求头的回归测试。
- [ ] 删除文件夹、请求和环境前提示影响；删除当前环境后不自动切至其他环境。
- [ ] 切换项目将中断在途请求时给出提示，保留现有脏页签处理。
- [ ] 明确认证、环境和历史中敏感信息的本地存储与导出风险；评估 Keychain、权限收紧及兼容迁移。

## 第三阶段：日常操作体验

- [ ] 历史记录可访问全部保留条目，并提供搜索或按需加载。
- [ ] SSE 上翻时暂停自动滚动，提供恢复跟随入口。
- [ ] 完善页签和键值编辑器的键盘操作、无障碍名称及选中状态；检查窄窗口、英文和大字号布局。
- [ ] 评估从响应提取变量、Postman 环境和 HAR 导入；先确定环境作用域和安全默认值。
- [ ] 对大文件上传、分块响应、启动及常用工作负载做耗时和内存测量，再决定性能方案。

## 验收与记录

- 关键数据路径增加针对触发条件的回归测试，失败路径做故障注入；运行相关测试与完整 `swift test`。
- 涉及界面的操作分别验证正常、取消、错误和恢复路径，并说明自动化或人工验证范围。
- 每完成一项，在本文件勾选并补充实现、测试和未覆盖边界；避免把静态推断或单元测试表述为 GUI 实测。

2026-11-05 首批修复后：`swift test` 共 417 项，7 项跳过，1 项失败。迁移写失败重试、OpenAPI 切换确认、SSE 真实本地流及 multipart 冲突的回归用例通过。覆盖确认尚未进行真实 GUI 点击验证。

2026-11-09 定位并修复该失败用例。`measure(contentHeight:)` 传的是 `NSWindow` 的 `contentRect` 请求值，AppKit 会按标题栏和屏幕可用区域改写实际内容高度（本机 800→832、1100→908），而响应区下限按 `geo.size.height - 320` 算。原断言用绝对像素（响应区 ≥500、请求区 ≤320）正好卡在漂移区间里，换个环境就时红时绿（11-05 实测 460，本机实测 512）；布局本身没问题。已把 `SplitLayoutTests.testResponsePaneKeepsItsMinimumHeight` 改为按实测 `split.frame.height` 的相对契约断言（请求区预算 320 + 20 容差，响应区须大于总高一半），并让 `measure` 返回总高。

验证：用 26.5 SDK 链接 `Postme` 目标文件跑独立探针（真实 `ContentView`），800/620/1100 三种窗口下新断言全部通过；把布局改回「只写 idealHeight」的回归场景两栏变成 415/416，断言全部失败，防回归能力保留。测试文件通过 `swiftc -frontend -parse` 语法检查。**未跑 `swift test`**：本机 CLT 27.0 只有 swift-testing、不含 XCTest 模块，测试目标编译不了；默认 27.0 SDK 又缺 SwiftUI 宏插件，且 SwiftPM 的 manifest 沙箱需 `--disable-sandbox`。需在装有 Xcode 的环境跑全量测试确认。另两条用例（`testBothPanesStayUsableInSmallWindow`、`testTallWindowGivesExtraHeightToResponse`）同样依赖真实窗口高度，建议后续一并加固。

2026-11-09 第二批（第 9/11 行）：按用户选择做「短锁 + 冲突检测」，并给 GUI 补上磁盘变更检测与重载——否则 CLI 写入后 GUI 内存快照陈旧，下次保存仍会整份覆盖。

实现：新增 `WorkspaceLock`（`.postme.lock` 的 `flock` 短锁，不 unlink、只读目录降级）、`DiskFingerprint`（四个受管文件的 `lstat` 元数据：inode + 纳秒 mtime + size + mode）、`SaveResult`（succeeded / failed / stale / conflict）。CAS 收口在 `PersistenceService.flush`：`:197` 的「过期算成功」改为 `.stale`（否则会清掉真实失败标记）；写前比对全四文件指纹；部分失败仍重算基准并记下失败节——修故障本身也是磁盘变化，重试时豁免这些文件，避免死循环。`reloadFromDisk()` 除取消防抖外还把 `writeState.generation` 顶到最新，防止在途旧快照盖回磁盘。GUI 侧 `applyLoadedState` 从 init 抽出供 init/重载共用，按页签 id 迁移运行期状态、清理失效 pending id；错误状态存 `L10nKey + 参数`，切语言自动重译；`examples.json` 写入收归 `PersistenceService.saveExamples`，堵住第二条绕过 CAS 的路径。CLI 新增退出码 3 与 `--json` 的 `code` / `exitCode`，冲突不自动重试；`export --output` 拒绝写受管文件。锁只在写临界区持有，GUI 不常驻持锁；计划里的只读命令白名单最终未实现——所有写都收口到 `flush` 的 CAS，比按命令分类更 fail-safe，新增命令不可能绕过保护。

验证（本机）：debug 与 `xcrun --sdk macosx26.5 swift build -c release --disable-sandbox` 均通过；`build/postme` 端到端 17 项断言全绿（正常写 0、锁占用时写命令 3 且 `--json` 带 `workspace_busy`、冲突时一个字节都不写、只读命令在持锁时 0、`--help` / `--version` 不创建锁文件、未知命令 2、export 拒绝受管输出）；独立探针（链接 testable 目标文件，绕开 XCTest）22 项断言全绿，覆盖指纹识别 `.atomic` 换 inode、锁文件 inode 稳定、陈旧基准报冲突且不写盘、部分失败修复后可重试、reload 掐掉在途防抖、本地化两表覆盖/占位符/en 无 CJK、GUI 重载维持页签不变量与错误状态存键。新增 `WorkspaceConcurrencyTests.swift` / `CLIExitCodeTests.swift` 两个回归测试文件，`swiftc -frontend -parse` 语法检查通过。

**未跑 `swift test`**（本机无 XCTest，同上）；GUI 路径（切回触发自动重载、有未落盘编辑的三按钮、Cmd-Q / 关最后一窗 / Dock 退出三条路径、「取消」后主窗口恢复、工具栏标记消失、SSE 在飞期间重载）均为静态推断 + 单元级状态机，待真实 GUI 点击验证。只读命令的 `load()` 也在锁内读（跨文件一致、corrupt 备份受保护），但锁被占用时会降级为不加锁读，此时可能读到四个 JSON 之间不完全一致的快照（单份文件仍原子写），已在 README 注明；崩溃 / 强杀不触发退出拦截，防抖窗口内的在途改动仍会丢，属既有边界。README 的测试计数（410，已陈旧）只在跑完全量后按实数更新。

2026-11-09 第三批（真实 GUI 点击实测）：本机屏幕已解锁、`python3` 具备辅助功能权限，用 ctypes 直连 `AXUIElement` 驱动真实窗口（System Events 的 AppleScript 仍报 -10004 权限违例；CGEvent 合成点击被系统丢弃；`AXPress` 返回 -25205 但动作确实派发）。先在隔离目录用 `history.json` 占位目录注入写故障，再用 AX 点击菜单「Quit postme」触发退出拦截：**弹窗真实出现**，标题「退出前保存失败」、正文列出 `history.json`、三按钮「重试 / 仍要退出 / 取消」齐全，工具栏常驻「保存有问题」标记可见。点「取消」后进程保留、弹窗收起、标记仍在；再次退出弹窗能重新出现（证明 `NSApp.reply(false)` 生效）；点「仍要退出」进程退出且没有产生成功落盘。

静态推断与探针都覆盖不到、由这次点击实测揪出并已修复的三处缺陷：

1. `ContentView` 用 `NSApp.delegate as? AppDelegate` 注入失败——`@NSApplicationDelegateAdaptor` 装进 NSApp 的是转发代理，类型转换不成立，退出时 `appState` 为 nil，直接放行且**连退出前保存都没执行**。改为由属性包装把 `AppDelegate` 直接传进 `ContentView`。
2. `AppState.resolveTermination` 同样依赖该转换，`NSApp.reply` 从未调用，点「取消」后进程卡在 `.terminateLater`、后续退出全部无响应。改为注入 weak delegate 引用。
3. SwiftUI 在 alert 按钮 action 之后会把 `isPresented` 置 false，「重试」仍失败时弹窗消失但退出流程仍挂起，用户看不到出口。改为在下一个 runloop 重新立起弹窗（`retrySave` / `retryTerminationSave` 共用）。

另给 GUI 补上 `POSTME_DATA_DIR`（CLI 早已有）：GUI 的 Foundation 不跟随 `HOME` 环境变量，首次实测因此把空 `.postme.lock` 写进了真实数据目录（已清理、真实目录恢复原状）。验证全程改走该变量隔离。

**补充实测（同日，沙箱审批恢复后）**：「重试」在故障仍在时点下去，弹窗保持、进程存活；删掉挡路的 `history.json` 目录后再点「重试」，三份 JSON 全部落盘并放行退出。CLI 写入（`project create FromCLI`）后把 postme 失焦（AX 激活 Finder）再切回，侧栏项目选择器由「默认项目」变为「FromCLI」——干净状态自动重载生效，未弹冲突提示。

**全量回归（CI）**：新增 `.github/workflows/swift-tests.yml`（macOS runner：`swift build` + `swift test`）。推送后 run `42610903196` 通过：**431 tests, 8 skipped, 0 failures**（约 42 秒）。8 项跳过 = 7 项 `GUILanguageRenderTests`（需要屏幕录制权限，按设计 opt-in，本机同样跑不了）+ 1 项 `testTallWindowGivesExtraHeightToResponse`（runner 可用高度只有 622，800/1100 落到同一高度）。首轮 CI 的 2 个失败正是 `SplitLayoutTests` 在本机 832 高、CI 622 高之间的环境差异——已改为屏幕高度不足时跳过「明显大于一半」与「拉高窗口」断言，不再把环境限制误报成回归。

**冲突三按钮（2026-11-09 补测）**：先把 `workspace.json` 预建成目录，让首次防抖保存失败、`lastCommittedGeneration` 追不平（GUI 保持「有未落盘编辑」）；再删掉挡路目录，让 CLI 写入 `FromExternal`。切回 GUI 后因指纹变化 + 有草稿，弹出冲突三按钮（标题「工作区已在别处修改」，正文点名 `workspace.json` 并说明重载会放弃编辑）。逐项点过：「重新检查」后冲突仍在、弹窗保持；「保留我的改动」只收起弹窗、工具栏标记保留、磁盘上的 CLI 项目未被覆盖；点工具栏标记可重新打开；「重载并放弃我的编辑」后标记消失、侧栏出现 `FromExternal`。

这次补测又暴露一个 UI 缺陷：`.alert(isPresented:presenting:)` 在 `presenting` 变化、`isPresented` 仍为 true 时只会 dismiss 旧弹窗、不会重新 present——「保存失败」弹窗开着时切到「工作区冲突」会直接消失。已统一改为先置 false、下一个 runloop 再置 true（`AppState.presentSaveIssue`），并回归了退出弹窗的三按钮与取消路径。**GUI 侧的保存失败 / 冲突 / 退出三条路径至此全部经过真实 AX 点击验证。**
