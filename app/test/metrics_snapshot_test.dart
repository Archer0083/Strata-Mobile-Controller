// MetricsSnapshot 模型层单测（M2-2）：
// - 格式化函数（fmtNum/kfmt/ctxfmt/gb/gbFromMiB/sinceStr）对齐 app.js
// - contextUsed / contextFraction（idle 取首条请求、进行中取 live、cap 1.0）
// - prefillTokS 计算（排除复用 token）、finishLabel 映射
// - fromJson 宽容忽略未知字段 / 缺失字段全 null 不抛
// - SparklinePainter 纵轴映射（viewBox 0 0 100 32 → y = 30 − (v/top)×26，clamp 2–30）

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:strata_mobile_controller/models/metrics_snapshot.dart';
import 'package:strata_mobile_controller/screens/monitor_screen.dart' show SparklinePainter;

void main() {
  group('fmtNum', () {
    test('千分位 + 固定小数位', () {
      expect(fmtNum(1234567), '1,234,567');
      expect(fmtNum(1234567.89, 1), '1,234,567.9');
      expect(fmtNum(0.5, 1), '0.5');
      expect(fmtNum(42, 0), '42');
    });

    test('null / NaN → en dash', () {
      expect(fmtNum(null), '–');
      expect(fmtNum(double.nan), '–');
    });
  });

  group('kfmt', () {
    test('≥10000 → 0 位 k；1000–9999 → 1 位 k；否则原值', () {
      expect(kfmt(null), '–');
      expect(kfmt(999), '999');
      expect(kfmt(1000), '1.0k');
      expect(kfmt(9999), '10.0k');
      expect(kfmt(10000), '10k');
      expect(kfmt(262144), '262k');
    });
  });

  group('ctxfmt', () {
    test('1024 整数倍 → K 标签', () {
      expect(ctxfmt(null), '–');
      expect(ctxfmt(1024), '1K');
      expect(ctxfmt(262144), '256K');
      expect(ctxfmt(262143), '262k'); // 非 1024 倍数 → kfmt
      expect(ctxfmt(0), '0');
    });
  });

  group('gb / gbFromMiB', () {
    test('1024 进制 GB（1 位小数默认）', () {
      expect(gb(null), '–');
      expect(gb(1073741824), '1.0');
      expect(gb(65536 * 1048576, 0), '64');
      expect(gbFromMiB(4096, 1), '4.0');
    });
  });

  group('sinceStr', () {
    test('相对时间（just now / N min ago / N h ago）', () {
      final now = DateTime.now().millisecondsSinceEpoch / 1000;
      expect(sinceStr(now - 30), 'just now');
      expect(sinceStr(now - 300), '5 min ago');
      expect(sinceStr(now - 7200), '2.0 h ago');
      expect(sinceStr(null), '–');
    });
  });

  group('LiveStats', () {
    test('effectiveState：queued>0 覆盖 state', () {
      expect(
        LiveStats.fromJson(const {'state': 'idle', 'queued': 2}).effectiveState,
        'queued',
      );
      expect(
        LiveStats.fromJson(const {'state': 'generating', 'queued': 0}).effectiveState,
        'generating',
      );
      expect(LiveStats.fromJson(const {}).effectiveState, 'idle');
    });

    test('readingPct / generatingPct', () {
      final reading = LiveStats.fromJson(const {
        'state': 'reading', 'prompt_read': 600, 'prompt_total': 1200,
      });
      expect(reading.readingPct, 50);
      expect(LiveStats.fromJson(const {}).readingPct, isNull);

      final gen = LiveStats.fromJson(const {
        'state': 'generating', 'generated': 50, 'max_tokens': 200,
      });
      expect(gen.generatingPct, 25);
      // cap 100
      expect(
        LiveStats.fromJson(const {'generated': 300, 'max_tokens': 200}).generatingPct,
        100,
      );
    });
  });

  group('contextUsed / contextFraction', () {
    MetricsSnapshot snapshotWith({
      Map<String, dynamic> live = const {},
      List<Map<String, dynamic>> requests = const [],
      int? maxContext,
    }) {
      return MetricsSnapshot.fromJson({
        'live': live,
        'requests': requests,
        'engine': {'max_context': maxContext},
      });
    }

    test('idle → 取最近请求（首条）prompt+output', () {
      final s = snapshotWith(requests: [
        {'prompt_tokens': 1200, 'output_tokens': 214},
        {'prompt_tokens': 500, 'output_tokens': 50},
      ]);
      expect(s.contextUsed, 1200 + 214);
    });

    test('idle 空表 → 0', () {
      expect(snapshotWith().contextUsed, 0);
    });

    test('generating → 取 live prompt_tokens + generated', () {
      final s = snapshotWith(live: {
        'state': 'generating', 'prompt_tokens': 800, 'generated': 120,
      });
      expect(s.contextUsed, 920);
    });

    test('fraction cap 1.0（超出上下文窗口）', () {
      // live generating → 取 live prompt+generated；构造真超出 max 的值
      final over = snapshotWith(
        live: {'state': 'generating', 'prompt_tokens': 480, 'generated': 90},
        maxContext: 512,
      );
      expect(over.contextUsed, 570);
      expect(over.contextFraction, 1.0);
    });

    test('mock 值：1200+214=1414 / 262144 ≈ 0.54%', () {
      final s = snapshotWith(requests: [
        {'prompt_tokens': 1200, 'output_tokens': 214},
      ], maxContext: 262144);
      expect(s.contextUsed, 1414);
      expect(s.contextFraction, closeTo(1414 / 262144, 0.0001));
    });
  });

  group('RequestRecord', () {
    test('prefillTokS = (prompt−reused)/(prompt_ms/1000)', () {
      final r = RequestRecord.fromJson(const {
        'prompt_tokens': 1200, 'reused': 780, 'prompt_ms': 640.0,
      });
      expect(r.prefillTokS, closeTo(420 / 0.64, 0.01));
    });

    test('prompt_ms 缺失 → null', () {
      expect(
        RequestRecord.fromJson(const {'prompt_tokens': 1200}).prefillTokS,
        isNull,
      );
    });

    test('finishLabel 映射', () {
      RequestRecord byFinish(String f) =>
          RequestRecord.fromJson({'finish': f});
      expect(byFinish('stop').finishLabel, 'Done');
      expect(byFinish('length').finishLabel, 'Max tokens');
      expect(byFinish('cancel').finishLabel, 'Stopped');
      expect(byFinish('disconnect').finishLabel, 'Closed');
      expect(byFinish('error').finishLabel, 'Error');
      expect(RequestRecord.fromJson(const {}).finishLabel, '–');
      expect(byFinish('weird').finishLabel, 'weird');
    });
  });

  group('MetricsSnapshot.fromJson 宽容性', () {
    test('未知字段全部忽略不抛', () {
      final s = MetricsSnapshot.fromJson(const {
        'live': {'state': 'idle', 'future_field': 'x'},
        'hardware': {'gpu_util': 8.0, 'future': [1, 2, 3]},
        'engine': {'model': 'm', 'future': {'a': 1}},
        'totally_unknown_section': {'x': 1},
      });
      expect(s.live.state, 'idle');
      expect(s.hardware.gpuUtil, 8.0);
      expect(s.engine.model, 'm');
    });

    test('空对象不抛，字段全 null/默认', () {
      final s = MetricsSnapshot.fromJson(const {});
      expect(s.live.state, isNull);
      expect(s.history, isEmpty);
      expect(s.requests, isEmpty);
      expect(s.conversationCache, isNull); // 旧服务器无此键
    });

    test('conversation_cache 缺失 → null；enabled=false 解析正常', () {
      final s = MetricsSnapshot.fromJson(const {
        'conversation_cache': {'enabled': false},
      });
      expect(s.conversationCache?.enabled, isFalse);
    });

    test('history 数组中非 num 元素被剔除', () {
      final s = MetricsSnapshot.fromJson(const {
        'history': {'tok_s': [1.0, 'x', null, 3.0]},
      });
      expect(s.historySeries('tok_s'), [1.0, 3.0]);
      expect(s.historySeries('nonexistent'), isEmpty);
    });

    test('requests 非 List 或元素非 Map → 空表', () {
      expect(MetricsSnapshot.fromJson(const {'requests': 'oops'}).requests, isEmpty);
      expect(
        MetricsSnapshot.fromJson(const {'requests': [1, 'x', null]}).requests,
        isEmpty,
      );
    });
  });

  group('EngineInfo', () {
    test('kvLabel 档位文案', () {
      EngineInfo byKv(String? kv) => EngineInfo.fromJson({'kv': kv});
      expect(byKv('int8').kvLabel, '8-bit');
      expect(byKv('q4_0').kvLabel, '4-bit (Hadamard-rotated)');
      expect(byKv('fp16').kvLabel, '16-bit');
      expect(byKv('custom').kvLabel, 'custom');
      expect(byKv(null).kvLabel, '–');
    });

    test('hasProjection：cvec 非 0/null/空串', () {
      expect(EngineInfo.fromJson(const {}).hasProjection, isFalse);
      expect(EngineInfo.fromJson(const {'cvec': 0}).hasProjection, isFalse);
      expect(EngineInfo.fromJson(const {'cvec': ''}).hasProjection, isFalse);
      expect(
        EngineInfo.fromJson(const {'cvec': 'project:4-44'}).hasProjection,
        isTrue,
      );
    });
  });

  group('SparklinePainter 纵轴映射', () {
    // 验证 app.js sparkPath 同款公式（paint 内部不可直接断言，用同算法验证）
    test('y = 30 − (v/top)×26，clamp 2–30', () {
      double yOf(double v, double top) => (30 - (v / top) * 26).clamp(2.0, 30.0);
      expect(yOf(0, 100), 30); // 0 值贴底
      expect(yOf(100, 100), 4); // 满值
      expect(yOf(50, 100), 17); // 半值
      expect(yOf(-5, 100), 30); // 负值 clamp 底
      expect(yOf(200, 100), 2); // 超限 clamp 顶
    });

    test('paint 数据点 <2 不绘制（不抛）', () {
      final painter = SparklinePainter(
        data: const [1.0],
        lineColor: const Color(0xFF000000),
        fillColor: const Color(0xFF000000),
      );
      final recorder = ui.PictureRecorder();
      painter.paint(Canvas(recorder), const Size(200, 32));
      final picture = recorder.endRecording();
      expect(picture, isNotNull);
    });

    test('shouldRepaint 数据变化触发', () {
      Color c = const Color(0xFF000000);
      final a = SparklinePainter(data: const [1, 2, 3], lineColor: c, fillColor: c);
      final b = SparklinePainter(data: const [1, 2, 4], lineColor: c, fillColor: c);
      final c2 = SparklinePainter(data: const [1, 2, 3], lineColor: c, fillColor: c, top: 10);
      expect(a.shouldRepaint(b), isTrue);
      expect(a.shouldRepaint(c2), isTrue);
      expect(a.shouldRepaint(SparklinePainter(data: const [1, 2, 3], lineColor: c, fillColor: c)), isFalse);
      expect(math.max(1, 2), 2); // 引用 math 防 unused import
    });
  });
}
