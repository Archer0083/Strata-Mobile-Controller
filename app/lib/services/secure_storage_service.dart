// SecureStorageService（M1-5）：Profile 列表（含 API Key）的持久化。
// 全量 JSON 存于 flutter_secure_storage 单键——iOS Keychain / Android Keystore
// 加密由插件承担；M1-8 多 Profile 与 M2 期数据结构演进时再考虑拆键。

import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../models/connection_profile.dart';

class SecureStorageService {
  SecureStorageService({FlutterSecureStorage? storage}) : _storage = storage ?? const FlutterSecureStorage();

  static const _profilesKey = 'strata_profiles';

  final FlutterSecureStorage _storage;

  Future<List<ConnectionProfile>> loadProfiles() async {
    final raw = await _storage.read(key: _profilesKey);
    if (raw == null || raw.isEmpty) return const [];
    final list = jsonDecode(raw) as List;
    return list.map((e) => ConnectionProfile.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<void> saveProfiles(List<ConnectionProfile> profiles) =>
      _storage.write(key: _profilesKey, value: jsonEncode(profiles.map((p) => p.toJson()).toList()));
}
