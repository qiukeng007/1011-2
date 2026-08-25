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
/// 供货商抓取结果：成功时 suppliers 非空；失败时 suppliers 为空并携带原因
class SupplierFetchResult {
  final List<String> suppliers;
  final int? statusCode;
  final String? error;

  const SupplierFetchResult({
    this.suppliers = const [],
    this.statusCode,
    this.error,
  });
}

class LoginService {
  final SessionManager _sessionManager;

  /// 桌面端 User-Agent
  static const String _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  LoginService(this._sessionManager);

  /// 登录成功后从银豹获取供货商名称列表
  /// 优先调用 LoadSuppliers 接口（用门店 ID），失败回退页面 HTML 解析
  Future<SupplierFetchResult> fetchSuppliers(StoreConfig config) async {
    try {
      final baseUrl = config.baseUrl.replaceAll(RegExp(r'/$'), '');
      final cookie = await _sessionManager.getCookie(config.storeKey);
      if (cookie == null || cookie.isEmpty) {
        return const SupplierFetchResult(error: '本机无登录会话（请先在 APP 内登录）');
      }

      final client = HttpClient();
      client.autoUncompress = true;
      client.connectionTimeout = const Duration(seconds: 10);
      try {
        // ---- 0. 总账号模式：先切到目标门店会话（避免停在总店拿错门店供货商）----
        if (config.storeId.isNotEmpty) {
          try {
            final warmReq = await client
                .getUrl(Uri.parse('$baseUrl/Product/Manage?userId=${config.storeId}'));
            warmReq.headers.set('User-Agent', _ua);
            warmReq.headers.set('Accept', 'text/html,application/xhtml+xml');
            warmReq.headers.set('Referer', '$baseUrl/Product/Manage');
            warmReq.headers.set('Cookie', cookie);
            warmReq.followRedirects = false;
            final warmResp =
                await warmReq.close().timeout(const Duration(seconds: 8));
            await warmResp.drain<void>();
          } catch (_) {}
        }

        // ---- 1. 抓取 Supplier/Manage 原始 HTML（提取门店 ID 与诊断）----
        String pageBody = '';
        final pageReq = await client.getUrl(Uri.parse('$baseUrl/Supplier/Manage'));
        pageReq.headers.set('User-Agent', _ua);
        pageReq.headers.set('Accept', 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8');
        pageReq.headers.set('Referer', '$baseUrl/Product/Manage');
        pageReq.headers.set('Cookie', cookie);
        final pageResp = await pageReq.close().timeout(const Duration(seconds: 15));
        if (pageResp.statusCode == 200) {
          pageBody = await pageResp.transform(utf8.decoder).join();
        }

        // ---- 2. 用候选 ID 调用 LoadSuppliers 接口 ----
        final cachedUserId = await _sessionManager.getUserId(config.storeKey);
        final candidateIds = <String>{};
        if (config.storeId.isNotEmpty) {
          candidateIds.add(config.storeId);
        }
        if (cachedUserId != null && cachedUserId.isNotEmpty) {
          candidateIds.add(cachedUserId);
        }
        final storeId = _extractStoreIdFromHtml(pageBody);
        if (storeId != null && storeId.isNotEmpty) {
          candidateIds.add(storeId);
        }
        final pageUserId = _extractCurrentUserId(pageBody);
        if (pageUserId != null && pageUserId.isNotEmpty) {
          candidateIds.add(pageUserId);
        }
        // 合并页面响应中的 Set-Cookie，保持会话最新（银豹会在响应中刷新会话）
        var postCookie = cookie;
        final setCookies = pageResp.headers['set-cookie'];
        if (setCookies != null && setCookies.isNotEmpty) {
          postCookie = _mergeSetCookie(cookie, pageResp.headers);
        }
        final apiErrors = <String>[];
        // 依次用候选门店 ID 调用（LoadSuppliers 需要 userId + supplierEnable=1）
        for (final id in candidateIds) {
          final api = await _loadSuppliersViaApi(client, baseUrl, postCookie, id);
          if (api.suppliers.isNotEmpty) {
            final apiList = api.suppliers.toList()..sort();
            return SupplierFetchResult(suppliers: apiList);
          }
          if (api.error != null && api.error!.isNotEmpty) {
            apiErrors.add('id=$id：${api.error}');
          }
        }

        // ---- 2.5 若接口 500（会话 Token 可能过期），重新登录刷新会话后重试一次 ----
        if (apiErrors.any((e) => e.contains('HTTP 500'))) {
          try {
            await login(config);
          } catch (_) {}
          final newCookie = await _sessionManager.getCookie(config.storeKey);
          if (newCookie != null && newCookie.isNotEmpty && newCookie != cookie) {
            final retry = await _loadSuppliersViaApi(client, baseUrl, newCookie, null);
            if (retry.suppliers.isNotEmpty) {
              final retryList = retry.suppliers.toList()..sort();
              return SupplierFetchResult(suppliers: retryList);
            }
            if (retry.error != null && retry.error!.isNotEmpty) {
              apiErrors.add('重登后重试：${retry.error}');
            }
          } else {
            apiErrors.add('重登后 Cookie 未变化，跳过重试');
          }
        }

        // ---- 3. 页面 HTML 直接解析（服务端渲染时可用）----
        final suppliers = <String>{};
        final nameAttrRegex = RegExp(
          r'<tr[^>]*data-name="([^"]+)"',
          caseSensitive: false,
        );
        for (final m in nameAttrRegex.allMatches(pageBody)) {
          final name = m.group(1)!.trim();
          if (name.isNotEmpty && name.length < 50) suppliers.add(name);
        }
        if (suppliers.isEmpty) {
          final rowRegex = RegExp(
            r'<tr[^>]*data="(\d+)"[^>]*data-uid="(\d+)"[^>]*>([\s\S]*?)</tr>',
            caseSensitive: false,
          );
          for (final m in rowRegex.allMatches(pageBody)) {
            final rowHtml = m.group(3)!;
            final tds = RegExp(r'<td[^>]*>([^<]*)</td>').allMatches(rowHtml).toList();
            if (tds.length >= 4) {
              final name = tds[3].group(1)!.trim();
              if (name.isNotEmpty && name.length < 50) suppliers.add(name);
            }
          }
        }
        if (suppliers.isNotEmpty) {
          final list = suppliers.toList()..sort();
          return SupplierFetchResult(suppliers: list);
        }

        // ---- 4. 全部失败：输出详细诊断 ----
        // 提取页面关键片段用于诊断
        String storeOptionsSnippet = '无';
        final soIdx = pageBody.indexOf('storeOptions');
        if (soIdx >= 0) {
          storeOptionsSnippet = pageBody.substring(
            soIdx > 120 ? soIdx - 120 : 0,
            (soIdx + 300) < pageBody.length ? soIdx + 300 : pageBody.length,
          ).replaceAll('\r', '').replaceAll('\n', ' ');
        }
        String currentUserIdSnippet = '无';
        final cuIdx = pageBody.indexOf('currentUserId');
        if (cuIdx >= 0) {
          currentUserIdSnippet = pageBody.substring(
            cuIdx > 60 ? cuIdx - 60 : 0,
            (cuIdx + 200) < pageBody.length ? cuIdx + 200 : pageBody.length,
          ).replaceAll('\r', '').replaceAll('\n', ' ');
        }
        final diag = <String>[
          '页面长度 ${pageBody.length}',
          '含 data-name ${pageBody.contains('data-name')}',
          'currentUserId $pageUserId',
          'storeId $storeId',
          '缓存 userId $cachedUserId',
          'storeOptions 片段：$storeOptionsSnippet',
          'currentUserId 片段：$currentUserIdSnippet',
        ];
        if (apiErrors.isNotEmpty) {
          diag.add('接口结果：${apiErrors.join(' | ')}');
        }
        return SupplierFetchResult(
          error: '获取供货商失败（${diag.join('；')}）',
        );
      } finally {
        client.close();
      }
    } catch (e) {
      return SupplierFetchResult(error: '$e');
    }
  }

  /// 从 Supplier/Manage 页面 HTML 提取门店 ID（hf_storeId / data-storeid / storeId）
  String? _extractStoreIdFromHtml(String body) {
    final m1 = RegExp(r'id="hf_storeId"\s+value="(\d+)"', caseSensitive: false).firstMatch(body);
    if (m1 != null) return m1.group(1);
    final m2 = RegExp(r'''data-storeid\s*=\s*['"](\d+)['"]''', caseSensitive: false).firstMatch(body);
    if (m2 != null) return m2.group(1);
    final m3 = RegExp(r'var\s+storeId\s*=\s*(\d+)\s*;', caseSensitive: false).firstMatch(body);
    if (m3 != null) return m3.group(1);
    final m4 = RegExp(r'''storeId['"]?\s*[:=]\s*['"]?(\d+)''', caseSensitive: false).firstMatch(body);
    if (m4 != null) return m4.group(1);
    return null;
  }

  /// 从页面 HTML 提取 currentUserId
  String? _extractCurrentUserId(String body) {
    final m1 = RegExp(r'var\s+currentUserId\s*=\s*(\d+)\s*;', caseSensitive: false).firstMatch(body);
    if (m1 != null) return m1.group(1);
    final m2 = RegExp(r'''currentUserId['"]?\s*[:=]\s*['"]?(\d+)''', caseSensitive: false).firstMatch(body);
    if (m2 != null) return m2.group(1);
    return null;
  }

  /// 调用银豹 LoadSuppliers 接口获取供货商表格 HTML（优先于页面解析）
  /// 返回 suppliers（非空即成功）与 error（失败原因）
  Future<({Set<String> suppliers, String? error})> _loadSuppliersViaApi(
    HttpClient client,
    String baseUrl,
    String cookie,
    String? userId,
  ) async {
    try {
      final req = await client.postUrl(Uri.parse('$baseUrl/Supplier/LoadSuppliers'));
      req.headers.set('User-Agent', _ua);
      req.headers.set('Accept', 'application/json, text/javascript, */*; q=0.01');
      req.headers.set('Referer', '$baseUrl/Supplier/Manage');
      req.headers.set('Cookie', cookie);
      req.headers.set('Content-Type', 'application/x-www-form-urlencoded; charset=UTF-8');
      req.headers.set('X-Requested-With', 'XMLHttpRequest');
      // 参数：userId（门店 ID）与 supplierEnable=1（启用筛选）必传，否则接口 500
      final fields = <String, String>{
        'supplierEnable': '1',
        'keyword': '',
      };
      if (userId == null || userId.isEmpty) {
        return (suppliers: <String>{}, error: '缺少门店 ID（userId）');
      }
      fields['userId'] = userId;
      final formBody = fields.entries
          .map((e) => '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}')
          .join('&');
      req.write(formBody);
      final resp = await req.close().timeout(const Duration(seconds: 15));
      if (resp.statusCode != 200) {
        String errBody = '';
        try {
          errBody = await resp.transform(utf8.decoder).join();
        } catch (_) {}
        if (errBody.length > 300) errBody = errBody.substring(0, 300);
        return (
          suppliers: <String>{},
          error: 'LoadSuppliers 接口 HTTP ${resp.statusCode}，请求体：$formBody，Cookie（前 600 字符）：${cookie.length > 600 ? cookie.substring(0, 600) : cookie}，响应：$errBody',
        );
      }
      final jsonText = await resp.transform(utf8.decoder).join();
      final Object? decoded;
      try {
        decoded = jsonDecode(jsonText);
      } catch (_) {
        return (
          suppliers: <String>{},
          error: 'LoadSuppliers 返回非 JSON（前 200 字符：${jsonText.length > 200 ? jsonText.substring(0, 200) : jsonText}）',
        );
      }
      if (decoded is! Map) {
        return (suppliers: <String>{}, error: 'LoadSuppliers 返回格式异常（${decoded.runtimeType}）');
      }
      final successed = decoded['successed'];
      final msg = decoded['msg'];
      final view = decoded['view'];
      if (view is! String || view.isEmpty) {
        return (
          suppliers: <String>{},
          error: 'LoadSuppliers 返回 view 为空（successed=$successed，msg=$msg）',
        );
      }
      final suppliers = <String>{};
      final nameRegex = RegExp(r'<tr[^>]*data-name="([^"]+)"', caseSensitive: false);
      for (final m in nameRegex.allMatches(view)) {
        final name = m.group(1)!.trim();
        if (name.isNotEmpty && name.length < 50) suppliers.add(name);
      }
      if (suppliers.isEmpty) {
        return (
          suppliers: <String>{},
          error: 'LoadSuppliers 表格中未找到 data-name（view 长度 ${view.length}）',
        );
      }
      return (suppliers: suppliers, error: null);
    } catch (e) {
      return (suppliers: <String>{}, error: 'LoadSuppliers 异常：$e');
    }
  }

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
