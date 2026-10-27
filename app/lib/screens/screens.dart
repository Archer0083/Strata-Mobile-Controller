// screens 层：纯展示与交互，业务逻辑下沉 services/providers。
// M1-5：connection_screen.dart（连接表单）、home_shell.dart（底部导航骨架）。
// M1-6：chat_screen.dart（流式对话 / reasoning 折叠 / 档位选择器）。
// M1-7：monitor_screen.dart（存活/模型/延迟骨架 + WebUI 兜底）。
// M1-8：settings_screen.dart（多 Profile 列表/激活/编辑/删除）。
// v0.0.9：about_screen.dart 提为一级页、session_data_screen.dart（会话数据独立页）、
//          session_data_section.dart（可复用的会话数据区块）、control_screen.dart、
//          export_sheet.dart、import_preview_dialog.dart、conversation_drawer.dart、
//          images_screen.dart。
// 后续：/metrics 指标扩展（M2）。
export 'about_screen.dart';
export 'chat_screen.dart';
export 'connection_screen.dart';
export 'control_screen.dart';
export 'conversation_drawer.dart';
export 'export_sheet.dart';
export 'home_shell.dart';
export 'images_screen.dart';
export 'import_preview_dialog.dart';
export 'monitor_screen.dart';
export 'session_data_screen.dart';
export 'session_data_section.dart';
export 'settings_screen.dart';
