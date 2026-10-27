// v0.0.8 真机反馈回归测试：/metrics 解析的**类型宽容性**。
//
// 【背景·为什么有这个文件】
// v0.0.7 真机反馈：监控页与 About 页**同时**降级，错误为
//   "type 'int' is not a subtype of type 'String?' in type cast"
// 而同一主机的 webUI（#monitor / #about）完全正常。
//
// 根因（strata_ref/serve/server.py:1073）：引擎 INFO 行的 `key=value` 中，
// **纯数字的值会被服务端转成 int**：
//   self.info[k] = int(v) if v.lstrip("-").isdigit() else v
// 引擎实际输出（strata_ref/src/program/generate.cpp:11114-11116）：
//   INFO logit_bias=1 context=262144 kv=int8 kv_resident=0 expert_slots=3550
//        expert_cache_mib=355000 spec=6 mtp_max=4 lookup=3 ...
// 于是 /metrics 的 engine 段里 spec / mtp_max / lookup 是 **int**；
// 而 `images` 是服务端直接给的 **bool**（server.py:4737 `self.vision is not None`）。
//
// webUI 不报错是因为 JS 全部用真值判断与隐式转换；
// Dart 的 `as String?` 是运行时**硬断言**，类型不符直接抛异常
// → 整份 /metrics 解析失败 → 监控页与 About 页同时降级（两页共用同一份快照）。
//
// 【本文件的教训】
// 既有 metrics_snapshot_test.dart 的 mock **全部手写**，字段类型"恰好正确"，
// 从未覆盖真实引擎的 int / bool 值 → 带着必然失败的缺陷连发三轮版本。
// 本文件用**真实主机的 /metrics 样本**（含 int/bool 混合类型）做回归，
// 保证同类类型差异再也不会让整页降级。

import 'package:flutter_test/flutter_test.dart';
import 'package:strata_mobile_controller/models/api_models.dart';
import 'package:strata_mobile_controller/models/json_readers.dart';
import 'package:strata_mobile_controller/models/metrics_snapshot.dart';

/// 真实主机的 engine 段样本（INFO 行 → server.py:1073 数字转 int 后）。
/// spec / mtp_max / lookup = int，images = bool。
Map<String, dynamic> realEngineMap() => <String, dynamic>{
      'model': 'qwen3.8-flash-next-iq3_s',
      'version': '0.1.47',
      'max_context': 262144,
      'kv': 'int8',
      'kv_resident': 0,
      'expert_slots': 3550,
      'expert_cache_mib': 355000,
      'spec': 6,
      'mtp_max': 4,
      'lookup': 3,
      'images': true,
      'cvec': 0,
    };

/// 真实主机的完整 /metrics 顶层样本（数值字段一律 int/double，无手写 string 化）。
Map<String, dynamic> realMetricsMap() => <String, dynamic>{
      'live': <String, dynamic>{
        'state': 'idle',
        'prompt_read': 0,
        'prompt_total': 0,
        'prompt_tokens': 0,
        'generated': 0,
        'max_tokens': 0,
        'tok_s': 59.7,
        'prefill_tok_s_mean': 0.0,
        'queued': 0,
        'phase': '',
      },
      'hardware': <String, dynamic>{
        'gpu_util': 0.0,
        'gpu_mem_used': 9568355840.0,
        'gpu_mem_total': 10737418240.0,
        'gpu_temp': 42.0,
        'gpu_power': 120.5,
        'gpu_power_limit': 300.0,
        'gpu_pcie_gen': 4,
        'gpu_pcie_gen_max': 4,
        'gpu_pcie_width': 16,
        'gpu_pcie_rx_mb': 0.0,
        'cpu': 3.25,
        'ram_used': 21474836480.0,
        'ram_total': 34359738368.0,
        'disk_read_mb': 1.0,
        'disk_write_mb': 0.5,
        'psutil': true,
        'gpus': <Map<String, dynamic>>[
          <String, dynamic>{
            'index': 0,
            'util': 12.5,
            'mem_used': 9568355840.0,
            'temp': 42.0,
          },
        ],
      },
      'hardware_static': <String, dynamic>{
        'gpu_name': 'NVIDIA GeForce RTX 5080',
        'gpu_note': '',
        'cpu_name': 'AMD Ryzen 9 9950X',
        'cores': 32,
        'threads': 64,
      },
      'engine': realEngineMap(),
      'history': <String, dynamic>{
        'tok_s': <double>[59.7, 60.1, 58.9],
      },
      'requests': <Map<String, dynamic>>[
        <String, dynamic>{
          'time': 1793068800.0,
          'finish': 'stop',
          'projection': false,
          'prompt_tokens': 128,
          'reused': 0,
          'output_tokens': 256,
          'prompt_ms': 210.5,
          'decode_tok_s': 59.7,
          'hit_rate': 0.0,
          'pcie_share': 1.0,
          'duration_s': 4.5,
        },
      ],
      'totals': <String, dynamic>{
        'since': 1793060000.0,
        'requests': 42,
        'prompt_tokens': 5120,
        'reused': 1024,
        'prompt_ms': 8400.0,
        'output_tokens': 8192,
        'decode_ms': 137000.0,
      },
      'conversation_cache': <String, dynamic>{
        'enabled': true,
        'parked': <String>[],
        'slots': 4,
        'budget_mib': 4096.0,
        'bytes': 1048576.0,
        'requests': 10,
        'requests_reused': 3,
        'prompt_tokens': 900,
        'reused_tokens': 300,
        'parks': 2,
        'restores': 1,
        'evictions': 0,
        'last_event': 'park',
        'last_tokens': 256,
        'last_at': 1793068700.0,
        'last_prompt': 'hello',
        'last_reused': true,
      },
    };

void main() {
  group('json_readers 宽容读取', () {
    test('readStr：num/bool → 字符串；其他类型 → null', () {
      expect(readStr(const {'k': 6}, 'k'), '6');
      expect(readStr(const {'k': 6.5}, 'k'), '6.5');
      expect(readStr(const {'k': true}, 'k'), 'true');
      expect(readStr(const {'k': 'x'}, 'k'), 'x');
      expect(readStr(const {'k': <int>[1]}, 'k'), isNull);
      expect(readStr(const {}, 'k'), isNull);
    });

    test('readInt：int/double/String 数字 → int；其他 → null', () {
      expect(readInt(const {'k': 6}, 'k'), 6);
      expect(readInt(const {'k': 6.7}, 'k'), 7);
      expect(readInt(const {'k': '6'}, 'k'), 6);
      expect(readInt(const {'k': ' 6 '}, 'k'), 6);
      expect(readInt(const {'k': 'abc'}, 'k'), isNull);
      expect(readInt(const {'k': true}, 'k'), isNull);
      expect(readInt(const {}, 'k'), isNull);
    });

    test('readDouble：num/String 数字 → double；其他 → null', () {
      expect(readDouble(const {'k': 6}, 'k'), 6.0);
      expect(readDouble(const {'k': 6.5}, 'k'), 6.5);
      expect(readDouble(const {'k': '6.5'}, 'k'), 6.5);
      expect(readDouble(const {'k': 'abc'}, 'k'), isNull);
      expect(readDouble(const {'k': true}, 'k'), isNull);
    });

    test('readBool：bool 原值；num → !=0；String → 关键字', () {
      expect(readBool(const {'k': true}, 'k'), isTrue);
      expect(readBool(const {'k': false}, 'k'), isFalse);
      expect(readBool(const {'k': 1}, 'k'), isTrue);
      expect(readBool(const {'k': 0}, 'k'), isFalse);
      expect(readBool(const {'k': 'true'}, 'k'), isTrue);
      expect(readBool(const {'k': 'off'}, 'k'), isFalse);
      expect(readBool(const {'k': 'maybe'}, 'k'), isNull);
      expect(readBool(const {}, 'k'), isNull);
    });
  });

  group('真实 /metrics 样本解析（v0.0.8 核心回归）', () {
    test('整份样本不抛异常（v0.0.7 的 type cast 崩溃点）', () {
      expect(() => MetricsSnapshot.fromJson(realMetricsMap()), returnsNormally);
    });

    test('engine 段：spec / lookup 为 int 也能解析成字符串', () {
      final e = MetricsSnapshot.fromJson(realMetricsMap()).engine;
      expect(e.spec, '6');
      expect(e.mtpMax, 4);
      expect(e.lookup, '3');
      expect(e.model, 'qwen3.8-flash-next-iq3_s');
      expect(e.maxContext, 262144);
      expect(e.kv, 'int8');
      expect(e.expertSlots, 3550);
    });

    test('engine.images 为 bool true → imagesEnabled == true', () {
      final e = MetricsSnapshot.fromJson(realMetricsMap()).engine;
      expect(e.images, 'true');
      expect(e.imagesEnabled, isTrue);
    });

    test('images 为 bool false → imagesEnabled == false（不误显示 on）', () {
      final m = realMetricsMap();
      (m['engine'] as Map<String, dynamic>)['images'] = false;
      final e = MetricsSnapshot.fromJson(m).engine;
      expect(e.images, 'false');
      expect(e.imagesEnabled, isFalse);
    });

    test('images 为字符串 "false" / "0" → 也视为关闭', () {
      for (final v in const ['false', '0', 'off', 'no', '']) {
        final m = realMetricsMap();
        (m['engine'] as Map<String, dynamic>)['images'] = v;
        expect(MetricsSnapshot.fromJson(m).engine.imagesEnabled, isFalse,
            reason: 'images="$v" 应视为关闭');
      }
    });

    test('其他段同样容忍类型差异（不因单字段炸整页）', () {
      final s = MetricsSnapshot.fromJson(realMetricsMap());
      expect(s.live.tokS, 59.7);
      expect(s.hardware.psutil, isTrue);
      expect(s.hardware.gpus.single.index, 0);
      expect(s.hardwareStatic.cores, 32);
      expect(s.requests.single.finish, 'stop');
      expect(s.totals.requests, 42);
      expect(s.conversationCache!.enabled, isTrue);
      expect(s.conversationCache!.parked, 0);
      expect(s.conversationCache!.lastReused, isTrue);
    });

    test('engine 段字段类型全部错乱（如 spec 为 "6" 字符串）也不抛', () {
      final m = realMetricsMap();
      (m['engine'] as Map<String, dynamic>)['spec'] = '6';
      (m['engine'] as Map<String, dynamic>)['mtp_max'] = '4';
      (m['engine'] as Map<String, dynamic>)['lookup'] = '3';
      expect(() => MetricsSnapshot.fromJson(m), returnsNormally);
      final e = MetricsSnapshot.fromJson(m).engine;
      expect(e.spec, '6');
      expect(e.mtpMax, 4);
      expect(e.lookup, '3');
    });
  });

  group('EngineStatus / EngineProps 宽容解析（api_models.dart 同类隐患）', () {
    test('EngineStatus：loaded 为 int/string 亦可', () {
      expect(EngineStatus.fromJson(const {'loaded': true}).loaded, isTrue);
      expect(EngineStatus.fromJson(const {'loaded': 'true'}).loaded, isTrue);
      expect(EngineStatus.fromJson(const {'loaded': 1}).loaded, isTrue);
      expect(EngineStatus.fromJson(const {}).loaded, isFalse);
    });

    test('EngineStatus.activity.in_flight 为字符串数字亦可', () {
      final s = EngineStatus.fromJson(const {
        'model': 'm',
        'loaded': true,
        'activity': {'in_flight': '2'},
      });
      expect(s.inFlight, 2);
      expect(s.stateLabel, 'In use');
    });

    test('EngineProps：context_length 为字符串数字亦可', () {
      final p = EngineProps.fromJson(const {
        'model': 'm',
        'context_length': '262144',
      });
      expect(p.contextLength, 262144);
    });

    test('EngineProps：modalities.vision 为字符串亦可', () {
      final p = EngineProps.fromJson(const {
        'model': 'm',
        'modalities': {'vision': 'true'},
      });
      expect(p.vision, isTrue);
    });
  });
}
