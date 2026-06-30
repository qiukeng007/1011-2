import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/login_session.dart';

/// Cookie 会话管理
/// - Cookie 持久化到 SharedPreferences
/// - 提供有效性验证
class SessionManager {
  static const _cookiePrefix = 'cookie_';
  static const _userIdPrefix = 'uid_';

  /// 桌面端 User-Agent（与 LoginService 一致）
  static const String _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  /// 保存 Cookie
  Future<void> saveCookie(String storeKey, String cookie) async {
    final prefs = await SharedPreferences.getInstance();
    final session = LoginSession(cookie: cookie);
    await prefs.setString(
      '$_cookiePrefix$storeKey',
      jsonEncode({
        'cookie': session.cookie,
        'via': session.via,
        'createdAt': session.createdAt.toIso8601String(),
      }),
    );
  }

  /// 获取 Cookie
  Future<String?> getCookie(String storeKey) async {
    final prefs = await SharedPreferences.getInstance();
    final jsonStr = prefs.getString('$_cookiePrefix$storeKey');
    if (jsonStr == null) return null;

    try {
      final data = jsonDecode(jsonStr) as Map<String, dynamic>;
      final createdAt = DateTime.parse(data['createdAt'] as String);
      final session = LoginSession(
        cookie: data['cookie'] as String? ?? '',
        via: data['via'] as String? ?? '',
        createdAt: createdAt,
      );
      if (session.isExpired) {
        await deleteCookie(storeKey);
        return null;
      }
      return session.cookie;
    } catch (_) {
      await deleteCookie(storeKey);
      return null;
    }
  }

  /// 删除 Cookie
  Future<void> deleteCookie(String storeKey) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('$_cookiePrefix$storeKey');
    await prefs.remove('$_userIdPrefix$storeKey');
  }

  /// 缓存 userId（从 Product/Manage 页面提取，避免每次查询重复请求）
  Future<void> saveUserId(String storeKey, String userId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('$_userIdPrefix$storeKey', userId);
  }

  /// 获取缓存的 userId
  Future<String?> getUserId(String storeKey) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('$_userIdPrefix$storeKey');
  }

  /// 验证 Cookie 是否有效
  ///
  /// 先检查商品管理页特征（Product/商品/库存），再检查登录页特征。
  /// 商品管理页的导航栏可能包含"退出登录""修改员工密码"等文字，
  /// 所以不能简单地用"登录+密码"来判断是登录页。
  /// 与 LoginService._verifyLoggedIn 逻辑一致。
  Future<bool> isCookieValid(String storeKey, String baseUrl) async {
    final cookie = await getCookie(storeKey);
    if (cookie == null) return false;

    final httpClient = HttpClient();
    httpClient.autoUncompress = true;
    try {
      final uri = Uri.parse('$baseUrl/Product/Manage');
      final request = await httpClient.getUrl(uri);
      request.headers.set('User-Agent', _ua);
      request.headers.set('Accept', 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8');
      request.headers.set('Accept-Language', 'zh-CN,zh;q=0.9');
      request.headers.set('Cookie', cookie);
      request.followRedirects = false;

      final response = await request.close().timeout(const Duration(seconds: 8));
      final body = await _readResponseBody(response);

      // 检查是否被重定向到登录页
      if (response.statusCode == 302 || response.statusCode == 301) {
        final loc = response.headers.value('location') ?? '';
        if (RegExp(r'signin|login', caseSensitive: false).hasMatch(loc)) {
          return false;
        }
      }

      if (response.statusCode != 200) return false;

      // 检查页面是否包含 currentUserId（商品管理页特有）
      if (RegExp(r'currentUserId\s*[=:]', caseSensitive: false).hasMatch(body)) {
        return true;
      }

      // 检查是否包含商品管理页特征
      if (body.contains('Product') ||
          body.contains('product') ||
          body.contains('商品') ||
          body.contains('库存') ||
          body.contains('条码') ||
          body.contains('LoadProductsByPage')) {
        return true;
      }

      // 检查是否包含登录页特征
      if (body.contains('signin') &&
          (body.contains('form') || body.contains('input'))) {
        return false;
      }

      // 检查登录表单特征（登录页特有的结构）
      if (body.contains('regularSignIn_box') ||
          body.contains('loginBox') ||
          body.contains('submitLoginBtn') ||
          body.contains('__RequestVerificationToken')) {
        return false;
      }

      return true;
    } catch (_) {
      // 网络异常不判定失效，保留现有 Cookie
      return true;
    } finally {
      httpClient.close();
    }
  }

  /// 读取响应体
  Future<String> _readResponseBody(HttpClientResponse response) async {
    final completer = Completer<String>();
    final bytes = <int>[];
    response.listen(
      (data) => bytes.addAll(data),
      onDone: () => completer.complete(utf8.decode(bytes)),
      onError: (e) => completer.completeError(e),
    );
    return completer.future;
  }

  /// 获取所有已保存 Cookie 的门店 key
  Future<List<String>> getSavedStoreKeys() async {
    final prefs = await SharedPreferences.getInstance();
    final keys = prefs.getKeys();
    return keys
        .where((k) => k.startsWith(_cookiePrefix))
        .map((k) => k.substring(_cookiePrefix.length))
        .toList();
  }

  /// 清除所有 Cookie
  Future<void> clearAll() async {
    final prefs = await SharedPreferences.getInstance();
    final keys = prefs.getKeys();
    for (final k in keys) {
      if (k.startsWith(_cookiePrefix)) {
        await prefs.remove(k);
      }
    }
  }
}
