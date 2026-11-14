---
name: postme
description: 使用 Postme CLI 管理本地 API 工作区中的项目、文件夹、请求、环境、历史和导入导出。用户要求操作 Postme、Postme 项目或请求集合时使用；普通 HTTP 调用或修改 Postme 源码不适用。
---

# Postme CLI

Postme 是 macOS API 工作区。CLI 与 GUI 共用数据；默认目录为 `~/Library/Application Support/postme/`，`--data-dir <目录>` 优先于 `POSTME_DATA_DIR`。先使用 `command -v postme` 和 `postme --help` 核对当前环境及版本能力；命令不存在时说明情况，不要假定安装路径或擅自安装。

## 命令与选择器

用 `--json` 取得机器可读输出。项目和环境可用准确名称或 UUID；名称不唯一时使用 UUID。请求使用 `postme --json request list` 输出的集合节点 `id`，不是其中的 `requestID`。

- 项目：`project list|create <名称>|rename <项目> <新名称>|use <项目>|delete <项目> --yes`。
- 请求：`request list [--project <项目>]`、`request show <请求UUID>`、`request create <JSON文件|-> [--project <项目>] [--name <名称>] [--folder <文件夹UUID>]`、`request update <请求UUID> <JSON文件|-> [--name <名称>] [--folder <文件夹UUID>|root]`、`request delete <请求UUID> --yes`。
- 文件夹：`folder list [--project <项目>]`、`folder create <名称> [--project <项目>] [--in <文件夹UUID>]`、`folder rename <文件夹UUID> <新名称>`、`folder delete <文件夹UUID> --yes`。`folder list --json` 输出的 `id` 就是文件夹 UUID，`path` 是含自身的层级路径，`requestCount` 统计该文件夹（含子文件夹）里的请求；`folder delete` 连同整个子树一起删。
- 编辑请求：`create` / `update` 从文件或标准输入（`-`）读一份完整的 `APIRequest` JSON；也接受 `request show <UUID> --json` 的完整输出（取其 `request` 对象与顶层 `name`），所以 `show` → 改 → `update` 可直接闭环。名称优先级 `--name` > JSON 的 `name` > 请求自带名；`update` 不给名称时保留原名。节点 UUID 与请求 UUID 都保持不变，已打开的页签归属不失效。缺少 `url` / `method` / `headers` / `bodyKind` 的输入会以退出码 2 拒绝，不会静默写出空请求。`create` 未指定 `--project` 时落在当前活动项目；`--yes` 只用于删除与清空，编辑不需要。
- 归属：`--folder <UUID>` 在 create 时把请求放进该文件夹、在 update 时把请求移过去；`--folder root`（或 `-`）移回项目根。不带 `--folder` 时 create 落项目根、update 保持原位置。目标文件夹不存在会报错，不会像 GUI 那样兜底建到根目录；`folder create --in` 同理。
- 环境：`environment list|create <名称>|use <环境>|deactivate|set <环境> <键> <值>|unset <环境> <键>|delete <环境> --yes`；`env` 是 `environment` 的别名。
- 历史：`history list [--limit <正整数>]`（默认 50 条）、`history clear --yes`。
- 导入：`import openapi <文件|-> [--project <项目> | --new-project <名称>]`；`import postman <文件|->`；`import curl <文件|-> [--project <项目> | --new-project <名称>]`。`-` 从标准输入读取。OpenAPI 默认新建项目，指定 `--project` 时导入为其下文件夹；Postman 始终新建项目；cURL 默认导入当前项目根目录。`--project` 与 `--new-project` 不能同时使用。
- 导出：`export postman <项目> [--output <文件|->]`，省略输出路径或使用 `-` 时输出 Postman JSON 到标准输出。

不要把 `--yes` 当成用户授权；用户明确要求删除或清空时才对该操作使用。导入和导出按用户给定目标执行，导出到现有文件可能覆盖它。不要自行清空历史或调整当前项目、环境来完成只读任务。

## 限制与处理

当前已核对的 CLI 不能发送 HTTP 请求，但可以用 `request create` / `request update` 创建和编辑单条请求、用 `folder` 命令管理文件夹（见上）；导入文件仍可批量创建请求。若用户要求发送请求，说明限制；仅在用户同意替代方式时使用其他工具，不要声称 Postme 已发送。未来版本以实际 `--help` 为准。

写操作与 GUI 共用短时锁和磁盘指纹检查：退出码 `3` 表示工作区忙或磁盘发生冲突，本次未写入；在重新读取最新状态后可重试，反复冲突则停止并报告。退出码 `0` 成功、`1` 操作失败、`2` 参数错误。只读操作可能跨多个文件读到非原子快照。

`request show`、JSON 格式的环境列表、导入文件和导出集合可能包含令牌、密码或其他敏感值；仅在任务需要时读取或展示，报告时避免无关泄露。测试写操作时使用独立的 `--data-dir`，不要触碰真实工作区。
