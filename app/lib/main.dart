// App 入口（M1-5）：ProviderScope 包裹；启动时读已存 Profile——
// 无配置进 ConnectionScreen，有配置直接进主页骨架。
// M1-8：main() 初始化 SharedPreferences + 预读 Profile 列表，按持久化激活 id
// 解析启动 Profile 并 overrideWith 注入（不可在 widget 生命周期内改 provider）。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'providers/connection_provider.dart';
import 'providers/theme_provider.dart';
import 'screens/connection_screen.dart';
import 'screens/home_shell.dart';
import 'services/secure_storage_service.dart';
import 'theme/trae_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  // 启动恢复：secure_storage 全量读一次 + prefs 激活 id → 解析应激活的 Profile
  final profiles = await SecureStorageService().loadProfiles();
  final startup = resolveStartupProfile(profiles, prefs.getString(kActiveProfileIdKey));
  final startupTheme = ThemeModeController.readStartup(prefs);
  runApp(ProviderScope(
    overrides: [
      sharedPrefsProvider.overrideWithValue(prefs),
      currentProfileProvider.overrideWith((_) => startup),
      themeModeProvider.overrideWith(
          (ref) => ThemeModeController(ref.watch(sharedPrefsProvider), startupTheme)),
    ],
    child: const StrataApp(),
  ));
}

class StrataApp extends ConsumerWidget {
  const StrataApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(themeModeProvider);
    return MaterialApp(
      title: '本地模型移动控制端',
      debugShowCheckedModeBanner: false,
      theme: TraeTheme.light,
      darkTheme: TraeTheme.dark,
      themeMode: mode ?? ThemeMode.system,
      home: const _SplashGate(),
    );
  }
}

/// 启动分派：有已存配置直接进主页骨架（激活项已由 main() 恢复注入），
/// 无配置进连接页。不在 build 中修改 provider（Riverpod 约束）。
class _SplashGate extends ConsumerWidget {
  const _SplashGate();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profiles = ref.watch(profilesProvider);
    return profiles.when(
      loading: () => const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (e, _) => Scaffold(
        body: Center(child: Text('读取配置失败：$e\n请重启 App 或清除应用数据', textAlign: TextAlign.center)),
      ),
      data: (list) => list.isNotEmpty ? const HomeShell() : const ConnectionScreen(),
    );
  }
}
