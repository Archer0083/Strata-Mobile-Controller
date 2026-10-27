# 移动端接入规范：如何用手机访问 Strata 服务器

> **文档编号**：docs-004
> **日期**：2026-10-27
> **用途**：描述手机客户端接入 Strata 引擎时必须知道的接口行为差异。
> **实测基础**：Android 真机 + 真实 Strata 主机（v0.0.10）；文中每条结论标注了依据。
> **上游同步状态**：本文件的英文版 [mobile-integration-spec.en.md](mobile-integration-spec.en.md) 是提交给上游 `Niko1221/Strata` 的 `docs/` 草案（上游文档统一使用英文）。本中文版供本仓库读者阅读，内容与英文版一致。

---

## 1. 服务器地址

服务器默认地址是 `http://127.0.0.1:8080`。

**手机不能使用这个地址。** 手机上的 `127.0.0.1` 指的是手机自己。手机需要一个能到达电脑的地址。

`strata launch --access` 已经能生成这些地址：

| 接入方式 | 手机使用什么 | 说明 |
| --- | --- | --- |
| `local` | 无 | 服务器只监听电脑自己的回环地址，手机无法访问。 |
| `lan` | 电脑在局域网内的地址 | 手机必须处于同一网络。服务器会为你生成一个 API Key。 |
| `tailscale` | 电脑的 Tailscale 地址 | 手机也需要安装 Tailscale。 |
| `cloudflare` | 一个 `trycloudflare.com` 地址 | 手机只需联网，不必同网络。隧道地址每次都会变。 |

API Key 是服务器校验的对象。请在两个请求头中都带上它：

```
Authorization: Bearer <key>
x-api-key: <key>
```

服务器接受其中任意一个。同时带上两个是安全的。

**实测**：本应用两个头都发送，对「有 Key 的服务器」和「无 Key 的服务器」均正常工作。

---

## 2. 对话请求

`POST <base>/v1/chat/completions`，其中 `<base>` 是不带 `/v1` 的服务器地址。请求体是 OpenAI 的结构：

```json
{
  "model": "the model name the server reports",
  "messages": [{"role": "user", "content": "your text"}],
  "stream": true
}
```

### 2.1 思考模式

要让模型先思考，请发送 `reasoning_effort`。可用的取值：

| 取值 | 效果 |
| --- | --- |
| `none` | 不思考。 |
| `low` | 少量思考。 |
| `medium` | 中等。 |
| `high` | 更多。服务器的对话模板把它称为 `xhigh`。 |

**其他任何取值都会被 HTTP 400 拒绝。** 服务器会拿这个名字比对一张白名单，不在表内即拒绝。

**实测**：`none`、`low`、`medium`、`high` 均在真实服务器上验证通过。

### 2.2 思考文本在独立字段中

模型思考时，思考文本**不会**混进正文，而是出现在单独的字段里：

```json
{"choices": [{"delta": {"reasoning_content": "the thinking text"}}]}
```

**第一个数据块完全没有 `reasoning_content` 这个键。** 它长这样：

```json
{"choices": [{"delta": {"role": "assistant", "content": ""}}]}
```

读取 `delta.reasoning_content` 的客户端不能把「键缺失」当作错误。

### 2.3 正文文本

```json
{"choices": [{"delta": {"content": "the answer text"}}]}
```

---

## 3. 流式返回

服务器以 Server-Sent Events 响应流式请求。格式如下：

```
data: {"choices":[{"delta":{"content":"Hello"}}]}

data: {"choices":[{"delta":{"content":" world"}}]}

data: {"choices":[{"delta":{},"finish_reason":"stop"}],"usage":{"total_tokens":42}}

data: [DONE]

```

客户端必须知道的四件事。

### 3.1 保活行是注释行

在模型还在产出第一个 token 期间，服务器每 15 秒发一行注释：

```
: keep-alive

```

这是合法的 SSE 注释。客户端如果等待下一条 `data:` 行、期间不显示任何内容，那属于正确行为。它不能把注释当成数据，也不能因此超时。

**实测**：15 秒，从真机连真实服务器的真实流中读出。

### 3.2 最后一个数据块的 `choices` 数组非空

OpenAI 规范说 usage 数据块携带的是**空**的 `choices` 数组。而 Strata 服务器发的是**非空**数组：

```json
{"choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}], "usage": {"total_tokens": 42}}
```

按 OpenAI 规范编写的客户端会等那个空 `choices` 数据块，等到了就停止读取。在这个服务器上那个数据块永远不会来，客户端最终可能拿不到回答。

**客户端必须同时接受两种形态。** 在两个位置都去找 usage 计数，并以 `data: [DONE]` 作为流结束标志。

### 3.3 usage 计数在顶层

`usage` 是数据块自身的键，不是 `choices` 内部的键。去找 `choices[0].usage` 的客户端什么也找不到。

### 3.4 不支持 `stream_options`

这个服务器无法识别 `stream_options` 与 `include_usage`。无论客户端是否索取，usage 计数总是出现在最后一个数据块里。

**实测**：在服务器源码中检索这两个名字，均无匹配。

---

## 4. 非流式返回

同一个请求去掉 `"stream": true`。回答一次性返回：

```json
{"choices": [{"message": {"role": "assistant", "content": "the answer text"}}]}
```

两个细节：

- `content` 可能为 `null`。不要不加判断就下标访问。
- `reasoning_content` 只在模型确实思考过时才存在，这个键也可能整个缺失。

**实测**：两种情况都在真实服务器上出现过。

---

## 5. 手机还可以用到的其他接口

| 接口 | 方法 | 用途 |
| --- | --- | --- |
| `/v1/models` | GET | 服务器当前提供的模型。 |
| `/v1/status` | GET | 服务器是否在线，以及它正在做什么。 |
| `/metrics` | GET | 引擎自身的数值：GPU 占用、显存、温度、`tok_s`、`live_state`。 |
| `/models/installed` | GET | 电脑上的模型文件。 |
| `/api/requests` | GET | 请求日志。 |

后三个不属于 OpenAI API，它们是桌面版 web 页面使用的接口。做监控页的手机客户端可以同样使用。

**实测**：本应用读取模型列表、已安装模型与 metrics 接口来填充监控页。

---

## 6. 手机客户端应当怎么做

一份简短的清单，按重要性排序。

1. **在首屏显示地址与 Key。** 手机上没有配置文件。Key 请放在手机的安全存储中，不要放在明文偏好设置里。
2. **保持流式连接，并把思考内容单独显示。** 两个字段，屏幕上也分开呈现。
3. **同时接受两种末块形态。** 在顶层与 `choices[0].usage` 两处都找 `usage`，以 `data: [DONE]` 结束。
4. **不要把保活注释当成错误。** 本地模型产出第一个 token 可能很慢。
5. **把 `reasoning_content` 键缺失当作正常情况。**
6. **如实展示失败。** 把畸形数据行吞掉的客户端，会把服务器的问题变成「没有回答」—— 这是最难报告的一类 bug。

---

## 7. 测试方式

- 应用版本：0.0.10，构建为 debug APK，覆盖三种 ABI（`arm64-v8a`、`armeabi-v7a`、`x86_64`）。
- 运行方式：真实 Android 手机，连接同一局域网内的真实 Strata 服务器。
- 应用自带测试套件：255 个测试通过；静态检查无告警。
- 第 3.1 至 3.3 节的流式细节，是在手机上直接读取原始 SSE 流得到的。
- 第 2.1 节的请求规则与第 4 节的返回结构，是对运行中的服务器校验的。

**未测试的部分**：

- iOS。该应用目前只支持 Android。
- Android 以外的任何手机系统。
- 应用未对以 `--access cloudflare` 或 `--access tailscale` 启动的服务器做过验证。隧道与 VPN 路径没有在手机上跑过。
- 应用不在任何应用商店中，需通过 APK 文件安装。

---

## 8. 这份文档的由来

手机和其他客户端一样，都是普通客户端，服务器用的也是同一套 API。这份文档把服务器与 OpenAI 规范不一致的地方集中记录下来，好让为手机编写的客户端不必重新发现一遍。

用于验证这些结论的客户端是一个第三方项目：
https://github.com/Archer0083/Strata-Mobile-Controller

它不属于 Strata，也不会改动服务器，只是用来验证本文档中的各条结论。
