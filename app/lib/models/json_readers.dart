// JSON 宽容读取助手（v0.0.8 真机反馈修复）。
//
// 真机反馈：App 监控页与 About 页同时降级，错误为
//   "type 'int' is not a subtype of type 'String?' in type cast"
// 而同一主机的 webUI（#monitor / #about）完全正常。
//
// 根因（strata_ref/serve/server.py:1073）：引擎 INFO 行的 `key=value` 中，
// **纯数字的值会被转成 int**：
//   self.info[k] = int(v) if v.lstrip("-").isdigit() else v
// 引擎实际输出（src/program/generate.cpp:11114）：
//   INFO logit_bias=1 context=262144 kv=int8 kv_resident=0 expert_slots=... spec=6 mtp_max=4 lookup=3 ...
// 于是 /metrics 的 engine 段里 spec / mtp_max / lookup 是 **int**，
// 而 `images` 是服务端直接给的 **bool**（server.py:4737 `self.vision is not None`）。
//
// webUI 不报错是因为 JS 全部用真值判断与隐式转换；
// Dart 的 `as String?` 是运行时硬断言，类型不符直接抛异常 → 整个 /metrics 解析失败
// → 监控页与 About 页同时降级（两个页面共用同一份解析结果）。
//
// 修复：所有字段改为宽容读取，类型不符时取合理默认值（null / 0），
// 绝不因单个字段的类型差异让整份响应解析失败。

/// 宽容读取字符串：num/bool → 其字符串形式；其他非 String → null
String? readStr(Map<String, dynamic> j, String key) {
  final v = j[key];
  if (v == null) return null;
  if (v is String) return v;
  if (v is num || v is bool) return v.toString();
  return null;
}

/// 宽容读取 int：num → 舍入取整；String 数字 → 解析；其他 → null
int? readInt(Map<String, dynamic> j, String key) {
  final v = j[key];
  if (v == null) return null;
  if (v is int) return v;
  if (v is double) return v.round();
  if (v is String) return int.tryParse(v.trim());
  return null;
}

/// 宽容读取 double：num → toDouble；String 数字 → 解析；其他 → null
double? readDouble(Map<String, dynamic> j, String key) {
  final v = j[key];
  if (v == null) return null;
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v.trim());
  return null;
}

/// 宽容读取 bool：bool → 原值；num → !=0；String → 'true'/'1'/'on'/'yes'
bool? readBool(Map<String, dynamic> j, String key) {
  final v = j[key];
  if (v == null) return null;
  if (v is bool) return v;
  if (v is num) return v != 0;
  if (v is String) {
    final t = v.trim().toLowerCase();
    if (const {'true', '1', 'on', 'yes'}.contains(t)) return true;
    if (const {'false', '0', 'off', 'no'}.contains(t)) return false;
  }
  return null;
}
