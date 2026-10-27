# Mock Strata 服务（M1-3 / P2-3 / M2-10）

在没有真实 Strata 主机的情况下，为 App 与单测提供形态一致的假服务。**零第三方依赖**，Python 3.8+ 标准库运行。

## 启动

```bash
cd server-bridge/mock
python mock_strata.py                       # 127.0.0.1:8420，开发模式（不鉴权）
python mock_strata.py --api-key sk-mock-123 # 开启 Bearer 鉴权（测 401 路径）
python mock_strata.py --ttft 50             # 固定首字延迟 50s（验证 15s SSE 保活 ×3）
python mock_strata.py --api-monitor off     # 模拟真实 svc.api_monitor 默认关闭
python mock_strata.py --port 8080           # 对齐真实默认端口
```

| 参数 | 默认 | 说明 |
|---|---|---|
| `--host` | 127.0.0.1 | 真机联调时改 `0.0.0.0` |
| `--port` | 8420 | 真实 Strata 默认 8080 |
| `--api-key` | 空 | 空=不鉴权；非空=强制 Bearer |
| `--speed` | 0.04 | 流式分块间隔（秒） |
| `--ttft` | auto | auto=按档位（none 0.3s / low 1s / medium 2.5s / high 6s）；指定秒数用于验证保活 |
| `--api-monitor` | on | off=`/api/requests` 404（真实服务 `svc.api_monitor` 默认关闭） |

## 端点清单（M2-10 全量）

| 端点 | 方法 | 行为 |
|---|---|---|
| `/v1/chat/completions` | POST | OpenAI 兼容；`stream:true` 逐 3 字流式；`reasoning_effort: none\|low\|medium\|high` 按请求生效；请求体带 `strata_mcp:true` 时流内插 `limit→start→call→result` 工具事件（挂 chunk 顶层 `strata_mcp` 字段）；TTFT 期间每 15s `: keep-alive` |
| `/v1/models` | GET | 单模型 `qwen3.8-flash-next` |
| `/health` | GET | `{"status","model","uptime_seconds","images","image_generation","max_context"}`；`image_generation` 控制 App Images tab 显隐 |
| `/metrics` | GET | **完整树**：`live/hardware/hardware_static/engine/history/requests/totals/requests_kept/conversation_cache`；`?requests=all` 给全部（默认 12 条）；`?format=prometheus` 双格式 |
| `/props` | GET | 量化档位（只读）等引擎属性 |
| `/status` | GET | 请求队列状态（App v0.0.4 兼容） |
| `/v1/status` | GET | `{model,loaded,auto_load,activity:{in_flight}}`（Monitor/控制页用） |
| `/api/requests` | GET | API Monitor：请求列表（真实 chat 驱动状态机 loading→prefilling→generating→completed/error/disconnected）；`?id=` 详情含 input/output/reasoning/response/usage/timings |
| `/config` | GET/POST | GET 键值清单（bool/enum/number/string 四 kind）；POST `{set:{k:v}}` 只发 diff → `{changed:[…],file}` |
| `/settings` | GET/POST | GET `{shared:bool}`；POST `{defaults:{…}}` 开共享 / `{defaults:null}` 关 |
| `/mcp` | GET | 静态样例：fetch/filesystem（ready）+ weather（failed，含 error 字段） |
| `/v1/images/generations` | POST | `{prompt,size,seed?}` → 小 PNG 的 `b64_json` + `seed` + `size`（同 seed 幂等） |
| `/load` `/unload` `/v1/load` `/v1/unload` | POST | 引擎启停（`/v1/status.loaded` 联动；unload 后 chat 在 auto_load 下自动拉起） |
| 其他 | - | 404；鉴权失败 401（OpenAI 风格错误体） |

## 流式响应样例

```text
data: {"choices":[{"delta":{"role":"assistant"},"finish_reason":null}]}

: keep-alive                     ← 仅长 TTFT 期间出现，每 15s 一行
data: {"strata_mcp":{"event":"limit","max_rounds":6},…}      ← 仅 strata_mcp:true 时
data: {"strata_mcp":{"event":"start","id":"mcp-…","server":"fetch","tool":"fetch",…},…}
data: {"strata_mcp":{"event":"call",…},…}
data: {"strata_mcp":{"event":"result","ok":true,"text":"…"},…}
data: {"choices":[{"delta":{"reasoning_content":"用户发来"},"finish_reason":null}]}
data: {"choices":[{"delta":{"content":"收到你的消息"},"finish_reason":null}]}
data: {"choices":[{"delta":{},"finish_reason":"stop"}]}
data: {"usage":{…},"choices":[{…,"finish_reason":"stop"}]}  ← usage 随尾块返回（choices 非空，上游真实形态）
data: [DONE]
```

## App / 单测接入

| 场景 | URL |
|---|---|
| Windows 本机（Dart 单测 / 桌面调试） | `http://127.0.0.1:8420` |
| Android 模拟器（App 连宿主机） | `http://10.0.2.2:8420` |
| Android 真机（同局域网） | `http://<PC局域网IP>:8420`（Mock 需 `--host 0.0.0.0`） |
| 模拟 WireGuard 虚拟网段 | `http://10.0.0.2:8080`（自定义 host 映射或本机加虚拟 IP 时） |

## 与真实 Strata 的对齐状态

**已对齐**：端点清单、`reasoning_effort` 按请求可调、15s SSE 注释保活、单模型 ID `qwen3.8-flash-next`、Bearer 鉴权方式。

**源码级对齐**（逐端点核实上游 `serve/web/` 实现）：`/metrics` 完整 schema、`/api/requests` 列表与详情、`/config` GET/POST、`/settings`、`/mcp`、`/v1/status`、`/v1/images/generations`、chat 流式尾块（choices 非空 + usage 顶层）、`strata_mcp` 四事件流、`/health` 的 `images/image_generation/max_context` 字段。

**合理猜测**（接入真实主机后需对齐）：401 错误体、`/metrics` 数值画像（硬件数值为模拟）、`/api/requests` 的 `load_s/queue_s` 具体量级、`/mcp` servers 静态内容。
→ 接入真实主机后若形态不符，**改本 Mock 并同步 App 解析层**，保持两边一致。

## 关联文档

| 方向 | 目标 |
|---|---|
| 接口与端点说明 | [移动端接入规范](../../docs/mobile-integration-spec.md) |
| 项目总览 | [README](../../README.md) |
| 逐页用法 | [用户手册](../../docs/用户手册.md) |
