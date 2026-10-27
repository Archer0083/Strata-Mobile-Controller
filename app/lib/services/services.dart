// services 层：网络与存储服务，不依赖 Flutter UI，保证可单测。
// M1-4：strata_client.dart（dio 封装：超时 / Bearer / SSE 手动解析 / 幂等 GET 重试）。
// 后续：SecureStorageService（M1-5）等按任务填充。
export 'strata_client.dart';
