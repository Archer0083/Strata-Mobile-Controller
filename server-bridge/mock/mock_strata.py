#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Mock Strata 服务 —— App 与单测的默认目标。

用途：
  在没有真实 Strata 主机的情况下，为 Flutter App 与 Dart 单测提供形态一致的
  HTTP/SSE 假服务。按引擎 web 端实现逐端点对齐（源码级核实）：

  对话     POST /v1/chat/completions（流式/非流式、reasoning_effort、15s keep-alive、
               尾块 choices 非空 + usage 顶层；请求体带 strata_mcp:true 时流内插
               limit/start/call/result 事件块，事件挂 chunk 顶层 strata_mcp 字段）
  模型     GET  /v1/models
  健康     GET  /health（images / image_generation / max_context 控制 Images tab 显隐）
  监控     GET  /metrics（完整 schema：live/hardware/hardware_static/engine/history/
               requests/totals/requests_kept/conversation_cache；?requests=all；
               format=prometheus 双格式）
  运维     GET  /props /status；POST /load /unload（含 /v1/load /v1/unload 别名）
  状态     GET  /v1/status（model/loaded/auto_load/activity.in_flight）
  API监控  GET  /api/requests（?id= 详情；--api-monitor off 模拟真实默认关闭→404）
  配置     GET/POST /config（内存键值 store，POST {set:{k:v}} → {changed,file}）
  共享     GET/POST /settings（GET {shared}；POST {defaults:{...}|null}）
  MCP      GET  /mcp（静态 servers 树：ready×2 + failed×1 样例）
  生图     POST /v1/images/generations（stdlib PNG 编码 → b64_json + seed + size）

  Bearer 鉴权：--api-key 非空时全端点强制（401 错误体为合理猜测）。

零第三方依赖，Python 3.8+ 标准库即可运行：
  python mock_strata.py [--host 127.0.0.1] [--port 8420] [--api-key SECRET]
                        [--speed 0.04] [--ttft auto|秒数] [--api-monitor on|off]
"""

import argparse
import base64
import json
import random
import struct
import threading
import time
import uuid
import zlib
from collections import deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs

MODEL_ID = "qwen3.8-flash-next"  # 单模型：与上游一致
QUANTIZATION = "IQ2_XS"          # 量化档位：运行期只读（SPEC §8.1）
CONTEXT_LENGTH = 262144

# v0.0.6：主机上「已安装的模型」清单（对齐服务端 GET /models/installed 的形状）。
# 真实服务端读的是安装目录里的 strata-<model>.json 运行配置；Mock 用静态示例。
INSTALLED_MODELS = [
    {"id": "qwen3.8-flash-next", "name": "qwen3.8-flash-next",
     "context_tokens": 262144, "component_status": "present",
     "backend": "llama-cpp", "source_config": "strata-qwen3.8-flash-next.json",
     "issue_codes": []},
    {"id": "qwen3.8-flash-next-coder", "name": "qwen3.8-flash-next-coder",
     "context_tokens": 131072, "component_status": "present",
     "backend": "llama-cpp", "source_config": "strata-qwen3.8-flash-next-coder.json",
     "issue_codes": []},
    {"id": "deepseek-v4.1-flash", "name": "deepseek-v4.1-flash",
     "context_tokens": 65536, "component_status": "missing_or_invalid",
     "backend": "llama-cpp", "source_config": "strata-deepseek-v4.1-flash.json",
     "issue_codes": ["model_file_missing"]},
]
KEEPALIVE_INTERVAL = 15          # 秒：真实引擎每 15s 发 SSE 注释行保活（api-notes §3）
HISTORY_LEN = 120                # /metrics history 环形缓冲长度（webUI sparkline 直接消费）
REQUESTS_KEPT = 12               # /metrics requests 默认条数（?requests=all 给全部）
REQUESTS_MAX = 64                # /metrics requests 内部环形缓冲上限
API_MONITOR_MAX = 50             # /api/requests 记录上限

# 思考档位 → (思考文本长度字数, 默认 TTFT 秒数)；TTFT 可用 --ttft 覆盖（验证长等待/保活）
EFFORT_PROFILE = {
    "none":   (0,   0.3),
    "low":    (60,  1.0),
    "medium": (160, 2.5),
    "high":   (420, 6.0),
}

REASONING_TEXT = (
    "用户发来了一条消息，我需要理解意图并组织回答。先看关键词与语气，判断是测试还是真实提问；"
    "再拆解问题的层次：核心诉求是什么、有没有隐含的上下文依赖、回复应当控制在什么长度。"
    "注意到这是通过移动端控制台发来的请求，界面上会同时展示思考过程与正文，"
    "所以思考内容适合写成连贯的短段落而不是零散短语。接下来我会检查消息里是否有需要回显的部分，"
    "如果有就直接引用原文，避免理解偏差。然后构思正文结构：先给结论、再给细节、最后给下一步建议。"
    "语言风格保持自然，避免机械感。长度上，既然对方在测试流式输出，正文不宜过长，"
    "几十到一百字左右即可，重点是让每个分块都肉眼可见地逐字出现。"
    "最后自查一遍：格式正确、没有幻觉、回复与档位语义一致。好，可以开始输出了。"
)

REPLY_TAIL = "（以上内容由 Mock 生成，用于验证流式渲染、思考区块与档位随发随调。）"


def approx_tokens(text):
    """粗略 token 估算（中英混合按 ~1.5 字符/token），仅用于 Mock usage 展示。"""
    return max(1, len(text) // 2)


def _walk(v, lo, hi, step):
    """有界随机游走一步。"""
    return min(hi, max(lo, v + random.uniform(-step, step)))


# =====================================================================
# 监控指标模拟器（M2-10：完整 /metrics schema，对齐 app.js render(m)）
# =====================================================================

class MetricsSim:
    """状态随机游走 + history 环形缓冲；chat 请求驱动 live.state 生命周期。"""

    def __init__(self):
        self._lock = threading.Lock()
        self._start = time.time()
        # live（prompt_read/prompt_total 模拟 context 进度环）
        self.state = "idle"            # reading / generating / idle
        self.phase = ""                # prefill / decode / ""
        self.prompt_read = 0
        self.prompt_total = 0
        self.prompt_tokens = 0
        self.generated = 0
        self.max_tokens = 0
        self.queued = 0
        self._active = 0
        # hardware（4090 级消费卡画像）
        self.gpu_util = 8.0
        self.gpu_power = 88.0
        self.gpu_mem_used = 23180.0
        self.gpu_temp = 42.0
        self.gpu_pcie_rx_mb = 4.0
        self.cpu = 9.0
        self.ram_used = 33200.0
        self.disk_read_mb = 0.0
        self.disk_write_mb = 0.0
        self.tok_s = 0.0
        self.prefill_tok_s_mean = 0.0
        self.hit_rate = 0.61
        # conversation_cache（字段对齐 app.js renderConvCache；先于 history 预填初始化）
        self.conv = {
            "enabled": True, "parked": [], "slots": 8, "budget_mib": 8192,
            "bytes": 3584.0, "requests": 27, "requests_reused": 11,
            "prompt_tokens": 31280, "reused_tokens": 9840,
            "parks": 3, "restores": 2, "evictions": 1,
            "last_event": "prefill", "last_tokens": 1204,
            "last_at": time.time() - 61.2,
            "last_prompt": "帮我把这段代码重构一下，顺便加上单测", "last_reused": False,
        }
        # history 环形缓冲（预填 HISTORY_LEN 个样本，sparkline 开屏即有形）
        self.hist = {
            "tok_s": deque(maxlen=HISTORY_LEN),
            "prefill_tok_s_mean": deque(maxlen=HISTORY_LEN),
            "gpu_util": deque(maxlen=HISTORY_LEN),
            "gpu_mem_used": deque(maxlen=HISTORY_LEN),
            "gpu_temp": deque(maxlen=HISTORY_LEN),
            "gpu_power": deque(maxlen=HISTORY_LEN),
            "gpu_pcie_rx_mb": deque(maxlen=HISTORY_LEN),
            "cpu": deque(maxlen=HISTORY_LEN),
            "disk_read_mb": deque(maxlen=HISTORY_LEN),
        }
        for _ in range(HISTORY_LEN):
            self._step()
        # 最近请求表（种子 3 条，避免首屏空表；真实 chat 完成后插入最新）
        self.requests = deque(maxlen=REQUESTS_MAX)
        now = time.time()
        for i, (finish, out_tok) in enumerate([("stop", 214), ("length", 512), ("stop", 96)]):
            self.requests.appendleft({
                "time": now - (i + 1) * 97.3, "finish": finish, "projection": False,
                "prompt_tokens": 1200 + i * 340, "reused": 780 - i * 120,
                "output_tokens": out_tok, "prompt_ms": 640.0 - i * 90,
                "decode_tok_s": 52.4 - i * 3.1, "hit_rate": 0.52 + i * 0.07,
                "pcie_share": 0.11 - i * 0.02, "duration_s": 8.9 - i * 1.7,
            })
        # totals（since 为启动时刻）
        self.totals = {"since": self._start, "requests": 3, "prompt_tokens": 4760,
                       "reused": 1980, "prompt_ms": 1490.0, "output_tokens": 822,
                       "decode_ms": 21340.0}

    # ---------- 内部游走 ----------

    def _step(self):
        busy = self._active > 0
        if busy:
            self.gpu_util = _walk(self.gpu_util, 55.0, 99.0, 5.0)
            self.gpu_power = _walk(self.gpu_power, 180.0, 448.0, 9.0)
            self.gpu_temp = _walk(self.gpu_temp, 55.0, 76.0, 0.6)
            self.gpu_pcie_rx_mb = _walk(self.gpu_pcie_rx_mb, 0.0, 720.0, 60.0)
            self.tok_s = _walk(self.tok_s, 28.0, 90.0, 3.0)
            self.prefill_tok_s_mean = _walk(self.prefill_tok_s_mean, 820.0, 2400.0, 90.0)
            self.disk_read_mb = _walk(self.disk_read_mb, 0.0, 260.0, 30.0)
        else:
            self.gpu_util = _walk(self.gpu_util, 2.0, 38.0, 4.0)
            self.gpu_power = _walk(self.gpu_power, 60.0, 130.0, 5.0)
            self.gpu_temp = _walk(self.gpu_temp, 38.0, 52.0, 0.4)
            self.gpu_pcie_rx_mb = _walk(self.gpu_pcie_rx_mb, 0.0, 18.0, 4.0)
            self.tok_s = max(0.0, self.tok_s * 0.6)
            self.prefill_tok_s_mean = 0.0
            self.disk_read_mb = _walk(self.disk_read_mb, 0.0, 6.0, 2.0)
        self.gpu_mem_used = _walk(self.gpu_mem_used, 22900.0, 24200.0, 25.0)
        self.cpu = _walk(self.cpu, 2.0, 62.0, 4.0)
        self.ram_used = _walk(self.ram_used, 30000.0, 42000.0, 160.0)
        self.disk_write_mb = _walk(self.disk_write_mb, 0.0, 90.0, 12.0)
        self.hit_rate = _walk(self.hit_rate, 0.05, 0.98, 0.03)
        self.conv["bytes"] = _walk(self.conv["bytes"], 512.0, 7800.0, 90.0)
        for key, dq in self.hist.items():
            dq.append(round(getattr(self, key), 2))

    def tick(self):
        with self._lock:
            self._step()

    # ---------- 请求生命周期（chat 流驱动） ----------

    def begin_prefill(self, prompt_tokens, max_tokens):
        with self._lock:
            self._active += 1
            self.state = "reading"
            self.phase = "prefill"
            self.prompt_tokens = prompt_tokens
            self.prompt_total = min(CONTEXT_LENGTH, prompt_tokens + 40960)
            self.prompt_read = int(prompt_tokens * random.uniform(0.05, 0.3))
            self.max_tokens = max_tokens
            self.generated = 0

    def begin_decode(self):
        with self._lock:
            self.state = "generating"
            self.phase = "decode"
            self.prompt_read = self.prompt_total

    def add_generated(self, n):
        with self._lock:
            self.generated += n

    def end_request(self):
        with self._lock:
            self._active = max(0, self._active - 1)
            if self._active == 0:
                self.state = "idle"
                self.phase = ""
                self.generated = 0

    def active(self):
        with self._lock:
            return self._active

    def record_request(self, prompt_tokens, output_tokens, prompt_ms, decode_tok_s,
                       duration_s, finish, user_text=""):
        """chat 请求完成后：插入 requests 表 + 累计 totals + 更新 conv_cache。"""
        with self._lock:
            reused = int(prompt_tokens * self.hit_rate)
            self.requests.appendleft({
                "time": time.time(), "finish": finish, "projection": False,
                "prompt_tokens": prompt_tokens, "reused": reused,
                "output_tokens": output_tokens, "prompt_ms": round(prompt_ms, 1),
                "decode_tok_s": round(decode_tok_s, 1),
                "hit_rate": round(self.hit_rate, 2),
                "pcie_share": round(min(0.6, self.gpu_pcie_rx_mb / 1200.0), 2),
                "duration_s": round(duration_s, 2),
            })
            self.totals["requests"] += 1
            self.totals["prompt_tokens"] += prompt_tokens
            self.totals["reused"] += reused
            self.totals["prompt_ms"] += prompt_ms
            self.totals["output_tokens"] += output_tokens
            self.totals["decode_ms"] += output_tokens / max(1.0, decode_tok_s) * 1000
            c = self.conv
            c["requests"] += 1
            hit = self.hit_rate > 0.5
            if hit:
                c["requests_reused"] += 1
                c["reused_tokens"] += reused
            c["last_event"] = "hit" if hit else "prefill"
            c["last_tokens"] = prompt_tokens
            c["last_at"] = time.time()
            c["last_prompt"] = user_text[:40]
            c["last_reused"] = hit
            if random.random() < 0.15:
                c["parks"] += 1
            if random.random() < 0.12:
                c["restores"] += 1
            if random.random() < 0.08:
                c["evictions"] += 1

    def uptime(self):
        return int(time.time() - self._start)

    # ---------- /metrics 树 ----------

    def metrics_tree(self, all_requests=False):
        with self._lock:
            reqs = list(self.requests) if all_requests else list(self.requests)[:REQUESTS_KEPT]
            gpu_mem_used = round(self.gpu_mem_used)
            return {
                "live": {
                    "state": self.state,
                    "prompt_read": self.prompt_read,
                    "prompt_total": self.prompt_total,
                    "prompt_tokens": self.prompt_tokens,
                    "generated": self.generated,
                    "max_tokens": self.max_tokens,
                    "tok_s": round(self.tok_s, 1),
                    "prefill_tok_s_mean": round(self.prefill_tok_s_mean, 1),
                    "queued": self.queued,
                    "phase": self.phase,
                },
                "hardware": {
                    "gpu_util": round(self.gpu_util, 1),
                    "gpu_mem_used": gpu_mem_used, "gpu_mem_total": 24576,
                    "gpu_temp": round(self.gpu_temp, 1),
                    "gpu_power": round(self.gpu_power, 1), "gpu_power_limit": 450,
                    "gpu_pcie_gen": 4, "gpu_pcie_gen_max": 5, "gpu_pcie_width": 16,
                    "gpu_pcie_rx_mb": round(self.gpu_pcie_rx_mb, 1),
                    "cpu": round(self.cpu, 1),
                    "ram_used": round(self.ram_used), "ram_total": 65536,
                    "disk_read_mb": round(self.disk_read_mb, 1),
                    "disk_write_mb": round(self.disk_write_mb, 1),
                    "psutil": True,
                    "gpus": [{"index": 0, "util": round(self.gpu_util, 1),
                              "mem_used": gpu_mem_used, "temp": round(self.gpu_temp, 1)}],
                },
                "hardware_static": {
                    "gpu_name": "NVIDIA GeForce RTX 4090", "gpu_note": "",
                    "cpu_name": "AMD Ryzen 9 7950X 16-Core", "cores": 16, "threads": 32,
                },
                "engine": {
                    "model": MODEL_ID, "version": "0.10.2", "max_context": CONTEXT_LENGTH,
                    "kv": "q4_0", "kv_resident": 24576,
                    "expert_slots": 128, "expert_cache_mib": 4096,
                    "spec": "", "mtp_max": 0, "lookup": "", "images": "", "cvec": 0,
                },
                "history": {k: list(v) for k, v in self.hist.items()},
                "requests": reqs,
                "totals": dict(self.totals),
                "requests_kept": REQUESTS_KEPT,
                "conversation_cache": {
                    "enabled": self.conv["enabled"], "parked": list(self.conv["parked"]),
                    "slots": self.conv["slots"], "budget_mib": self.conv["budget_mib"],
                    "bytes": round(self.conv["bytes"], 1),
                    "requests": self.conv["requests"],
                    "requests_reused": self.conv["requests_reused"],
                    "prompt_tokens": self.conv["prompt_tokens"],
                    "reused_tokens": self.conv["reused_tokens"],
                    "parks": self.conv["parks"], "restores": self.conv["restores"],
                    "evictions": self.conv["evictions"],
                    "last_event": self.conv["last_event"],
                    "last_tokens": self.conv["last_tokens"],
                    "last_at": round(self.conv["last_at"], 1),
                    "last_prompt": self.conv["last_prompt"],
                    "last_reused": self.conv["last_reused"],
                },
            }

    def prometheus_text(self):
        """Prometheus 双格式（真实 Strata 的 /metrics 兼容格式；App 不消费，运维用）。"""
        with self._lock:
            lines = [
                "# HELP strata_gpu_util GPU utilization percent",
                "# TYPE strata_gpu_util gauge",
                "strata_gpu_util %.1f" % self.gpu_util,
                "# HELP strata_gpu_power_w GPU power draw in watts",
                "# TYPE strata_gpu_power_w gauge",
                "strata_gpu_power_w %.1f" % self.gpu_power,
                "# HELP strata_gpu_mem_used_mb GPU memory used in MB",
                "# TYPE strata_gpu_mem_used_mb gauge",
                "strata_gpu_mem_used_mb %d" % round(self.gpu_mem_used),
                "# HELP strata_gpu_temp_c GPU temperature celsius",
                "# TYPE strata_gpu_temp_c gauge",
                "strata_gpu_temp_c %.1f" % self.gpu_temp,
                "# HELP strata_cpu_util CPU utilization percent",
                "# TYPE strata_cpu_util gauge",
                "strata_cpu_util %.1f" % self.cpu,
                "# HELP strata_ram_used_mb System memory used in MB",
                "# TYPE strata_ram_used_mb gauge",
                "strata_ram_used_mb %d" % round(self.ram_used),
                "# HELP strata_tok_s Generation speed tokens per second",
                "# TYPE strata_tok_s gauge",
                "strata_tok_s %.1f" % self.tok_s,
                "# HELP strata_prefill_tok_s Prefill speed tokens per second",
                "# TYPE strata_prefill_tok_s gauge",
                "strata_prefill_tok_s %.1f" % self.prefill_tok_s_mean,
                "# HELP strata_queued_requests Queued requests",
                "# TYPE strata_queued_requests gauge",
                "strata_queued_requests %d" % self.queued,
                "# HELP strata_active_requests Active requests",
                "# TYPE strata_active_requests gauge",
                "strata_active_requests %d" % self._active,
                "",
            ]
            return "\n".join(lines)


# =====================================================================
# API Monitor 请求记录器（M2-10：/api/requests，对齐 monitor.js）
# =====================================================================

TERMINAL_STATES = ("completed", "error", "disconnected")


class RequestRecorder:
    """记录真实经过 /v1/chat/completions 的请求，驱动状态机：
    loading → prefilling → generating → completed | error | disconnected。
    """

    def __init__(self):
        self._lock = threading.Lock()
        self._records = {}   # id -> record dict（含 _ended 内部字段）
        self._order = deque()  # 最新在前；超限淘汰最老

    def start(self, path, model, stream, response_format="text"):
        rid = "req-" + uuid.uuid4().hex[:8]
        rec = {
            "id": rid, "path": path, "model": model, "state": "loading",
            "started_at": round(time.time(), 3), "stream": bool(stream),
            "http_status": 200, "response_format": response_format,
            "load_s": round(random.uniform(0.2, 0.9), 3),
            "queue_s": 0.0, "first_token_s": None,
            "usage": {"prompt_tokens": 0, "completion_tokens": 0},
            "timings": {"predicted_per_second": 0.0},
            "input": "", "output": "", "reasoning": "", "response": "",
            "error": None, "finish": None, "_ended": None,
        }
        with self._lock:
            self._records[rid] = rec
            self._order.appendleft(rid)
            while len(self._order) > API_MONITOR_MAX:
                old = self._order.pop()
                self._records.pop(old, None)
        return rid

    def _set(self, rid, **kw):
        with self._lock:
            rec = self._records.get(rid)
            if rec is not None:
                rec.update(kw)

    def prefilling(self, rid, prompt_tokens, input_text):
        self._set(rid, state="prefilling",
                  usage={"prompt_tokens": prompt_tokens, "completion_tokens": 0},
                  input=input_text)

    def generating(self, rid, first_token_s):
        self._set(rid, state="generating", first_token_s=round(first_token_s, 3))

    def complete(self, rid, output_text, reasoning_text, prompt_tokens,
                 completion_tokens, tok_s, first_token_s, finish="stop"):
        with self._lock:
            rec = self._records.get(rid)
            if rec is None:
                return
            rec.update({
                "state": "completed", "output": output_text,
                "reasoning": reasoning_text, "response": output_text,
                "finish": finish, "_ended": time.time(),
                "usage": {"prompt_tokens": prompt_tokens,
                          "completion_tokens": completion_tokens},
                "timings": {"predicted_per_second": round(tok_s, 1)},
                "first_token_s": round(first_token_s, 3),
            })

    def error(self, rid, message):
        self._set(rid, state="error", error={"message": message}, _ended=time.time())

    def disconnect(self, rid):
        self._set(rid, state="disconnected", finish="disconnect", _ended=time.time())

    def active_count(self):
        with self._lock:
            return sum(1 for r in self._records.values()
                       if r["state"] not in TERMINAL_STATES)

    def list_json(self, loaded, auto_load):
        with self._lock:
            now = time.time()
            items = []
            for rid in self._order:
                rec = self._records.get(rid)
                if rec is None:
                    continue
                end = rec["_ended"] or now
                items.append({
                    "id": rec["id"], "path": rec["path"], "model": rec["model"],
                    "state": rec["state"], "started_at": rec["started_at"],
                    "wallclock_s": round(end - rec["started_at"], 3),
                    "stream": rec["stream"], "http_status": rec["http_status"],
                    # webUI monitor.js「Last decode speed」统计卡取列表项
                    # timings.predicted_per_second，此处与 detail_json 保持同源。
                    "timings": {"predicted_per_second":
                                rec["timings"]["predicted_per_second"]},
                })
            return {"requests": items, "loaded": loaded, "auto_load": auto_load}

    def detail_json(self, rid):
        with self._lock:
            rec = self._records.get(rid)
            if rec is None:
                return None
            now = time.time()
            end = rec["_ended"] or now
            out = {k: v for k, v in rec.items() if not k.startswith("_")}
            out["wallclock_s"] = round(end - rec["started_at"], 3)
            return out


# =====================================================================
# /config 内存键值 store（M2-10：四种 kind 各至少两个，对齐 app.js loadConfig）
# =====================================================================

class ConfigStore:
    KEYS = [
        {"key": "ctx", "value": 8192, "kind": "number", "help": "Context size (tokens)"},
        # v0.0.6：上下文长度（对齐真实服务端 runconfig 的 context_length 键）
        {"key": "context_length", "value": 262144, "kind": "number",
         "help": "Context length in tokens (used from the next start of the model)"},
        {"key": "ngl", "value": 999, "kind": "number", "help": "GPU layers"},
        {"key": "temperature", "value": 0.7, "kind": "number", "help": "Sampling temperature"},
        {"key": "flash_attn", "value": True, "kind": "bool", "help": "Use flash attention"},
        {"key": "mmproj", "value": False, "kind": "bool", "help": "Load multimodal projector"},
        {"key": "kv", "value": "q4_0", "kind": "enum",
         "choices": ["int8", "q4_0", "fp16"], "help": "KV cache quantization"},
        {"key": "host", "value": "127.0.0.1:8080", "kind": "string", "help": "Listen address"},
        {"key": "system", "value": "", "kind": "string", "help": "System prompt"},
    ]

    def __init__(self):
        self._lock = threading.Lock()
        self._values = {k["key"]: k["value"] for k in self.KEYS}
        self.file = "mock/strata.conf"

    def get_json(self):
        with self._lock:
            keys = []
            for k in self.KEYS:
                item = {"key": k["key"], "value": self._values[k["key"]],
                        "kind": k["kind"]}
                if k["kind"] == "enum":
                    item["choices"] = k["choices"]
                item["help"] = k["help"]
                keys.append(item)
            return {"file": self.file, "keys": keys}

    def apply(self, changes):
        """POST {set:{k:v,...}} → ({changed:[...]}, err)；webUI 只发 diff。"""
        if not isinstance(changes, dict) or not changes:
            return None, "set 必须是非空对象"
        with self._lock:
            changed = []
            for key, value in changes.items():
                if key not in self._values:
                    return None, "Unknown key: %s" % key
                if self._values[key] != value:
                    self._values[key] = value
                    changed.append(key)
            return changed, None


# =====================================================================
# /v1/images/generations：stdlib PNG 编码（M2-10）
# =====================================================================

def make_png_b64(w, h, seed):
    """按 seed 生成 w×h 彩色噪声 PNG，返回 base64（模拟生图结果）。"""
    rnd = random.Random(seed)
    rows = []
    base_r, base_g, base_b = rnd.randrange(256), rnd.randrange(256), rnd.randrange(256)
    for _ in range(h):
        row = bytearray([0])  # PNG 行过滤器类型 0
        for _ in range(w):
            row += bytes(((base_r + rnd.randrange(24)) % 256,
                          (base_g + rnd.randrange(24)) % 256,
                          (base_b + rnd.randrange(24)) % 256))
        rows.append(bytes(row))
    raw = b"".join(rows)

    def chunk(tag, data):
        return (struct.pack(">I", len(data)) + tag + data +
                struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(raw, 6))
    png += chunk(b"IEND", b"")
    return base64.b64encode(png).decode("ascii")


def parse_size(size, cap=256):
    """'WxH' → (w,h)；非法回退 1024x1024；上限 cap 防 CPU 爆炸（Mock 不做真生图）。"""
    try:
        w, h = str(size).lower().split("x", 1)
        w, h = int(w), int(h)
        if w <= 0 or h <= 0:
            raise ValueError
    except (ValueError, AttributeError):
        w, h = 1024, 1024
    return min(w, cap), min(h, cap)


# =====================================================================
# 全局状态
# =====================================================================

SIM = MetricsSim()
RECORDER = RequestRecorder()
CONFIG = ConfigStore()
STATE = {
    "loaded": True,       # 模型常驻（/load /unload 切换；chat 在 auto_load 下自动拉起）
    "auto_load": True,    # /v1/status 回显
    "shared": False,      # /settings 共享采样默认值开关
    "api_monitor": True,  # main() 里按 --api-monitor 覆盖（off → /api/requests 404）
    "current_model": MODEL_ID,  # v0.0.6：当前服务的模型（/models/select 会改它）
}
ARGS = None  # main() 里填充


# =====================================================================
# HTTP Handler
# =====================================================================

class MockHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    # ---------- 工具 ----------

    def _send_json(self, obj, status=200):
        body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _send_text(self, text, ctype, status=200):
        body = text.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _auth_ok(self):
        """Bearer 鉴权：--api-key 为空表示不鉴权（本地开发模式）。"""
        if not ARGS.api_key:
            return True
        header = self.headers.get("Authorization", "")
        return header == "Bearer " + ARGS.api_key

    def _deny(self):
        # 错误体形态：OpenAI 风合理猜测，实例级实测后对齐（api-notes §6 待办）
        self._send_json({"error": {"message": "Invalid API key",
                                   "type": "invalid_request_error",
                                   "code": "invalid_api_key"}}, status=401)

    def _read_body(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b"{}"
        try:
            return json.loads(raw or b"{}")
        except json.JSONDecodeError:
            return None

    def log_message(self, fmt, *args):
        print("[%s] %s" % (time.strftime("%H:%M:%S"), fmt % args), flush=True)

    def _in_flight(self):
        """monitor.js：in_flight = max(activity, active records)。"""
        return max(SIM.active(), RECORDER.active_count())

    # ---------- v0.0.6：已安装模型清单与模型选择 ----------

    def _models_installed(self):
        """GET /models/installed —— 主机上已安装的模型清单（对齐真实服务端形状）。"""
        current = STATE["current_model"]
        data = []
        for item in INSTALLED_MODELS:
            entry = dict(item)
            entry["current"] = (entry["id"] == current)
            data.append(entry)
        self._send_json({"object": "list", "data": data,
                         "install_dir": "G:/Strata-data/models",
                         "install_dir_source": "env:STRATA_MODELS_DIR",
                         "count": len(data)})

    def _models_select(self, body):
        """POST /models/select {"model": "<id>"} —— 切换到另一个已安装的模型。"""
        model_id = body.get("model")
        if not isinstance(model_id, str) or not model_id.strip():
            return self._send_json({"error": {"message": "name the model to serve (\"model\": \"<model id>\")",
                                              "type": "invalid_request_error"}},
                                   status=400)
        model_id = model_id.strip()
        target = next((m for m in INSTALLED_MODELS if m["id"] == model_id), None)
        if target is None:
            return self._send_json({"error": {"type": "not_found_error",
                                              "message": "model %r is not installed on this PC" % model_id}},
                                   status=404)
        if target["component_status"] != "present":
            return self._send_json({"error": {"type": "server_error",
                                              "message": "the model could not be started: its files are not all there"}},
                                   status=500)
        STATE["current_model"] = target["id"]
        STATE["loaded"] = False      # 真实服务端：引擎重建后按需加载
        self._send_json({"status": "switched", "model": target["id"],
                         "source_config": target["source_config"], "aliases": [],
                         "context_tokens": target["context_tokens"], "loaded": False,
                         "auto_load": STATE["auto_load"]})

    # ---------- 路由：GET ----------

    def do_GET(self):
        path, _, query = self.path.partition("?")
        qs = parse_qs(query)
        get_routes = ("/v1/models", "/health", "/metrics", "/props", "/status",
                      "/v1/status", "/api/requests", "/config", "/settings", "/mcp",
                      "/models/installed")
        if path not in get_routes:
            return self._send_json({"error": {"message": "Not found: " + path,
                                              "type": "invalid_request_error"}},
                                   status=404)
        if not self._auth_ok():
            return self._deny()
        if path == "/v1/models":
            self._send_json({"object": "list", "data": [{
                "id": STATE["current_model"], "object": "model",
                "created": int(time.time()), "owned_by": "strata"}]})
        elif path == "/models/installed":
            self._models_installed()
        elif path == "/health":
            # App v0.0.4 兼容字段（status/model/uptime_seconds）保留；
            # M2 新增 images/image_generation/max_context（webUI loadHealth 消费）
            self._send_json({"status": "ok", "model": STATE["current_model"],
                             "uptime_seconds": SIM.uptime(),
                             "images": "", "image_generation": True,
                             "max_context": CONTEXT_LENGTH})
        elif path == "/metrics":
            self._metrics(query)
        elif path == "/props":
            self._send_json({"model": STATE["current_model"], "quantization": QUANTIZATION,
                             "context_length": CONTEXT_LENGTH, "host_mode": "mock"})
        elif path == "/status":
            self._send_json({"active": SIM.active(), "queued": 0,
                             "queue": [], "uptime_seconds": SIM.uptime()})
        elif path == "/v1/status":
            self._send_json({"model": STATE["current_model"], "loaded": STATE["loaded"],
                             "auto_load": STATE["auto_load"],
                             "activity": {"in_flight": self._in_flight()}})
        elif path == "/api/requests":
            self._api_requests(qs)
        elif path == "/config":
            self._send_json(CONFIG.get_json())
        elif path == "/settings":
            self._send_json({"shared": STATE["shared"]})
        elif path == "/mcp":
            self._mcp()


    # ---------- 路由：POST ----------

    def do_POST(self):
        path = self.path.split("?", 1)[0]
        if not self._auth_ok():
            return self._deny()
        if path == "/v1/chat/completions":
            return self._chat()
        if path == "/v1/images/generations":
            return self._images()
        body = self._read_body()
        if body is None:
            return self._send_json({"error": {"message": "Invalid JSON body"}}, status=400)
        if path in ("/load", "/v1/load"):
            STATE["loaded"] = True
            self._send_json({"ok": True, "action": "load", "loaded": True})
        elif path in ("/unload", "/v1/unload"):
            STATE["loaded"] = False
            self._send_json({"ok": True, "action": "unload", "loaded": False})
        elif path == "/models/select":
            self._models_select(body or {})
        elif path == "/config":
            changes = (body or {}).get("set")
            changed, err = CONFIG.apply(changes)
            if err:
                return self._send_json({"error": {"message": err,
                                                  "type": "invalid_request_error"}},
                                       status=400)
            self._send_json({"changed": changed, "file": CONFIG.file})
        elif path == "/settings":
            defaults = (body or {}).get("defaults", "__missing__")
            if defaults == "__missing__":
                return self._send_json({"error": {"message": "defaults 字段缺失",
                                                  "type": "invalid_request_error"}},
                                       status=400)
            STATE["shared"] = defaults is not None  # null=恢复各自默认（共享关）
            self._send_json({"shared": STATE["shared"]})
        else:
            self._send_json({"error": {"message": "Not found: " + path,
                                       "type": "invalid_request_error"}}, status=404)

    # ---------- /metrics：JSON 完整树与 Prometheus 双格式 ----------

    def _metrics(self, query):
        SIM.tick()
        want_prom = "format=prometheus" in query or \
            "text/plain" in self.headers.get("Accept", "")
        if not want_prom:
            return self._send_json(SIM.metrics_tree(all_requests="requests=all" in query))
        self._send_text(SIM.prometheus_text(),
                        "text/plain; version=0.0.4; charset=utf-8")

    # ---------- /api/requests（API Monitor；--api-monitor off 时 404） ----------

    def _api_requests(self, qs):
        if not STATE["api_monitor"]:
            return self._send_json({"error": {"message": "api_monitor disabled",
                                              "type": "invalid_request_error"}},
                                   status=404)
        rid = (qs.get("id") or [""])[0]
        if rid:
            detail = RECORDER.detail_json(rid)
            if detail is None:
                return self._send_json({"error": {"message": "No such request: " + rid,
                                                  "type": "invalid_request_error"}},
                                       status=404)
            return self._send_json(detail)
        self._send_json(RECORDER.list_json(STATE["loaded"], STATE["auto_load"]))

    # ---------- /mcp（静态样例：ready×2 + failed×1，对齐 app.js loadMcp） ----------

    def _mcp(self):
        servers = [
            {"name": "fetch", "status": "ready", "transport": "stdio",
             "tools": [{"tool": "fetch", "description": "Fetch a URL and return text"}],
             "info": {"name": "fetch", "version": "0.3.1"}, "error": None},
            {"name": "filesystem", "status": "ready", "transport": "stdio",
             "tools": [{"tool": "read_file", "description": "Read a file"},
                       {"tool": "list_dir", "description": "List directory"}],
             "info": {"name": "@modelcontextprotocol/server-filesystem",
                      "version": "2025.1.0"},
             "error": None},
            {"name": "weather", "status": "failed", "transport": "sse",
             "tools": [], "info": None,
             "error": "connect ECONNREFUSED 127.0.0.1:8931"},
        ]
        total = sum(len(s["tools"]) for s in servers)
        self._send_json({"servers": servers, "tools": total})

    # ---------- /v1/images/generations ----------

    def _images(self):
        req = self._read_body()
        if req is None:
            return self._send_json({"error": {"message": "Invalid JSON body"}}, status=400)
        prompt = str(req.get("prompt") or "").strip()
        if not prompt:
            return self._send_json({"error": {"message": "prompt 不能为空",
                                              "type": "invalid_request_error"}},
                                   status=400)
        seed = req.get("seed")
        seed = int(seed) if isinstance(seed, int) else random.randrange(1, 2 ** 31)
        w, h = parse_size(req.get("size") or "1024x1024")
        b64 = make_png_b64(w, h, seed)
        # webUI images 表单消费 data[i].b64_json / seed；顶层 size 回显
        self._send_json({"created": int(time.time()),
                         "data": [{"b64_json": b64, "seed": seed}],
                         "size": "%dx%d" % (w, h)})

    # ---------- /v1/chat/completions ----------

    def _chat(self):
        req = self._read_body()
        if req is None:
            return self._send_json({"error": {"message": "Invalid JSON body"}}, status=400)
        rid = RECORDER.start("/v1/chat/completions", MODEL_ID,
                             bool(req.get("stream")),
                             str(req.get("response_format") or "text"))
        if not STATE["loaded"]:
            if not STATE["auto_load"]:
                RECORDER.error(rid, "Model not loaded")
                return self._send_json({"error": {"message": "Model not loaded",
                                                  "type": "invalid_request_error"}},
                                       status=503)
            STATE["loaded"] = True  # auto_load：自动拉起
        messages = req.get("messages") or []
        if not isinstance(messages, list) or not messages:
            RECORDER.error(rid, "messages 不能为空")
            return self._send_json({"error": {"message": "messages 不能为空",
                                              "type": "invalid_request_error"}}, status=400)
        effort = str(req.get("reasoning_effort", "medium")).lower()
        if effort not in EFFORT_PROFILE:
            RECORDER.error(rid, "reasoning_effort 取值必须是 none|low|medium|high")
            return self._send_json({"error": {"message": "reasoning_effort 取值必须是 none|low|medium|high",
                                              "type": "invalid_request_error"}}, status=400)
        think_len, default_ttft = EFFORT_PROFILE[effort]
        ttft = default_ttft if ARGS.ttft == "auto" else float(ARGS.ttft)

        user_text = ""
        for m in reversed(messages):
            if m.get("role") == "user":
                user_text = str(m.get("content", ""))
                break
        prompt_tokens = sum(approx_tokens(str(m.get("content", ""))) for m in messages)
        reasoning = REASONING_TEXT[:think_len] if think_len else ""
        reply = ("收到你的消息：「%s」\n本次思考档位 %s，思考 %d 字，TTFT %.1fs。\n%s"
                 % (user_text[:40], effort, len(reasoning), ttft, REPLY_TAIL))
        completion_tokens = approx_tokens(reply)
        RECORDER.prefilling(rid, prompt_tokens, user_text)

        if not req.get("stream"):
            return self._non_stream(rid, effort, reasoning, reply, prompt_tokens,
                                    user_text)
        return self._stream(rid, req, effort, reasoning, reply, prompt_tokens,
                            user_text, ttft)

    def _non_stream(self, rid, effort, reasoning, reply, prompt_tokens, user_text):
        prompt_ms = random.uniform(200, 900)
        tok_s = random.uniform(40, 80)
        msg = {"role": "assistant", "content": reply}
        if reasoning:
            msg["reasoning_content"] = reasoning
        RECORDER.complete(rid, reply, reasoning, prompt_tokens,
                          approx_tokens(reply), tok_s, prompt_ms / 1000)
        SIM.record_request(prompt_tokens, approx_tokens(reply), prompt_ms, tok_s,
                           prompt_ms / 1000 + approx_tokens(reply) / tok_s,
                           "stop", user_text)
        self._send_json({
            "id": "chatcmpl-mock-" + uuid.uuid4().hex[:8],
            "object": "chat.completion", "created": int(time.time()), "model": MODEL_ID,
            "choices": [{"index": 0, "message": msg, "finish_reason": "stop"}],
            "usage": {"prompt_tokens": prompt_tokens, "completion_tokens": approx_tokens(reply),
                      "total_tokens": prompt_tokens + approx_tokens(reply)},
        })

    def _stream(self, rid, req, effort, reasoning, reply, prompt_tokens,
                user_text, ttft):
        SIM.begin_prefill(prompt_tokens, int(req.get("max_tokens") or 0))
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream; charset=utf-8")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")  # 流结束即断，SSE 不走 keep-alive 复用
        self.end_headers()
        t0 = time.time()
        finish = "stop"
        try:
            cid = "chatcmpl-mock-" + uuid.uuid4().hex[:8]
            base = {"id": cid, "object": "chat.completion.chunk",
                    "created": int(time.time()), "model": MODEL_ID}

            def chunk(delta, finish_reason=None, extra=None):
                # extra：挂在 chunk 顶层的附加字段（strata_mcp 事件走这里）
                c = dict(base)
                if delta or finish_reason is None:
                    c["choices"] = [{"index": 0, "delta": delta,
                                     "finish_reason": finish_reason}]
                else:
                    c["choices"] = [{"index": 0, "delta": {},
                                     "finish_reason": finish_reason}]
                if extra:
                    c.update(extra)
                self.wfile.write(("data: " + json.dumps(c, ensure_ascii=False) + "\n\n").encode("utf-8"))
                self.wfile.flush()

            # TTFT 阶段：长等待期间每 15s 发 SSE 注释保活（真实引擎行为，api-notes §3）
            self._wait_with_keepalive(ttft)
            SIM.begin_decode()
            first_token_s = time.time() - t0
            RECORDER.generating(rid, first_token_s)

            chunk({"role": "assistant", "content": ""})

            # strata_mcp：请求带 strata_mcp:true 时演示一轮工具调用事件流
            # （limit → start → call → result；事件挂 chunk 顶层，对齐 app.js onTool）
            if req.get("strata_mcp"):
                call_id = "mcp-" + uuid.uuid4().hex[:6]
                chunk({}, extra={"strata_mcp": {"event": "limit", "max_rounds": 6}})
                time.sleep(0.3)
                chunk({}, extra={"strata_mcp": {
                    "event": "start", "id": call_id, "name": "fetch",
                    "server": "fetch", "tool": "fetch",
                    "arguments": {"url": "https://example.com/docs"},
                    "round": 1}})
                time.sleep(0.2)
                chunk({}, extra={"strata_mcp": {
                    "event": "call", "id": call_id, "name": "fetch",
                    "server": "fetch", "tool": "fetch",
                    "arguments": {"url": "https://example.com/docs"},
                    "round": 1}})
                time.sleep(0.5)
                chunk({}, extra={"strata_mcp": {
                    "event": "result", "id": call_id,
                    "text": "Example Domain. This domain is for use in illustrative examples.",
                    "ok": True, "chars": 66, "truncated": False, "ms": 512,
                    "skipped": False}})

            for i in range(0, len(reasoning), 3):
                chunk({"reasoning_content": reasoning[i:i + 3]})  # 上游源码已核实字段名
                time.sleep(ARGS.speed)
            for i in range(0, len(reply), 3):
                piece = reply[i:i + 3]
                chunk({"content": piece})
                SIM.add_generated(max(1, len(piece) // 2))
                time.sleep(ARGS.speed)
            # 尾块：上游 Strata 的 choices **非空**（含 finish_reason），usage 挂在块顶层——
            # 与 OpenAI 规范「usage 块 choices 为空数组」不同。M1-11 已按上游真实形态对齐。
            chunk({}, finish_reason="stop")
            tail = dict(base)
            tail["choices"] = [{"index": 0, "delta": {}, "finish_reason": "stop"}]
            tail["usage"] = {"prompt_tokens": prompt_tokens,
                             "completion_tokens": approx_tokens(reply),
                             "total_tokens": prompt_tokens + approx_tokens(reply),
                             "prompt_tokens_details": {"cached_tokens": 0}}
            self.wfile.write(("data: " + json.dumps(tail, ensure_ascii=False) + "\n\n").encode("utf-8"))
            self.wfile.flush()
            self.wfile.write(b"data: [DONE]\n\n")
            self.wfile.flush()
            duration = time.time() - t0
            decode_tok_s = approx_tokens(reply) / max(0.1, duration - ttft)
            RECORDER.complete(rid, reply, reasoning, prompt_tokens,
                              approx_tokens(reply), decode_tok_s, first_token_s)
            SIM.record_request(prompt_tokens, approx_tokens(reply), ttft * 1000,
                               decode_tok_s, duration, finish, user_text)
        except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
            # 客户端中断（如用户停止生成）：记录 disconnect，属正常路径
            RECORDER.disconnect(rid)
            SIM.record_request(prompt_tokens, approx_tokens(reply), ttft * 1000, 0.0,
                               time.time() - t0, "disconnect", user_text)
        finally:
            SIM.end_request()

    def _wait_with_keepalive(self, seconds):
        """等待 seconds 秒；期间每 KEEPALIVE_INTERVAL 秒发一行 SSE 注释（: keep-alive）。"""
        deadline = time.time() + seconds
        last = time.time()
        while time.time() < deadline:
            time.sleep(0.1)
            now = time.time()
            if now - last >= KEEPALIVE_INTERVAL:
                self.wfile.write(b": keep-alive\n\n")
                self.wfile.flush()
                last = now


def main():
    global ARGS
    ap = argparse.ArgumentParser(description="Mock Strata server (M1-3 / M2-10)")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=8420)
    ap.add_argument("--api-key", default="", help="非空则强制 Bearer 鉴权（空=开发模式不鉴权）")
    ap.add_argument("--speed", type=float, default=0.04, help="流式分块间隔秒数")
    ap.add_argument("--ttft", default="auto", help="auto=按档位；或指定秒数（验证 15s 保活）")
    ap.add_argument("--api-monitor", default="on", choices=["on", "off"],
                    help="off=模拟真实 svc.api_monitor 默认关闭（/api/requests → 404）")
    ARGS = ap.parse_args()
    STATE["api_monitor"] = ARGS.api_monitor == "on"

    server = ThreadingHTTPServer((ARGS.host, ARGS.port), MockHandler)
    server.daemon_threads = True
    auth = "鉴权开启（Bearer %s…）" % ARGS.api_key[:6] if ARGS.api_key else "开发模式（不鉴权）"
    print("Mock Strata 服务已启动: http://%s:%d  [%s]" % (ARGS.host, ARGS.port, auth), flush=True)
    print("GET : /v1/models /health /metrics[?requests=all|&format=prometheus] /props /status "
          "/v1/status /api/requests[?id=] /config /settings /mcp", flush=True)
    print("POST: /v1/chat/completions /v1/images/generations /load /unload "
          "/v1/load /v1/unload /config /settings", flush=True)
    print("API Monitor: %s" % ("on" if STATE["api_monitor"] else "off（/api/requests → 404）"),
          flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n已停止", flush=True)


if __name__ == "__main__":
    main()
