# 界面功能说明

本文逐张说明仓库中 `assets/screenshots/` 下的全部 27 张截图。所有截图均取自 v0.0.10 真机运行（Android，浅色与深色主题），未做修饰。

---

## 一、对话（Chat）

| # | 文件 | 界面 | 说明 |
|---|---|---|---|
| 01 | `01-chat-dark-image-message.jpg` | 对话 · 深色 · 图片消息 | 发送带图片的消息。图片随会话持久化，重启 App 后仍可查看。顶部状态条显示当前连接的主机地址与在线状态。 |
| 02 | `02-chat-light-long-answer.jpg` | 对话 · 浅色 · 长回答 | 长篇回答的完整渲染效果。Markdown 表格、列表、代码块在窄屏上自动换行而不横向溢出。 |
| 03 | `03-chat-light-image-thinking.jpg` | 对话 · 浅色 · 图片 + 思考 | 模型的思考过程以独立区块呈现，可折叠展开。正文与思考内容视觉上分开，不会混在一起。 |
| 04 | `04-chat-dark-light-theme.jpg` | 对话 · 深色 · 手动切换浅色 | 主题可在设置中手动指定，或跟随系统。此图为在深色界面内切换到浅色后的即时状态。 |
| 09 | `09-chat-light-markdown.jpg` | 对话 · 浅色 · Markdown | Markdown 渲染细节：标题层级、引用块、行内代码、加粗与链接。 |
| 10 | `10-chat-empty-state.jpg` | 对话 · 空状态 | 尚未开始对话时的引导页，说明可在此处新建会话或恢复历史会话。 |

**流式输出**：回答按 token 逐段到达，界面实时刷新，并显示当前 tok/s 与已用 token 总数。思考强度可按消息设置为 `none` / `low` / `medium` / `high`。

---

## 二、监控（Monitor）

| # | 文件 | 界面 | 说明 |
|---|---|---|---|
| 07 | `07-monitor-dark.jpg` | 监控 · 深色 | 监控仪表盘（深色主题）。上半部分是模型状态与速度折线图，下半部分是硬件指标卡片。 |
| 26 | `26-monitor-dark-full.jpg` | 监控 · 深色 · 完整长图 | 同一页面的完整纵向截图，包含「近期请求」列表与「自引擎启动以来」的累计统计。 |
| 27 | `27-monitor-light.jpg` | 监控 · 浅色 | 浅色主题下的监控页，与深色版信息完全一致。 |

**指标说明**：

- **Model state**：模型状态徽章（Idle / Reading / Generating / Queued / Error），配色与引擎自带 WebUI 一致
- **Speed**：decode 与 prefill 的 tok/s 折线，两条线独立绘制
- **GPU load / VRAM**：GPU 负载百分比与显存占用 / 总量
- **GPU temp / Power**：显卡温度与整机功耗
- **PCIe / CPU**：PCIe 链路规格（如 Gen4 x16）与 CPU 占用、核心线程数
- **Disk read / Disk write**：磁盘读写速率，单位 MB/s
- **Context fill**：上下文占用比例（已用 / 总容量）
- **Experts / VRAM / System temperature / RAM / VRAM / KV cache**：引擎进程级的内存与温度明细，含 KV 缓存命中占用
- **Recent requests**：近期请求列表，含时间、状态、prompt / 请求 token 数、请求 token 数与耗时
- **Since start**：自引擎启动以来的累计请求数、prompt token 数、输出 token 数

**与 WebUI 对齐**：布局与信息层级对齐引擎自带 Web 界面，同样的状态徽章、同一套指标、同一套折线配色——确保手机上读到的信息与桌面上读到的一致。

---

## 三、控制（Control）

| # | 文件 | 界面 | 说明 |
|---|---|---|---|
| 11 | `11-control-engine-full.jpg` | 控制 · 引擎 | 引擎运行状态卡片：模型名、加载状态徽章、加载/卸载按钮。 |
| 12 | `12-control-models-context.jpg` | 控制 · 模型与上下文 | 已安装模型列表与上下文长度设置（可直接输入，或用 8K/16K/32K/64K/128K/256K 快捷键）。设置写入主机运行配置，**需重启主机后生效**，界面会明确提示。 |
| 20 | `20-control-unloaded.jpg` | 控制 · 未加载状态 | 模型未加载时的状态。此时 Load / Unload 按钮因 busy 状态而不可用，界面给出说明。 |
| 21 | `21-control-loaded.jpg` | 控制 · 已加载状态 | 模型加载完成后的状态，徽章变为绿色 Loaded，并显示「主机已开启自动加载：首次请求会自动拉起模型」。 |
| 22 | `22-control-unload-confirm.jpg` | 控制 · 卸载确认 | 卸载前弹出的确认对话框，说明卸载会停止当前模型、进行中的请求将被断开，并提供「等待进行中的请求完成（最长 120s）」选项。 |

**降级行为**：若主机版本不支持 `/models/installed`（返回 404），「已安装模型」区域会明确说明原因并降级为只显示当前服务的模型，其余功能照常可用。

---

## 四、关于（About）

| # | 文件 | 界面 | 说明 |
|---|---|---|---|
| 05 | `05-about-dark-engine.jpg` | 关于 · 深色 · 引擎 | 引擎信息卡：引擎版本、模型、设备与后端等运行参数。 |
| 13 | `13-about-light-engine.jpg` | 关于 · 浅色 · 引擎 | 同一页面在浅色主题下的呈现。 |

关于页共三张卡：**引擎**、**硬件**、**API**。

---

## 五、设置与会话数据

| # | 文件 | 界面 | 说明 |
|---|---|---|---|
| 06 | `06-settings-light.jpg` | 设置 | 设置总览：外观主题、连接管理、帮助与连接指南、会话数据、开发者信息入口。 |
| 17 | `17-session-data.jpg` | 会话数据 | 展示 App 本地存储的全部内容（会话、附件、导出文件），可查看与清理。 |

**API Key 存储**：API Key 存于 Android Keystore，不写入 shared preferences、不写入会话数据库、不会出现在任何导出文件中。

---

## 六、连接配置

| # | 文件 | 界面 | 说明 |
|---|---|---|---|
| 14 | `14-connection-edit.jpg` | 编辑连接 | 填写配置名称、主机地址、端口、API Key。点击「测试连接」校验并显示当前模型。 |
| 24 | `24-connection-edit-light-success.jpg` | 编辑连接 · 测试成功 | 连接成功后显示绿色成功提示与当前模型名。 |
| 25 | `25-connection-edit-light.jpg` | 编辑连接 · 浅色 | 浅色主题下的连接编辑页。 |
| 15 | `15-connection-guide.jpg` | App 内连接指南 | 首次配置时的图文指引：两端 WireGuard 配置、常见错误、各页面用途。可从「设置 → 帮助 → 连接指南」或连接页右上角 `?` 进入。 |

**地址提示**：主机地址字段会识别内网 / WireGuard 网段地址并给出「推荐经隧道访问」的提示。手机无法访问主机上的 `127.0.0.1`，必须使用可达的地址。

---

## 七、导入导出与分享

| # | 文件 | 界面 | 说明 |
|---|---|---|---|
| 16 | `16-export-share-md.jpg` | 导出分享（Markdown） | 导出为 `.md` 并调起系统分享面板。文件按会话内容命名。 |
| 18 | `18-export-format-sheet.jpg` | 导出格式选择 | 四种格式可选：`.md` / `.json` / `.html` / `.pdf`。 |
| 19 | `19-import-preview.jpg` | 导入预览 | 导入前自动识别单个会话还是整包会话，并在写入前给出预览。 |
| 08 | `08-conversation-drawer.jpg` | 会话抽屉 | 侧边抽屉列出全部会话，按主机分组，支持置顶 / 改名 / 删除。 |
| 23 | `23-share-screenshot-fallback.jpg` | 分享截图 · 失败提示 | **如实展示的限制**：部分机型上「直接分享截图」失败，App 给出明确提示并提供退路——导出为 `.md` 后分享文件在各设备上都可用。 |

---

## 八、界面与体验细节

| # | 文件 | 界面 | 说明 |
|---|---|---|---|
| 08 | `08-conversation-drawer.jpg` | 会话抽屉 | 见上。 |
| 04 | `04-chat-dark-light-theme.jpg` | 主题切换 | 见上。 |

**浅色 / 深色主题**：跟随系统或手动指定，两套主题在所有页面保持一致的信息层级。

**统一按钮逻辑**：对话页的操作按钮（导出、分享、删除、重命名、置顶）沿用引擎自带 WebUI 对话栏的交互设计，减少学习成本。

---

## 九、截图清单速查

```text
01-chat-dark-image-message.jpg      对话 · 深色 · 图片消息
02-chat-light-long-answer.jpg       对话 · 浅色 · 长回答
03-chat-light-image-thinking.jpg    对话 · 浅色 · 图片与思考
04-chat-dark-light-theme.jpg        对话 · 深色 · 主题切换
05-about-dark-engine.jpg            关于 · 深色 · 引擎
06-settings-light.jpg               设置总览
07-monitor-dark.jpg                 监控 · 深色
08-conversation-drawer.jpg          会话抽屉
09-chat-light-markdown.jpg          对话 · 浅色 · Markdown
10-chat-empty-state.jpg             对话 · 空状态
11-control-engine-full.jpg          控制 · 引擎状态
12-control-models-context.jpg       控制 · 模型与上下文
13-about-light-engine.jpg           关于 · 浅色 · 引擎
14-connection-edit.jpg              编辑连接
15-connection-guide.jpg             App 内连接指南
16-export-share-md.jpg              导出分享（Markdown）
17-session-data.jpg                 会话数据
18-export-format-sheet.jpg          导出格式选择
19-import-preview.jpg               导入预览
20-control-unloaded.jpg             控制 · 未加载
21-control-loaded.jpg               控制 · 已加载
22-control-unload-confirm.jpg       控制 · 卸载确认
23-share-screenshot-fallback.jpg    分享截图 · 失败提示
24-connection-edit-light-success.jpg 编辑连接 · 测试成功
25-connection-edit-light.jpg        编辑连接 · 浅色
26-monitor-dark-full.jpg            监控 · 深色 · 完整长图
27-monitor-light.jpg                监控 · 浅色
```

---

## 十、关于这些截图的说明

- 全部截自 **v0.0.10** 真机运行，未做修饰或拼接。
- 界面文案目前**仅有中文**（国际化在路线图中）。
- 截图中的主机地址为内网 / WireGuard 虚拟网段示例，API Key 在界面上以圆点遮挡。
- 若某处界面与当前版本不符，以 `CHANGELOG.md` 与 Releases 中的最新 APK 为准。
