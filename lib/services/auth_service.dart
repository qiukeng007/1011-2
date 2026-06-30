import 'dart:convert';
import 'dart:io';
import 'package:shared_preferences/shared_preferences.dart';

/// 系统授权服务
/// - 远程 password.txt 变更后强制重新验证
/// - 验证失败可切换到配置页修改服务器地址
class AuthService {
  static const _authKey = 'sys_auth_v2';
  static const _localPwdKey = 'sys_local_pwd';
  static const _operatorKey = 'operator_name_v5';
  static const _cachedJsonKey = 'sys_config_json';

  final SharedPreferences _prefs;

  AuthService(this._prefs);

  /// 是否已授权
  bool get isAuthorized => _prefs.getBool(_authKey) ?? false;

  /// 操作员姓名
  String get operatorName => _prefs.getString(_operatorKey) ?? '';

  /// 规范化 URL
  static String normalizeUrl(String serverUrl) {
    var url = serverUrl.trim();
    if (url.isEmpty) return url;
    if (url.startsWith('https://')) {
      url = 'http://${url.substring(8)}';
    }
    if (!url.startsWith('http://')) {
      url = 'http://$url';
    }
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    return url;
  }

  /// 从远程获取密码（明文）
  Future<String> _fetchRemotePassword(String serverUrl) async {
    try {
      final url = normalizeUrl(serverUrl);
      if (url.isEmpty) return '';
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 5);
      final uri = Uri.parse('$url/PIC/password.txt');
      final request = await client.getUrl(uri);
      final response = await request.close().timeout(const Duration(seconds: 4));
      if (response.statusCode == 200) {
        final body = await response.transform(utf8.decoder).join();
        client.close();
        return body.trim();
      }
      client.close();
    } catch (_) {}
    return '';
  }

  /// 检查是否需要重新授权（仅检查远程密码是否变更）
  Future<bool> needReAuth(String currentJson, String serverUrl) async {
    // 从未授权过 → 需要授权
    if (!_prefs.containsKey(_authKey)) return true;

    // 远程密码变更
    final remotePwd = await _fetchRemotePassword(serverUrl);
    if (remotePwd.isEmpty) return false; // 连不上服务器，跳过

    final localPwd = _prefs.getString(_localPwdKey) ?? '';
    if (localPwd.isEmpty) return true; // 首次验证
    return remotePwd != localPwd;
  }

  /// 获取远程密码（用于验证用户输入）
  Future<String> fetchRemotePassword(String serverUrl) async {
    return _fetchRemotePassword(serverUrl);
  }

  /// 验证密码（与远程密码对比）
  bool verifyPassword(String input, String remotePwd) {
    return input.trim() == remotePwd;
  }

  /// 标记已授权并保存快照
  Future<void> authorize(String currentJson, String serverUrl,
      {String? operator}) async {
    await _prefs.setBool(_authKey, true);
    await _prefs.setString(_cachedJsonKey, currentJson);

    // 保存当前远程密码
    final remotePwd = await _fetchRemotePassword(serverUrl);
    if (remotePwd.isNotEmpty) {
      await _prefs.setString(_localPwdKey, remotePwd);
    }

    if (operator != null && operator.isNotEmpty) {
      await _prefs.setString(_operatorKey, operator.trim());
    }
  }

  /// 保存操作员姓名
  Future<void> saveOperator(String name) async {
    await _prefs.setString(_operatorKey, name.trim());
  }

  /// 清除授权
  Future<void> clearAuth() async {
    await _prefs.remove(_authKey);
    await _prefs.remove(_cachedJsonKey);
    await _prefs.remove(_localPwdKey);
  }
}
