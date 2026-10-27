// models 层：纯数据模型，不依赖 Flutter UI。
// M1-4：strata_models.dart（接口模型 + 流事件）。
// M1-5：connection_profile.dart（连接配置，对应 SPEC §9 ServerProfile）。
// M1-6：chat_models.dart（UI 渲染层消息，含流式中间态）。
// 后续：SystemMetrics（M2）等按任务填充。
export 'chat_models.dart';
export 'connection_profile.dart';
export 'strata_models.dart';
