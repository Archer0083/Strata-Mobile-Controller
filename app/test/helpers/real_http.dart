// 测试 helper：testWidgets 环境真连网络的 HttpOverrides 逃生通道（M1-5 踩坑固化）。
//
// flutter_test 在 TestWidgetsFlutterBinding 下全局安装 _MockHttpOverrides
// （flutter_test/lib/src/_binding_io.dart）：所有 dart:io HTTP 请求被替换为
// 固定的空 400 响应，不发真实网络请求。真连 Mock 的用例须：
//   await tester.runAsync(() => realHttp(() => ...));   // 双保险
// 其中 runAsync 让 fake zone 推进真实 socket 事件，本 helper 摘除假 client。

import 'dart:io';

/// 空 HttpOverrides：createHttpClient 走默认实现（真实 HttpClient）。
class RealHttpOverrides extends HttpOverrides {}

/// 在真实 HTTP 环境中执行 [body]。
Future<T> realHttp<T>(Future<T> Function() body) =>
    HttpOverrides.runWithHttpOverrides<Future<T>>(body, RealHttpOverrides());
