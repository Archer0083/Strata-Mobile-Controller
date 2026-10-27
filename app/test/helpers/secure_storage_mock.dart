// 测试辅助：flutter_secure_storage 的 MethodChannel 内存 Mock。
// widget/集成测试环境下插件 channel 不可用，用内存 Map 模拟读写删，
// 使 profilesProvider / ConnectionController.save() 可在测试中真实运行。

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
final Map<String, String> _store = {};

void mockSecureStorage() {
  TestWidgetsFlutterBinding.ensureInitialized();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_channel, (call) async {
    final args = Map<String, dynamic>.from(call.arguments as Map? ?? {});
    switch (call.method) {
      case 'read':
        return _store[args['key'] as String?];
      case 'write':
        _store[args['key'] as String? ?? ''] = args['value'] as String? ?? '';
        return null;
      case 'delete':
        _store.remove(args['key'] as String?);
        return null;
      case 'readAll':
        return Map<String, String>.of(_store);
      case 'deleteAll':
        _store.clear();
        return null;
      case 'containsKey':
        return _store.containsKey(args['key'] as String?);
      default:
        return null;
    }
  });
}
