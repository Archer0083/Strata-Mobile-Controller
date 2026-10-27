# 界面功能说明

本文逐张说明仓库中 `assets/screenshots/` 下的全部 **25 张**截图。所有截图均取自 v0.0.10 真机运行（Android，浅色与深色主题），未做修饰。全部截图已统一裁剪为 **1216 × 2688** 标准手机尺寸。

> 截图按**使用逻辑顺序**编排，浅色与深色主题**分组呈现、不混排**。

---

## 一、连接配置

| 文件 | 界面 | 说明 |
|---|---|---|
| `connection-01-light.jpg` | 编辑连接 | 填写配置名称、主机地址、端口、API Key。内网 / WireGuard 网段地址会提示「推荐经隧道访问」。点击「测试连接」校验并显示当前模型。 |
| `connection-02-light-success.jpg` | 编辑连接 · 测试成功 | 连接成功后显示绿色成功提示与当前模型名。 |

**地址提示**：主机地址字段会识别内网 / WireGuard 网段地址并给出「推荐经隧道访问」的提示。手机无法访问主机上的 `127.0.0.1`，必须使用可达的地址。

---

## 二、对话（Chat）

| 文件 | 界面 | 说明 |
|---|---|---|
| `chat-05-light-empty-state.jpg` | 对话 · 空状态 | 尚未开始对话时的引导页，说明可在此处新建会话或恢复历史会话。 |
| `chat-02-light-long-answer.jpg` | 对话 · 浅色 · 长回答 | 长篇回答的完整渲染效果。Markdown 表格、列表、代码块在窄屏上自动换行而不横向溢出。 |
| `chat-03-light-image-thinking.jpg` | 对话 · 浅色 · 图片 + 思考 | 模型的思考过程以独立区块呈现，可折叠展开。正文与思考内容视觉上分开，不会混在一起。 |
| `chat-04-light-markdown.jpg` | 对话 · 浅色 · Markdown | Markdown 渲染细节：标题层级、引用块、行内代码、加粗与链接。 |

**流式输出**：回答按 token 逐段到达，界面实时刷新，并显示当前 tok/s 与已用 token 总数。思考强度可按消息设置为 `none` / `low` / `medium` / `high`。

---

## 三、会话管理

| 文件 | 界面 | 说明 |
|---|---|---|
| `drawer-01-light.jpg` | 会话抽屉 | 侧边抽屉列出全部会话，按主机分组，支持置顶 / 改名 / 删除。 |
| `session-data-01-light.jpg` | 会话数据 | 展示 App 本地存储的全部内容（会话、附件、导出文件），可查看与清理。 |

---

## 四、导出与分享

| 文件 | 界面 | 说明 |
|---|---|---|
| `export-01-light-format-sheet.jpg` | 会话操作面板 · 四格式导出 | 弹层标题为「会话操作」，首项是「导出当前会话」，可从 `.md` / `.json` / `.html` / `.pdf` **四种格式**中选择。导出的是**整个会话的对话内容**。 |
| `export-03-light-screenshot-share.jpg` | 单条消息 · 一键生成长截图分享 | 任意一条**单独消息**（模型回复或用户提问）渲染成长截图后调起系统分享面板，含截图缩略图与「编辑」按钮，可先调整再分享。超长内容自动分片为多张连续编号的图片。 |
| `export-02-dark-share-md.jpg` | 文件分享（Markdown） | 导出为 `.md` 文件后调起系统分享面板（微信 / 文件管理 / 其他应用）。文件按会话内容命名。 |
| `import-01-light-preview.jpg` | 导入预览 | 导入前自动识别单个会话还是整包会话，并在写入前给出预览（含消息条数与时间范围）。 |

**两条独立的分享路径**：

| 路径 | 分享对象 | 适用场景 |
|---|---|---|
| **单条回复一键截图** | 一条回复的渲染图 | 把某段结论直接发给别人，不必导出整个会话 |
| **整会话四格式导出** | `.md` / `.json` / `.html` / `.pdf` | 归档、备份、迁移 |

**已知限制**：直接分享图片依赖厂商分享面板实现，跨机型不稳定。App 会如实提示失败，退路是导出 `.md` 后分享文件——该方式在各设备上均可用。

---

## 五、监控（Monitor）

| 文件 | 界面 | 说明 |
|---|---|---|
| `monitor-02-light.jpg` | 监控 · 浅色 | 监控仪表盘（浅色主题）。上半部分是模型状态与速度折线图，下半部分是硬件指标卡片。 |
| `monitor-01-dark.jpg` | 监控 · 深色 | 同一页面在深色主题下的呈现，信息与浅色版完全一致。 |

**指标说明**：

- **Model state**：模型状态徽章（Idle / Reading / Generating / Queued / Error），配色与引擎自带 WebUI 一致
- **Speed**：decode 与 prefill 的 tok/s 折线，两条线独立绘制
- **GPU load / VRAM**：GPU 负载百分比与显存占用 / 总量
- **GPU temp / Power**：显卡温度与整机功耗
- **PCIe / CPU**：PCIe 链路规格（如 Gen4 x16）与 CPU 占用、核心线程数
- **Disk read / Disk write**：磁盘读写速率，单位 MB/s
- **Context fill**：上下文占用比例（已用 / 总容量）
- **Experts / VRAM / System temperature / RAM / KV cache**：引擎进程级的内存与温度明细，含 KV 缓存命中占用
- **Recent requests**：近期请求列表，含时间、状态、请求 token 数与耗时
- **Since start**：自引擎启动以来的累计请求数、prompt token 数、输出 token 数

**与 WebUI 对齐**：布局与信息层级对齐引擎自带 Web 界面，同样的状态徽章、同一套指标、同一套折线配色——确保手机上读到的信息与桌面上读到的一致。

---

## 六、引擎控制（Control）

| 文件 | 界面 | 说明 |
|---|---|---|
| `control-01-light-loaded.jpg` | 控制 · 引擎已加载 | 引擎运行状态卡片：模型名、加载状态徽章、加载 / 卸载按钮。 |
| `control-02-light-models-context.jpg` | 控制 · 模型与上下文 | 已安装模型列表与上下文长度设置（可直接输入，或用 8K/16K/32K/64K/128K/256K 快捷键）。设置写入主机运行配置，**需重启主机后生效**，界面会明确提示。 |
| `control-03-light-unloaded.jpg` | 控制 · 未加载状态 | 模型未加载时的状态。此时 Load / Unload 按钮因 busy 状态而不可用，界面给出说明。 |
| `control-04-light-loaded.jpg` | 控制 · 加载完成 | 模型加载完成后的状态，徽章变为绿色 Loaded，并显示「主机已开启自动加载：首次请求会自动拉起模型」。 |
| `control-05-light-unload-confirm.jpg` | 控制 · 卸载确认 | 卸载前弹出的确认对话框，说明卸载会停止当前模型、进行中的请求将被断开，并提供「等待进行中的请求完成（最长 120s）」选项。 |

**降级行为**：若主机版本不支持 `/models/installed`（返回 404），「已安装模型」区域会明确说明原因并降级为只显示当前服务的模型，其余功能照常可用。

---

## 七、设置、指南与关于

| 文件 | 界面 | 说明 |
|---|---|---|
| `settings-01-light.jpg` | 设置 · 浅色 | 设置总览：外观主题、连接管理、帮助与连接指南、会话数据、开发者信息入口。 |
| `guide-01-light.jpg` | App 内连接指南 | 首次配置时的图文指引：两端 WireGuard 配置、常见错误、各页面用途。可从「设置 → 帮助 → 连接指南」或连接页右上角 `?` 进入。 |
| `about-02-light-engine.jpg` | 关于 · 浅色 | 引擎信息卡：引擎版本、模型、设备与后端等运行参数。 |

关于页共三张卡：**引擎**、**硬件**、**API**。

**API Key 存储**：API Key 存于 Android Keystore，不写入 shared preferences、不写入会话数据库、不会出现在任何导出文件中。

---

## 八、深色主题一览

| 文件 | 界面 | 说明 |
|---|---|---|
| `chat-01-dark-image-message.jpg` | 对话 · 深色 · 图片消息 | 发送带图片的消息。图片随会话持久化，重启 App 后仍可查看。顶部状态条显示当前连接的主机地址与在线状态。 |
| `monitor-01-dark.jpg` | 监控 · 深色 | 见第五章。 |
| `settings-02-dark.jpg` | 设置 · 深色 | 与浅色版信息层级完全一致。 |
| `about-01-dark-engine.jpg` | 关于 · 深色 | 引擎信息卡，与浅色版同构。 |
| `export-02-dark-share-md.jpg` | 分享面板 · 深色 | 系统分享面板叠在浅色 App 之上的实际呈现。 |

**浅色 / 深色主题**：跟随系统或手动指定，两套主题在所有页面保持一致的信息层级。

**统一按钮逻辑**：对话页的操作按钮（导出、分享、删除、重命名、置顶）沿用引擎自带 WebUI 对话栏的交互设计，减少学习成本。

---

## 九、截图清单速查

```text
connection-01-light.jpg              编辑连接
connection-02-light-success.jpg      编辑连接 · 测试成功
chat-05-light-empty-state.jpg        对话 · 空状态
chat-02-light-long-answer.jpg        对话 · 浅色 · 长回答
chat-03-light-image-thinking.jpg     对话 · 浅色 · 图片与思考
chat-04-light-markdown.jpg           对话 · 浅色 · Markdown
drawer-01-light.jpg                  会话抽屉
session-data-01-light.jpg            会话数据
export-01-light-format-sheet.jpg     会话操作 · 四格式导出
export-03-light-screenshot-share.jpg 单条回复 · 一键生成截图分享
export-02-dark-share-md.jpg          文件分享（Markdown）
import-01-light-preview.jpg          导入预览
monitor-02-light.jpg                 监控 · 浅色
monitor-01-dark.jpg                  监控 · 深色
control-01-light-loaded.jpg          控制 · 引擎已加载
control-02-light-models-context.jpg  控制 · 模型与上下文
control-03-light-unloaded.jpg        控制 · 未加载
control-04-light-loaded.jpg          控制 · 加载完成
control-05-light-unload-confirm.jpg  控制 · 卸载确认
settings-01-light.jpg                设置 · 浅色
settings-02-dark.jpg                 设置 · 深色
guide-01-light.jpg                   App 内连接指南
about-02-light-engine.jpg            关于 · 浅色
about-01-dark-engine.jpg             关于 · 深色
chat-01-dark-image-message.jpg       对话 · 深色 · 图片消息
```

---

## 十、关于这些截图的说明

- 全部截自 **v0.0.10** 真机运行，未做修饰或拼接。
- 全部截图统一裁剪为 **1216 × 2688**，与标准手机截图等高。
- 界面文案目前**仅有中文**（国际化在路线图中）。
- 截图中的主机地址为内网 / WireGuard 虚拟网段示例，API Key 在界面上以圆点遮挡。
- 已剔除内容重复的两张截图（旧 `14-connection-edit` 与旧 `26-monitor-dark-full`），
  原因分别与「编辑连接 · 测试成功」和「监控 · 浅色」重复。
- 若某处界面与当前版本不符，以 `CHANGELOG.md` 与 Releases 中的最新 APK 为准。
