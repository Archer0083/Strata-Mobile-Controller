// ThemeMode Provider（M2-1）：深浅主题持久化切换。
//
// 模式：system / light / dark 三态，持久化到 shared_preferences
// （key=kThemeModeKey，非敏感）。MaterialApp.themeMode 消费。
// About 页开关（M2-3）与设置页入口共用本 provider。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'connection_provider.dart' show sharedPrefsProvider;

/// 持久化 key。
const kThemeModeKey = 'theme_mode';

/// 主题模式 provider：启动由 main() 依 prefs 预读注入，运行时切换写回。
///
/// 读取共享 prefs；未记录时 null（MaterialApp 回退 system）。
final themeModeProvider = StateNotifierProvider<ThemeModeController, ThemeMode?>((ref) {
  return ThemeModeController(ref.watch(sharedPrefsProvider));
});

class ThemeModeController extends StateNotifier<ThemeMode?> {
  ThemeModeController(this._prefs, [ThemeMode? initial]) : super(initial);

  final SharedPreferences _prefs;

  /// 从 prefs 读取启动模式（main() 调用；无记录返回 null = 跟随系统）。
  static ThemeMode? readStartup(SharedPreferences prefs) {
    final s = prefs.getString(kThemeModeKey);
    if (s == 'light') return ThemeMode.light;
    if (s == 'dark') return ThemeMode.dark;
    return null;
  }

  /// 设置模式并持久化（null = 跟随系统，清记录）。
  Future<void> set(ThemeMode? mode) async {
    state = mode;
    if (mode == null) {
      await _prefs.remove(kThemeModeKey);
    } else {
      await _prefs.setString(kThemeModeKey, mode.name);
    }
  }
}
