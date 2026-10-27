// 连接配置（M1-5）：对应 SPEC §9 ServerProfile。
// apiKey 仅存在于内存与 flutter_secure_storage（Android Keystore 加密），不进日志不上云。

class ConnectionProfile {
  const ConnectionProfile({
    required this.id,
    required this.name,
    required this.host,
    required this.port,
    this.apiKey,
    this.useWireGuardOnly = true,
    required this.createdAt,
  });

  final String id;
  final String name;
  final String host; // IPv4 或主机名（推荐 WireGuard 虚拟 IP，如 10.0.0.2）
  final int port; // Strata 默认 8080
  final String? apiKey;
  final bool useWireGuardOnly;
  final DateTime createdAt;

  String get baseUrl => 'http://$host:$port';

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'host': host,
        'port': port,
        'apiKey': apiKey,
        'useWireGuardOnly': useWireGuardOnly,
        'createdAt': createdAt.toIso8601String(),
      };

  factory ConnectionProfile.fromJson(Map<String, dynamic> json) => ConnectionProfile(
        id: json['id'] as String,
        name: json['name'] as String,
        host: json['host'] as String,
        port: (json['port'] as num).toInt(),
        apiKey: json['apiKey'] as String?,
        useWireGuardOnly: (json['useWireGuardOnly'] as bool?) ?? true,
        createdAt: DateTime.parse(json['createdAt'] as String),
      );
}
