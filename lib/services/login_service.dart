import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../models/store_config.dart';
import '../models/login_session.dart';
import 'session_manager.dart';

/// 工号登录服务
///
/// 银豹登录流程（2025年新版 AJAX API）：
/// 1. GET /account/signin?ReturnUrl=... 获取登录页（获取初始 Cookie）
/// 2. POST /account/SignIn 提交登录凭据（form-encoded）
///    参数：userName=账号:工号, password=密码, returnUrl, screenSize, employeeSignin=true
/// 3. 解析返回 JSON：{ successed: true, msg: "重定向URL" }
/// 4. 跟随重定向到商品管理页
class LoginService {
  final SessionManager _sessionManager;

  /// 桌面端 User-Agent
  static const String _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  LoginService(this._sessionManager);

  /// 登录门店
  /// 返回 LoginSession（含 Cookie）
  /// 抛出 LoginException 时携带错误信息
  Future<LoginSession> login(
    StoreConfig store, {
    void Function(LoginProgress)? onProgress,
  }) async {
    final baseUrl = store.baseUrl.replaceAll(RegExp(r'/$'), '');
    final account = store.account.trim();
    final cashierJobNumber = store.cashierJobNumber.trim();
    final password = store.password.trim();

    if (account.isEmpty || cashierJobNumber.isEmpty || password.isEmpty) {
      throw LoginException('请填写门店账号、员工工号和工号密码');
    }

    _report(onProgress, '正在打开登录页…', 10);

    // 使用底层 HttpClient 以禁用自动重定向
    final httpClient = HttpClient();
    httpClient.autoUncompress = true;
    try {
      final signinUrl = Uri.parse('$baseUrl/account/signin?ReturnUrl=%2fProduct%2fManage');

      // ---- Step 1: GET 登录页（获取初始 Cookie）----
      final signinRequest = await httpClient.getUrl(signinUrl);
      signinRequest.headers.set('User-Agent', _ua);
      signinRequest.headers.set('Accept', 'text/html,application/xhtml+xml');
      signinRequest.headers.set('Accept-Language', 'zh-CN,zh;q=0.9');
      signinRequest.followRedirects = false;

      final signinResponse = await signinRequest.close().timeout(const Duration(seconds: 15));
      await _readBody(signinResponse);

      if (signinResponse.statusCode >= 400) {
        throw LoginException('无法打开登录页 (HTTP ${signinResponse.statusCode})，请检查后台地址');
      }

      // 提取初始 Cookie
      String cookie = _mergeSetCookie('', signinResponse.headers);

      // 检查是否已有有效会话
      if (RegExp(r'\.POSPALAUTH|\.ASPXAUTH', caseSensitive: false).hasMatch(cookie)) {
        _report(onProgress, '检测到已登录状态，正在验证…', 50);
        final userId = await _verifyAndCacheUserId(baseUrl, cookie, store.storeKey, httpClient);
        if (userId != null) {
          _report(onProgress, '登录状态有效！', 100);
          await _sessionManager.saveCookie(store.storeKey, cookie);
          return LoginSession(cookie: cookie, via: '已有会话');
        }
      }

      _report(onProgress, '正在登录…', 30);

      // ---- Step 2: POST 登录（使用新版 AJAX API）----
      // 银豹新版登录 API：
      // - URL: /account/SignIn
      // - 参数：userName=账号:工号, password=密码, returnUrl, screenSize, employeeSignin=true
      // - Content-Type: application/x-www-form-urlencoded
      // - 需要 X-Requested-With: XMLHttpRequest
      final loginUri = Uri.parse('$baseUrl/account/SignIn');
      final loginRequest = await httpClient.postUrl(loginUri);

      // 构建登录参数
      final loginData = <String, String>{
        'userName': '$account:$cashierJobNumber',
        'password': password,
        'returnUrl': '/Product/Manage',
        'screenSize': '1080*1920',
        'employeeSignin': 'true',
      };

      // 设置请求头
      loginRequest.headers.set('User-Agent', _ua);
      loginRequest.headers.set('Accept', 'application/json, text/javascript, */*');
      loginRequest.headers.set('Referer', signinUrl.toString());
      loginRequest.headers.set('Origin', baseUrl);
      loginRequest.headers.set('Accept-Language', 'zh-CN,zh;q=0.9');
      loginRequest.headers.set('Content-Type',
          'application/x-www-form-urlencoded; charset=UTF-8');
      loginRequest.headers.set('X-Requested-With', 'XMLHttpRequest');
      if (cookie.isNotEmpty) {
        loginRequest.headers.set('Cookie', cookie);
      }
      loginRequest.followRedirects = false;

      // 写入 form-encoded body
      loginRequest.write(_encodeForm(loginData));

      final loginResponse = await loginRequest.close().timeout(const Duration(seconds: 15));
      final loginBody = await _readBody(loginResponse);

      // 合并 Cookie
      cookie = _mergeSetCookie(cookie, loginResponse.headers);

      // ---- Step 3: 解析登录结果 ----
      String? redirectUrl;
      try {
        final result = jsonDecode(loginBody) as Map<String, dynamic>;
        final successed = result['successed'] == true;
        final msg = result['msg'] as String? ?? '';

        if (successed && msg.isNotEmpty) {
          // 登录成功，msg 包含重定向 URL
          redirectUrl = msg;
        } else {
          // 登录失败，msg 包含错误信息
          throw LoginException(
            '工号登录失败：${msg.isNotEmpty ? msg : '未知错误，请确认账号/工号/密码与网页一致'}',
          );
        }
      } on LoginException {
        rethrow;
      } catch (e) {
        // JSON 解析失败，检查是否是 HTML 错误页
        final plain = loginBody
            .replaceAll(RegExp(r'<[^>]+>'), ' ')
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim();
        if (plain.length > 10) {
          throw LoginException('登录失败：${_safeSubstring(plain, 300)}');
        }
        throw LoginException('登录失败：无法解析服务器响应');
      }

      // ---- Step 4: 跟随重定向到商品管理页 ----
      _report(onProgress, '登录成功，正在进入…', 70);

      final redirectUri = Uri.parse(redirectUrl.startsWith('http')
          ? redirectUrl
          : '$baseUrl${redirectUrl.startsWith('/') ? '' : '/'}$redirectUrl');

      final followRequest = await httpClient.getUrl(redirectUri);
      followRequest.headers.set('User-Agent', _ua);
      followRequest.headers.set('Cookie', cookie);
      followRequest.headers.set('Referer', signinUrl.toString());
      followRequest.followRedirects = false;

      final followResponse = await followRequest.close().timeout(const Duration(seconds: 10));
      await _readBody(followResponse);
      cookie = _mergeSetCookie(cookie, followResponse.headers);

      // ---- Step 5: 验证登录状态 ----
      _report(onProgress, '验证登录状态…', 85);

      final userId = await _verifyAndCacheUserId(baseUrl, cookie, store.storeKey, httpClient);
      if (userId == null) {
        throw LoginException('登录验证失败，请重试');
      }

      _report(onProgress, '登录成功！', 100);
      await _sessionManager.saveCookie(store.storeKey, cookie);
      return LoginSession(cookie: cookie, via: '工号登录');
    } finally {
      httpClient.close();
    }
  }

  /// 读取响应体
  Future<String> _readBody(HttpClientResponse response) async {
    final bytes = <int>[];
    await for (final chunk in response) {
      bytes.addAll(chunk);
    }
    return utf8.decode(bytes);
  }

  /// 验证登录状态并缓存 userId
  ///
  /// 先检查商品管理页特征（Product/商品/库存），再检查登录页特征。
  /// 验证通过后提取 currentUserId 并缓存到 SessionManager，
  /// 避免后续查询时重复 GET /Product/Manage。
  /// 返回 userId 表示验证通过，null 表示未登录。
  Future<String?> _verifyAndCacheUserId(String baseUrl, String cookie, String storeKey, HttpClient httpClient) async {
    try {
      final uri = Uri.parse('$baseUrl/Product/Manage');
      final request = await httpClient.getUrl(uri);
      request.headers.set('User-Agent', _ua);
      request.headers.set('Accept', 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8');
      request.headers.set('Accept-Language', 'zh-CN,zh;q=0.9');
      request.headers.set('Cookie', cookie);
      request.followRedirects = false;

      final response = await request.close().timeout(const Duration(seconds: 10));
      final body = await _readBody(response);

      if (response.statusCode != 200) return null;

      // 检查是否被重定向到登录页（通过 location header 或 URL）
      if (response.headers.value('location') != null &&
          RegExp(r'signin|login', caseSensitive: false)
              .hasMatch(response.headers.value('location')!)) {
        return null;
      }

      // 提取 userId 并缓存
      final userId = _extractUserIdFromHtml(body);
      if (userId != null) {
        await _sessionManager.saveUserId(storeKey, userId);
        return userId;
      }

      // 优先检查商品管理页特征（商品管理页也可能包含"登录""密码"等导航文字）
      if (body.contains('Product') ||
          body.contains('product') ||
          body.contains('商品') ||
          body.contains('库存') ||
          body.contains('条码') ||
          body.contains('LoadProductsByPage')) {
        return ''; // 已验证但无法提取 userId，返回空串标记已验证
      }

      // 检查是否包含登录页特征（仅在无商品特征时判断）
      if (body.contains('signin') &&
          (body.contains('form') || body.contains('input'))) {
        return null;
      }

      // 检查登录表单特征（登录页特有的结构）
      if (body.contains('regularSignIn_box') ||
          body.contains('loginBox') ||
          body.contains('submitLoginBtn') ||
          body.contains('__RequestVerificationToken')) {
        return null;
      }

      return ''; // 默认识别为已登录
    } catch (_) {
      return null;
    }
  }

  /// 从 Product/Manage 页面 HTML 提取 currentUserId
  String? _extractUserIdFromHtml(String body) {
    // 格式1: var currentUserId = 12345;
    final m1 = RegExp(r'var\s+currentUserId\s*=\s*(\d+)\s*;', caseSensitive: false).firstMatch(body);
    if (m1 != null) return m1.group(1);

    // 格式2: currentUserId: 12345 或 "currentUserId": 12345
    final m2 = RegExp(r'''currentUserId['"]?\s*[:=]\s*['"]?(\d+)['"]?''', caseSensitive: false).firstMatch(body);
    if (m2 != null) return m2.group(1);

    // 备选: id="hf_storeId" value="12345"
    final m3 = RegExp(r'id="hf_storeId"\s+value="(\d+)"', caseSensitive: false).firstMatch(body);
    if (m3 != null) return m3.group(1);

    // 备选: data-storeid="12345"
    final m4 = RegExp(r'''data-storeid\s*=\s*['"](\d+)['"]''', caseSensitive: false).firstMatch(body);
    if (m4 != null) return m4.group(1);

    return null;
  }

  /// 从响应头提取并合并 Set-Cookie 到现有 Cookie
  String _mergeSetCookie(String existingCookie, HttpHeaders headers) {
    final allSetCookie = headers['set-cookie'];
    if (allSetCookie == null || allSetCookie.isEmpty) return existingCookie;

    final map = <String, String>{};

    // 先解析现有 Cookie
    if (existingCookie.isNotEmpty) {
      for (final part in existingCookie.split(';')) {
        final trimmed = part.trim();
        if (trimmed.isEmpty) continue;
        final eqIdx = trimmed.indexOf('=');
        if (eqIdx <= 0) continue;
        map[trimmed.substring(0, eqIdx).trim()] = trimmed.substring(eqIdx + 1).trim();
      }
    }

    // 解析每个 Set-Cookie 值
    for (final raw in allSetCookie) {
      if (raw.isEmpty) continue;

      // 取第一个分号前的部分作为 name=value
      final firstSemi = raw.indexOf(';');
      final nv = firstSemi > 0 ? raw.substring(0, firstSemi).trim() : raw.trim();
      final eqIdx = nv.indexOf('=');
      if (eqIdx <= 0) continue;

      final name = nv.substring(0, eqIdx).trim();
      final value = nv.substring(eqIdx + 1).trim();

      // 跳过属性字段
      if (RegExp(r'^(path|domain|expires|max-age|secure|httponly|samesite)',
              caseSensitive: false)
          .hasMatch(name)) {
        continue;
      }

      map[name] = value;
    }

    return map.entries.map((e) => '${e.key}=${e.value}').join('; ');
  }

  /// URL 编码表单数据
  String _encodeForm(Map<String, String> data) {
    return data.entries
        .map((e) =>
            '${Uri.encodeComponent(e.key)}=${Uri.encodeComponent(e.value)}')
        .join('&');
  }

  /// 安全截取字符串前 n 个字符
  String _safeSubstring(String s, int maxLen) {
    if (s.length <= maxLen) return s;
    return s.substring(0, maxLen);
  }

  void _report(
    void Function(LoginProgress)? onProgress,
    String message,
    double percent,
  ) {
    onProgress?.call(LoginProgress(message: message, percent: percent));
  }
}

/// 登录异常
class LoginException implements Exception {
  final String message;
  const LoginException(this.message);

  @override
  String toString() => message;
}
