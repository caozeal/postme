# postme × ApiPost 功能差距与路线图

> 对比时间：2026-10-23
> 对比对象：ApiPost v7（官方文档：<https://wiki.apipost.cn/docs/http/debug/>）
> 对比基线：postme `main` 分支 + 当前工作区（SSE / 大模型输出 / 多页签 / 项目隔离已就绪）

## 1. 结论

postme 已经覆盖了「日常接口调试」的主干：请求构造、环境变量、项目与目录、多页签、
历史、cURL / Postman 互通、SSE 流式响应，以及 ApiPost 没有的「大模型输出拼接」。
2026-10-23 已补上五个高频缺口：

1. **认证**（P0）——Bearer / Basic / API Key 页签；
2. **文件上传**（P1-2）——multipart 文件字段 + binary Body；
3. **响应取证**（P1-3）——正文查找 + 保存响应示例；
4. **Cookie**（P1-4）——手动 Cookie 行 + 会话内 Jar（默认关闭）；
5. **RESTful 路径变量**（P1-6）——URL 里的 `{id}` / `:id` 自动进参数表。

剩下的主要是**规模化能力**：HAR 导入、项目级配置、代理 / 客户端证书。
OpenAPI / Swagger 导入已完成；代码生成**暂不排期**；Mock / 自动化 / 多协议仍不做。
按「频次 × 痛感 ÷ 成本 × 与轻量定位的契合度」继续排序。

## 2. 功能对照

图例：✅ 已有 · 🟡 部分/有替代路径 · ❌ 缺失 · 🚫 明确不做

### 2.1 请求构造

| 能力 | ApiPost v7 | postme | 差距说明 |
|---|---|---|---|
| HTTP 方法 | ✅ | ✅ | GET/POST/PUT/PATCH/DELETE/HEAD/OPTIONS |
| Query / Headers 逐行启停 | ✅ | ✅ | |
| RESTful 路径变量（`{id}` / `:id`） | ✅ | ✅ | URL 占位符自动同步到 Params，值按路径段编码 |
| Body：none | ✅ | ✅ | |
| Body：JSON / raw（xml、js、plain、html） | ✅ | ✅ | raw 可自定义 Content-Type |
| Body：urlencoded | ✅ | ✅ | |
| Body：form-data 文本字段 | ✅ | ✅ | |
| Body：form-data 文件字段 | ✅ | ✅ | multipart 文件字段；cURL / Postman 保留路径 |
| Body：binary | ✅ | ✅ | 本地文件原样作为正文，单文件上限 64 MB |
| Body：GraphQL（query / variables 分栏） | ✅ | 🟡 | 只能手写等价 JSON；Postman 导入会还原成 JSON |
| 认证（Bearer/Basic/Digest/OAuth1/OAuth2/Hawk/AWS/NTLM/EdgeGrid） | ✅ | 🟡 | Bearer / Basic / API Key 已支持；其余类型仍缺失 |
| Cookie（key-value 编辑） | ✅ | ✅ | 手动行 + 会话 Jar（默认关闭，退出即清空） |
| 前置脚本 / 连接数据库 | ✅ | 🚫 | 与「零依赖、轻量、本地」定位冲突（README 已声明不做） |
| 后置脚本 / 断言 / 变量提取 | ✅ | 🚫 | 同上；轻量「从响应提取变量」可作为未来折中 |
| 超时 / 跟随重定向 / 忽略证书 | ✅ | ✅ | 全局设置 |
| 代理 / 客户端证书 / 自定义 CA | ✅ | ❌ | 企业内网调试会用到 |
| 请求级覆盖全局设置 | ✅ | ❌ | 目前只能改全局设置再改回来 |

### 2.2 响应

| 能力 | ApiPost v7 | postme | 差距说明 |
|---|---|---|---|
| 状态码 / 响应头 / 正文 | ✅ | ✅ | |
| 分阶段耗时 | ✅ | ✅ | DNS/TCP/TLS/TTFB/下载 |
| JSON 美化 / 压缩 / 语法高亮 / 树形 | ✅ | ✅ | 格式化分页即树形（保留键顺序），另有压缩文本 |
| SSE 实时接收 | ✅ | ✅ | 事件分页 + 自动滚动 + 2000 条环形缓冲 |
| 大模型增量拼接 | ❌ | ✅ | postme 独有：OpenAI / Anthropic / LangChain / 自定义路径 |
| 响应体搜索 | ✅ | ✅ | 系统查找条：匹配数 + 上一个 / 下一个（⌥⌘F） |
| 保存响应为示例 | ✅ | ✅ | 按请求保存，正文上限 2 MB，存 `examples.json` |
| 响应对比 | ✅ | ❌ | |
| 二进制响应预览（图片等） | ✅ | 🟡 | 只显示「二进制，N KB」占位 |

### 2.3 组织与协作

| 能力 | ApiPost v7 | postme | 差距说明 |
|---|---|---|---|
| 项目 / 文件夹 / 请求树 | ✅ | ✅ | 切项目清空编辑器，历史按项目隔离 |
| 多页签编辑 | ✅ | ✅ | 每页签独立草稿、响应、请求分页 |
| 请求搜索 | ✅ | ✅ | 当前项目内按名称 / URL |
| 历史记录 | ✅ | ✅ | 每项目最多 200 条，可恢复到编辑器 |
| 环境变量 | ✅ | ✅ | 多环境切换，内置 4 个动态变量 |
| 项目级 / 全局变量 | ✅ | ❌ | 目前环境是全局的（2026-10-16 明确保持全局） |
| 变量提取回写环境 | ✅ | ❌ | 依赖后置脚本能力 |
| Postman Collection v2.1 导入导出 | ✅ | ✅ | 保留 bearer/basic/apikey 认证语义 |
| cURL 导入 / 导出 | ✅ | ✅ | 导入支持多命令与 `--next` |
| OpenAPI / Swagger 导入导出 | ✅ | ❌ | 从接口文档批量生成请求集合 |
| HAR 导入 | ✅ | ❌ | 从浏览器 DevTools 直接复现请求 |
| ApiPost 原生格式导入 | ✅ | ❌ | 目前只能走 Postman v2.1 中转 |
| 代码生成（Python/JS/Go/Java/PHP…） | ✅ | 🟡 | 只有 cURL |
| API 文档生成 / 分享 | ✅ | 🚫 | 定位是本地调试器，不是文档平台 |
| Mock 服务 | ✅ | 🚫 | 需要常驻服务，与单进程轻量定位冲突 |
| 自动化测试 / CI | ✅ | 🚫 | 需要脚本与测试编排，README 已声明不做 |
| 团队协作 / 账号 / 云同步 | ✅ | 🚫 | 数据只在本机，是产品前提 |
| WebSocket / gRPC / TCP / UDP / 数据库 | ✅ | ❌ | 目前只有 HTTP（含 SSE） |
| 简体中文 / English | ✅ | ✅ | 跟随系统或手动切换 |

## 3. 优先级模型

排序不看「ApiPost 有而我们没有」的数量，而看四个因子：

- **频次**：日常调试一天会用几次；
- **痛感**：缺了它是「多敲几行」还是「根本做不了」；
- **成本**：模型、UI、持久化、导入导出、测试的连带改动；
- **契合度**：是否仍符合「原生、零依赖、单进程、数据不出本机」。

### P0 —— 已完成（2026-10-23）

| # | 功能 | 频次 | 痛感 | 成本 | 结论 |
|---|---|---|---|---|---|
| 1 | **认证页签**（Bearer / Basic / API Key） | 极高 | 中高 | 小 | 每天都要用；改动集中在请求模型 + 一处注入点 |

### P1 —— 已完成（2026-10-23）

| # | 功能 | 理由 | 预估成本 | 状态 |
|---|---|---|---|---|
| 2 | 文件上传（form-data 文件字段 + binary Body） | 上传接口原本**完全无法调试**，是硬缺口 | 中 | ✅ 2026-10-23 |
| 3 | 响应体搜索 + 保存响应为示例 | 大响应定位字段、沉淀预期返回；纯本地能力 | 小 | ✅ 2026-10-23 |
| 4 | Cookie 管理（会话内 Cookie Jar + 手动 Cookie 表） | 登录态接口的日常痛点；明确「默认不带、显式开启」 | 中 | ✅ 2026-10-23 |
| 6 | RESTful 路径变量（`{id}` / `:id`） | URL 可读性与参数表联动 | 小 | ✅ 2026-10-23 |

### 暂不排期（用户明确不做）

| # | 功能 | 原因 |
|---|---|---|
| 5 | 代码生成（Python / JavaScript / Go / Java） | 用户 2026-10-23 明确「暂不考虑，不放到下一步」；当前不排期。 |

### P2 —— 结构性能力

| # | 功能 | 理由 | 预估成本 |
|---|---|---|---|
| 7 | OpenAPI / Swagger 导入（3.x + 2.0 JSON） | ✅ 2026-10-23；范围见 §6，不做导出 / 文档 / Mock / 双向同步 | 大 |
| 8 | HAR 导入 | 浏览器里复现问题的最短路径 | 中 |
| 9 | GraphQL 专用 Body（query / variables 分栏） | 手写 JSON 容易漏转义 | 小中 |
| 10 | 项目级 / 全局 Header 与变量 | 减少重复；但会推翻「环境全局」的既有决定，需先确认 | 中 |
| 11 | 代理 / 客户端证书 / 自定义 CA | 企业内网与抓包场景 | 中 |
| 12 | 请求级设置覆盖（超时 / 重定向 / 证书） | 单请求调试特殊服务时不必改全局再改回 | 小 |
| 13 | 轻量变量提取（无脚本，按 JSON 路径取响应字段写入环境） | 在「不做脚本」的前提下拿到 80% 的收益 | 中 |

### P3 —— 明确不做（保持产品边界）

- 前置 / 后置 JavaScript 脚本、断言、数据库连接；
- Mock 服务、自动化测试编排、CI 集成；
- API 文档生成与分享、团队协作、账号、云同步；
- gRPC / TCP / UDP / 数据库协议。

这些能力都要求常驻服务、脚本运行时或账号体系，与「单进程、零依赖、数据只在本机」
直接冲突。需要时应继续用 ApiPost，而不是把 postme 做成第二个 ApiPost。

## 4. P0 设计：认证页签

> 状态：**已实现**（2026-10-23）。代码见 `Sources/Postme/Views/AuthPane.swift`、
> `Services/AuthApplier.swift`、`Models/RequestAuth.swift`。

### 4.1 目标

在请求编辑区新增「认证」分页，用 ApiPost 的方式配置认证，发送时自动注入等价的
Header / Query 参数；同时让 cURL 导出、历史恢复、持久化、Postman 导出看到同一份结果。

### 4.2 范围

本次只做**静态可表达**的三种认证：

| 类型 | 注入结果 |
|---|---|
| Bearer Token | `Authorization: Bearer <token>` |
| Basic Auth | `Authorization: Basic base64(username:password)` |
| API Key | 指定名称的 Header，或同名 Query 参数 |

不做 OAuth 1.0/2.0、Digest、AWS Signature 等需要握手或动态签名的类型——
它们无法在「一次静态请求」里表达，后续如做需要独立的令牌获取与缓存机制。

### 4.3 交互

- 分页顺序：`Headers → Params → Body → 认证`（追加在最后，不改变现有肌肉记忆）。
- 类型选择用下拉菜单：`无认证 / Bearer Token / Basic Auth / API Key`。
- 字段按类型切换：
  - Bearer：Token（默认掩码，可点眼睛显示）；
  - Basic：用户名、密码（密码掩码）；
  - API Key：Key 名、Value、位置（Header / Query）。
- 所有字段都支持 `{{变量}}`，未定义变量沿用现有「原样发出 + 顶部横幅提示」策略。
- 页脚提示两条规则：
  1. 认证在发送前注入，`{{变量}}` 按当前环境替换；
  2. 已有同名 Header / 参数时以手写的那一条为准（不覆盖、不重复）。

### 4.4 注入规则（必须可预测）

1. **变量替换先于注入**：先解析认证字段里的 `{{var}}`，再物化成 Header/Query。
2. **显式优先**：若请求里已有启用的同名 Header（大小写不敏感）或同名 Query 参数，
   认证不写入；禁用的行不算「已有」。
3. **空值不注入**：Bearer token 为空、Basic 用户名与密码都为空、API Key 名为空时，
   什么都不加——绝不发出 `Authorization: Bearer ` 这种假认证。
4. **只注入一次**：注入发生在 `AppState.resolve` 的唯一出口，发送、最终 URL 预览、
   cURL 导出共用同一条路径，不会出现「界面显示有、实际没发」。
5. **不改原始草稿**：注入只作用于解析后的副本；页签、历史、保存的请求里仍是认证配置本身，
   因此修改 token 不需要逐条改请求。

### 4.5 连带影响

| 链路 | 行为 |
|---|---|
| 发送 | 自动带上认证 Header / Query |
| 最终 URL 预览 | API Key 在 Query 时能看到替换后的值 |
| 复制为 cURL | 命令里出现实际注入的 `-H 'Authorization: …'` |
| 历史 / 恢复 | 保存的是认证配置，恢复后仍可在「认证」页签里改 |
| 持久化 | `APIRequest.auth` 容错解码，旧文件缺字段 = 无认证 |
| Postman 导出 | 按 Postman 的 `auth` 结构导出，`{{变量}}` 原样保留；再导入时物化为等效 Header |
| Postman / cURL 导入 | 仍物化为 Header，功能等价；结构转换列为后续项 |

### 4.6 验收标准

- Bearer / Basic / API Key（Header、Query）四类注入结果正确；
- 显式同名 Header / Query 不被覆盖，且不产生重复行；
- 空凭据不注入；
- 认证字段中的 `{{变量}}` 被替换，未定义变量进入未解析列表；
- `⌘S` 保存、重启、历史恢复后认证配置不丢；
- 旧 workspace / tabs 文件（无 `auth` 键）正常载入；
- 中英文案齐全，`make app` 产物可运行。

## 5. 后续里程碑建议

### 已完成（2026-10-23）

1. **P0 认证页签**：Bearer / Basic / API Key，变量替换、显式优先、Postman 结构导出。
2. **P1-2 文件上传**：multipart 文件字段 + binary Body；单文件 64 MB 上限；
   cURL / Postman 导入导出保留路径；`-F key=@file` / `--data-binary @file` / `-T file` 可导入。
3. **P1-3 响应取证**：系统查找条（⌥⌘F）+ 响应示例（按请求归属，`examples.json`，
   正文 2 MB 上限，支持查看 / 复制 / 删除）。
4. **P1-4 Cookie**：手动 Cookie 行 + 会话内 Jar；默认关闭；按域 / 路径 / Secure / 过期回带；
   显式 `Cookie` 头优先，手动行覆盖同名 Jar Cookie。
5. **P1-6 RESTful 路径变量**：URL 里的 `{id}` / `:id` 自动同步到 Params 的路径参数区；
   值支持 `{{变量}}`，按单个路径段编码；cURL / Postman 导入导出保留占位符与值。
6. **侧栏拖拽整理**（2026-10-23 追加）：请求 / 文件夹同级排序、拖入文件夹；
   文件夹不能拖进自己的子树，失败不改树。
7. **P2-7 OpenAPI / Swagger 导入**（2026-10-23）：Swagger 2.0 + OpenAPI 3.x **JSON** →
   可运行请求；tags → 文件夹、参数 / body / 认证 / servers → `baseUrl` 环境；
   预览 sheet 支持新建项目 / 并入当前项目；不做响应文档、Mock、导出、双向同步。

### 下一步

1. **P2-8 HAR 导入**：浏览器里复现问题的最短路径。
2. **P2-9 GraphQL 专用 Body**：query / variables 分栏，减少手写 JSON 的转义错误。
3. **P2-10 项目级 / 全局 Header 与变量**：先确认是否推翻「环境全局」的既有决定。

> 代码生成不在「下一步」里，见上方「暂不排期」。

## 6. P2-7 OpenAPI 导入：范围与实现（已完成 2026-10-23）

### 6.1 ApiPost 的做法

ApiPost 的「手动导入」官方支持 **Swagger 2.0 / 3.0 的 JSON 文件**，并且：
- 可选择导入到已有项目 / 目录，而不是每次新建项目；
- Swagger 2.0 可选择是否把 `basePath` / `host` 拼进接口路径；
- 导入后路径、参数、响应结构基本完整保留，作为它的「API 设计 / 文档」数据源；
- 后续还能接文档、Mock、自动化测试、团队协作与代码生成。

换句话说，ApiPost 的 OpenAPI 导入不是一个独立功能，而是它整个 API 工作台的入口。

### 6.2 为什么不该全盘复刻

全盘复刻意味着：YAML、双向同步、Schema 可视化编辑器、响应文档、
Mock、测试用例、团队权限……这些都需要文档模型、编辑器和常驻服务，
与 postme「原生、零依赖、单进程、数据不出本机」的前提直接冲突。

对 postme 真正有价值的是 **80% 的那一步**：把一份 spec 变成一堆**能直接发**的请求，
省掉手工录入几百个接口。导入之后，项目树就是普通的 postme 项目，不承担「文档源」职责。

### 6.3 推荐 MVP（spec → 可运行请求）

**输入**
- **Swagger 2.0 / OpenAPI 3.0 / 3.1 JSON**，本地文件。
- 预览 sheet：显示项目名、接口数、目录数、警告；选择「新建项目（默认）」或「并入当前项目」。

**结构**
- `info.title` → 项目名；`tags[0]` → 文件夹；无 tag → 路径第一段；再兜底「未分组」。
- 请求名：`summary` > `operationId` > `METHOD /path`。

**地址与环境**
- 请求 URL 统一写成 `{{baseUrl}}` + path；创建一个环境（`baseUrl` = server URL）。
- OpenAPI 3：取 `servers[0].url`（支持 `variables` 默认值）；
- Swagger 2：取 `schemes[0]` + `host` + `basePath`；
- 多个 server / scheme：用第一个并警告，其余列在导入提示里。

**参数**
- path → 路径参数（复用 §4 的 `{id}` / `:id`）；query → Query；header → Headers；
  cookie → Cookie。
- 值优先级：`example` > `schema.example` > `schema.default` > 枚举首项 > 空。
- 必填参数启用；可选参数**默认禁用**，避免把一堆空参数发出去。

**请求体**
- `application/json` → JSON，示例优先，缺失时按 schema 生成骨架；
- `application/x-www-form-urlencoded` → 表单字段；
- `multipart/form-data` → 文本字段 + 文件字段（文件路径留空，等用户选）；
- 其它 content-type → Raw Text + 对应 Content-Type。
- 多 content-type：JSON > form > multipart > 第一个；其余记警告。

**认证**
- `http` bearer / basic、`apiKey` → 映射到认证页签，凭据留空（用户填）；
- `oauth2` / `openIdConnect` / digest / mTLS → 警告并跳过；
- operation 级 `security` 覆盖全局；`security: []` = 无认证。

**引用与 schema**
- 只解析文档内 `#/components/...` 的 `$ref`；外部引用警告并跳过；
- schema 骨架只处理 object / array / 基础类型、`example` / `default` / `enum`、
  `allOf` 合并、`oneOf` / `anyOf` 取第一个；循环引用有深度上限。

**导入提示**
- 不支持的认证、被跳过的 content-type、外部 `$ref`、额外 server、
  不支持的参数序列化（deepObject 等）、被跳过的响应定义，都要在预览里列出来，不静默丢。

### 6.4 明确不做的部分

- **YAML**：官方手动导入列表里也是 JSON；当前不做。若后续确实需要，宁可引入
  一个 YAML 解析库，也不要自己写半成品解析器。
- **OpenAPI 导出**：只做导入。
- **响应文档 / 响应示例导入**：首版跳过；以后可以接到 `examples.json`。
- **文档、Mock、自动化测试、团队协作、代码生成**：不在本功能范围内。
- **远程 URL 导入、外部 `$ref`、callbacks / links / webhooks、XML body、
  高级序列化**：后置。

### 6.5 已拍板（2026-10-23）

1. **Swagger 2.0 需要支持**：用户当前主要项目使用 2.0，已与 OpenAPI 3.x 一起实现。
2. **导入落点**：预览 sheet 里选「新建项目（默认）/ 并入当前项目」；并入时在当前项目
   根目录新建同名文件夹。
3. **响应定义**：跳过，只导入请求；以后需要再存成响应示例。

### 6.6 MVP 验收标准

- 一份 Swagger 2.0 或 OpenAPI 3.x JSON → 同名项目，tags 成文件夹，接口数量正确；
- path / query / header / cookie 参数进入对应页签，必填启用、可选禁用；
- JSON / form / multipart 请求体正确落位；
- `servers[0]` 生成 `baseUrl` 环境，请求能直接发出；
- bearer / basic / apiKey 映射到认证页签，其余认证有警告；
- 外部 `$ref`、额外 server、跳过内容都有可见提示；
- 只读本地文件，不联网；重复导入是新建项目，不做同步。

### 6.7 实现落点

- `Services/OpenAPICodec.swift`：JSON 解析、`$ref`、schema 骨架、参数 / body / 认证 / 环境映射；
- `Views/OpenAPIImportSheet.swift`：预览与落点选择；
- `AppState`：`beginOpenAPIImport` / `commitOpenAPIImport`，新建项目或并入当前项目，
  创建并启用 `baseUrl` 环境；
- `FileActions` + 菜单 `⌘⇧O`：本地 JSON 文件选择。
