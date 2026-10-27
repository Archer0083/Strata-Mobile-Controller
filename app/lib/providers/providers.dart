// providers 层：Riverpod Provider 定义，桥接 services → screens。
// M1-5：connection_provider.dart（Profile 持久化 / 当前连接 / 表单状态 / 测试连接）。
// M1-6：chat_provider.dart（消息列表 / 发送阶段 / 思考档位）。
// M1-7：monitor_provider.dart（health + models 快照；/metrics 属 M2）。
// 后续：MonitorProvider 扩展 /metrics（M2）、ControlProvider（M2）等。
export 'chat_provider.dart';
export 'connection_provider.dart';
export 'monitor_provider.dart';
