# Mobile clients: how to talk to a Strata server from a phone

> **Document id**: docs-004
> **Date**: 2026-10-27
> **Purpose**: a draft for the upstream `Niko1221/Strata` `docs/` folder, describing what a mobile client must know about the server's API.
> **Style constraint**: follows the upstream `AGENTS.md` — plain words, short sentences, written for non-technical users first. Give measured numbers with what they were measured on. Make no claim without a measurement.
> **Measured against**: a real Android phone and a real Strata host (v0.0.10); every claim below says what it rests on.
> **Chinese translation**: [mobile-integration-spec.md](mobile-integration-spec.md) carries the same content for readers of the client repository.

---

## Why this page

The server speaks the OpenAI Chat Completions API. A phone can therefore use the same
API as any other client. This page lists the parts where the server does not behave
exactly like the OpenAI specification, and what a client has to do about it.

Everything here was measured against a running Strata server from a real Android phone.
Where a statement comes from reading the server's source code, it says so.

---

## 1. The address

The default server address is `http://127.0.0.1:8080`.

**A phone cannot use that address.** `127.0.0.1` on a phone means the phone itself.
The phone needs an address that reaches the computer.

`strata launch --access` already builds those addresses:

| Access | What the phone uses | Notes |
| --- | --- | --- |
| `local` | nothing | The server stays on the computer's own loopback. A phone cannot reach it. |
| `lan` | the computer's address on the local network | The phone must be on the same network. The server makes an API key for you. |
| `tailscale` | the computer's Tailscale address | The phone needs Tailscale too. |
| `cloudflare` | a `trycloudflare.com` address | The phone needs internet, not the same network. The tunnel URL changes every time. |

The API key is what the server checks. Send it in both headers:

```
Authorization: Bearer <key>
x-api-key: <key>
```

The server accepts either one. Sending both is safe.

**Measured:** the app sends both headers and works against a server with a key and
against one without.

---

## 2. The chat request

`POST <base>/v1/chat/completions`, where `<base>` is the server address without `/v1`
in it. The request body is the OpenAI shape:

```json
{
  "model": "the model name the server reports",
  "messages": [{"role": "user", "content": "your text"}],
  "stream": true
}
```

### 2.1 Thinking

To ask the model to think, send `reasoning_effort`. The values that work are:

| Value | What it does |
| --- | --- |
| `none` | No thinking. |
| `low` | A little. |
| `medium` | The middle. |
| `high` | More. The server's chat template calls this `xhigh`. |

**Any other value is refused with HTTP 400.** The server checks the name against a
list and rejects what is not on it.

**Measured:** `none`, `low`, `medium`, `high` all work against a running server.

### 2.2 The reasoning text arrives in its own field

When the model thinks, the thinking text is **not** mixed into the answer. It arrives
in a separate field:

```json
{"choices": [{"delta": {"reasoning_content": "the thinking text"}}]}
```

**The first chunk has no `reasoning_content` key at all.** It looks like this:

```json
{"choices": [{"delta": {"role": "assistant", "content": ""}}]}
```

A client that reads `delta.reasoning_content` must not treat the missing key as an
error.

### 2.3 The answer text

```json
{"choices": [{"delta": {"content": "the answer text"}}]}
```

---

## 3. The streaming reply

The server answers a streamed request with Server-Sent Events. The format:

```
data: {"choices":[{"delta":{"content":"Hello"}}]}

data: {"choices":[{"delta":{"content":" world"}}]}

data: {"choices":[{"delta":{},"finish_reason":"stop"}],"usage":{"total_tokens":42}}

data: [DONE]

```

Four things a client has to know.

### 3.1 Keep-alive lines are comments

While the model is still working on the first token, the server sends a comment line
every 15 seconds:

```
: keep-alive

```

This is a valid SSE comment. A client that waits for the next `data:` line and shows
nothing in the meantime is behaving correctly. It must not treat the comment as data
and must not time out because of it.

**Measured:** 15 seconds, read off a real stream from a real server on a real phone.

### 3.2 The last data chunk has a non-empty `choices` array

The OpenAI specification says the usage chunk carries an **empty** `choices` array.
The Strata server sends a **non-empty** one:

```json
{"choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}], "usage": {"total_tokens": 42}}
```

A client written against the OpenAI specification waits for the empty-`choices` chunk
and stops reading there. On this server that chunk never comes, and the client can end
up with a missing answer.

**A client must accept both shapes.** Look for the usage counters wherever they are,
and end the stream on `data: [DONE]`.

### 3.3 The usage counters sit at the top level

`usage` is a key of the chunk itself, not a key inside `choices`. A client that looks
for `choices[0].usage` finds nothing.

### 3.4 `stream_options` is not supported

`stream_options` and `include_usage` are not understood by this server. The usage
counters always come in the last chunk, whether the client asks for them or not.

**Measured:** no match for either name in the server's source.

---

## 4. The non-streaming reply

Same request without `"stream": true`. The answer is in one piece:

```json
{"choices": [{"message": {"role": "assistant", "content": "the answer text"}}]}
```

Two details:

- `content` can be `null`. Do not index it blindly.
- `reasoning_content` is only there when the model actually thought. The key may be
  missing entirely.

**Measured:** both cases were seen against a running server.

---

## 5. Other endpoints a phone can use

| Endpoint | Method | What it gives |
| --- | --- | --- |
| `/v1/models` | GET | The model the server serves. |
| `/v1/status` | GET | Whether the server is up and what it is doing. |
| `/metrics` | GET | The engine's own numbers: GPU use, memory, temperature, `tok_s`, `live_state`. |
| `/models/installed` | GET | The model files on the computer. |
| `/api/requests` | GET | The request log. |

The last three are not part of the OpenAI API. They are what the desktop web page
uses, and a phone client that shows a monitor page can use them the same way.

**Measured:** the app reads the model list, the installed models and the metrics
endpoint to fill its monitor page.

---

## 6. What a phone client should do

A short list, in the order that matters.

1. **Show the address and the key on the first screen.** There is no config file on a
   phone. Keep the key in the phone's secure storage, not in plain preferences.
2. **Keep the stream open and show the thinking separately.** Two fields, two places
   on screen.
3. **Accept both last-chunk shapes.** Look for `usage` at the top level and at
   `choices[0].usage`. End on `data: [DONE]`.
4. **Do not treat a keep-alive comment as an error.** The first token can take a long
   time on a local model.
5. **Treat a missing `reasoning_content` key as normal.**
6. **Show the real failure.** A client that swallows a malformed line turns a server
   problem into "no answer", which is the hardest kind of bug to report.

---

## 7. How this was tested

- App version: 0.0.10, built as a debug APK for three ABIs (`arm64-v8a`,
  `armeabi-v7a`, `x86_64`).
- Run on: a real Android phone, against a real Strata server on the same local
  network.
- The app's own test suite: 255 tests pass. The static check reports no issues.
- The streaming details in sections 3.1 to 3.3 were read off the raw SSE stream on
  the phone.
- The request rules in section 2.1 and the reply shapes in section 4 were checked
  against the running server.

**Not tested:**

- iOS. The app is Android only so far.
- Any phone system other than Android.
- The app against a server started with `--access cloudflare` or `--access tailscale`.
  The tunnel and VPN paths were not exercised on the phone.
- The app is not in any app store. It is installed from an APK file.

---

## 8. Why this page is here

A phone is a client like any other, and the server's API is the same one every other
client uses. This page collects the places where the server differs from the OpenAI
specification, so that a client written for a phone does not have to rediscover them.

The client used to test these notes is a third-party project:
https://github.com/Archer0083/Strata-Mobile-Controller

It is not part of Strata and it does not change the server. It is a way to check the
points on this page.
