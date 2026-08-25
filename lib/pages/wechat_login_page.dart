import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import '../services/session_manager.dart';
import '../services/store_sync_service.dart';
import '../utils/constants.dart';

/// 微信扫码登录页（移植自 smart_eye_stock 的登录方式）
///
/// 原理：
/// 1. 用 WebView 打开银豹后台商品管理页；
/// 2. 打开前先把本地已保存的 Cookie 注入 WebView —— 如果会话仍有效，
///    会直接进入商品管理页，免扫码；
/// 3. 若会话失效，页面会跳到登录页，用户用另一台手机微信扫码完成 OAuth
///    授权，页面自动跳回 /Product/Manage；
/// 4. 检测到登录成功后，把 WebView 里的完整 Cookie 抓出来保存到本地，
///    之后查询直接带该 Cookie 请求银豹接口，长期有效、无需反复登录。
class WechatLoginPage extends StatefulWidget {
  final String baseUrl;
  final String storeKey;
  final SessionManager sessionManager;
  final ValueChanged<String> onLoggedIn;
  final void Function(List<PospalSubStore> stores)? onStoresLoaded;
  final String? account;
  final String? employee;
  final String? password;

  const WechatLoginPage({
    super.key,
    required this.baseUrl,
    required this.storeKey,
    required this.sessionManager,
    required this.onLoggedIn,
    this.onStoresLoaded,
    this.account,
    this.employee,
    this.password,
  });

  @override
  State<WechatLoginPage> createState() => _WechatLoginPageState();
}

class _WechatLoginPageState extends State<WechatLoginPage> {
  InAppWebViewController? _ctrl;
  bool _loading = true;
  bool _loggedIn = false;
  bool _loginAttempting = false;
  bool _prefillInjected = false;
  bool _storesLoaded = false;

  static const _oauthKeywords = [
    'oauth',
    'wechat',
    'authorize',
    'open.weixin',
    'mp.weixin',
    'wxopen',
    'user.pospal.cn',
  ];

  static const String _ua =
      'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';

  static String _norm(String url) =>
      url.trim().replaceAll(RegExp(r'/+$'), '');

  bool _isOAuthPage(String url) {
    final lower = url.toLowerCase();
    return _oauthKeywords.any((kw) => lower.contains(kw));
  }

  /// 把本地已保存的 Cookie 注入 WebView，再导航到商品管理页
  Future<void> _seedAndLoad(InAppWebViewController c) async {
    try {
      final saved = await widget.sessionManager.getCookie(widget.storeKey);
      if (saved != null && saved.isNotEmpty) {
        final base = WebUri(_norm(widget.baseUrl));
        final host = Uri.parse(_norm(widget.baseUrl)).host;
        for (final part in saved.split(';')) {
          final idx = part.indexOf('=');
          if (idx <= 0) continue;
          try {
            await CookieManager.instance().setCookie(
              url: base,
              name: part.substring(0, idx).trim(),
              value: part.substring(idx + 1).trim(),
              path: '/',
              domain: host,
            );
          } catch (_) {}
        }
      }
    } catch (_) {}
    c.loadUrl(
      urlRequest: URLRequest(
        url: WebUri('${_norm(widget.baseUrl)}/Product/Manage'),
      ),
    );
  }

  /// OAuth 中间页 http -> https（微信授权要求 https）
  Future<NavigationActionPolicy?> _onUrlOverride(
    InAppWebViewController c,
    NavigationAction action,
  ) async {
    final u = action.request.url.toString();
    if (u.startsWith('http://user.pospal.cn')) {
      final httpsUrl = u.replaceFirst('http://', 'https://');
      c.loadUrl(urlRequest: URLRequest(url: WebUri(httpsUrl)));
      return NavigationActionPolicy.CANCEL;
    }
    return NavigationActionPolicy.ALLOW;
  }

  void _onUpdateVisitedHistory(
    InAppWebViewController c,
    Uri? url,
    bool? reload,
  ) {
    if (_loggedIn || url == null) return;
    final u = url.toString();
    if (_isOAuthPage(u)) return;
    if (!_prefillInjected &&
        _isAuthPage(u) &&
        ((widget.employee ?? '').isNotEmpty ||
            (widget.password ?? '').isNotEmpty)) {
      _prefillInjected = true;
      _injectFill();
    }
    if (u.contains('/Product/Manage') || u.contains('/product/manage')) {
      _tryLogin(currentUrl: u);
    }
  }

  void _onLoadStop(InAppWebViewController c, Uri? url) {
    if (url == null) return;
    final u = url.toString();
    setState(() => _loading = false);
    if (_isOAuthPage(u)) return;
    if (!_prefillInjected &&
        _isAuthPage(u) &&
        ((widget.employee ?? '').isNotEmpty ||
            (widget.password ?? '').isNotEmpty)) {
      _prefillInjected = true;
      _injectFill();
    }
    if (u.contains('/Product/Manage') || u.contains('/product/manage')) {
      _tryLogin(currentUrl: u);
    }
  }

  void _onJsDetect(List<dynamic> args) {
    if (_loggedIn) return;
    try {
      final data = args.isNotEmpty ? args[0] as String : '';
      if (_isOAuthPage(data)) return;
      _tryLogin(currentUrl: data);
    } catch (_) {}
  }

  /// 手动验证（扫码完成后用户点击按钮）
  /// 判断是否银豹登录页（用于自动填充工号密码）
  bool _isAuthPage(String url) {
    final lower = url.toLowerCase();
    return lower.contains('signin') ||
        lower.contains('/login') ||
        lower.contains('/account');
  }

  /// 自动填充账号/工号/密码并提交（模仿 smart_eye_stock 的自动登录）
  Future<void> _injectFill() async {
    if (_ctrl == null) return;
    final accountJs = jsonEncode(widget.account ?? '');
    final employeeJs = jsonEncode(widget.employee ?? '');
    final passwordJs = jsonEncode(widget.password ?? '');
    await _ctrl!.evaluateJavascript(source: '''
      (function(){
        var emp=document.querySelector('span[data-type="2"]');if(emp)emp.click();
        setTimeout(function(){
          var a=document.getElementById('txt_userName')||document.querySelector('input[placeholder*="账号"]');
          if(a && $accountJs !== ''){a.value=$accountJs;a.dispatchEvent(new Event('input',{bubbles:true}));a.dispatchEvent(new Event('change',{bubbles:true}));}
          var j=document.getElementById('txt_cashierJobName');
          if(j && $employeeJs !== ''){j.value=$employeeJs;j.dispatchEvent(new Event('input',{bubbles:true}));j.dispatchEvent(new Event('change',{bubbles:true}));}
          var pw=document.querySelectorAll('input[type="password"]');
          if($passwordJs !== ''){for(var i=0;i<pw.length;i++){pw[i].value=$passwordJs;pw[i].dispatchEvent(new Event('input',{bubbles:true}));pw[i].dispatchEvent(new Event('change',{bubbles:true}));}}
          setTimeout(function(){
            var btn=document.querySelector('button[type="submit"]')||document.querySelector('input[type="submit"]')||document.querySelector('button.btn-primary')||document.querySelector('a.btn-primary')||document.querySelector('button[class*="login"]')||document.querySelector('button[class*="submit"]')||document.querySelector('a[class*="login"]');
            if(btn)btn.click();else{var fs=document.querySelectorAll('form');for(var f=0;f<fs.length;f++)try{fs[f].submit()}catch(e){}}
          },400);
        },500);
      })();
    ''');
  }

  /// 从当前页面 DOM 提取门店列表（优先 JS，失败时 HTTP 兜底）
  Future<List<PospalSubStore>> _extractStores(String cookie) async {
    try {
      if (_ctrl != null) {
        final result = await _ctrl!.evaluateJavascript(
          source: StoreSyncService.jsExtractStores,
        );
        final stores = StoreSyncService.parseStoresJson(result?.toString());
        if (stores.isNotEmpty) return stores;
      }
    } catch (_) {}
    try {
      final stores = await StoreSyncService.fetchStores(
        baseUrl: _norm(widget.baseUrl),
        cookie: cookie,
      );
      if (stores.isNotEmpty) return stores;
    } catch (_) {}
    return const [];
  }
  Future<void> _manualCheck() async {
    if (_loggedIn) return;
    String currentUrl = '';
    if (_ctrl != null) {
      try {
        final u = await _ctrl!.getUrl();
        currentUrl = u?.toString() ?? '';
      } catch (_) {}
    }
    await _tryLogin(currentUrl: currentUrl, manual: true);
  }

  Future<void> _tryLogin({String currentUrl = '', bool manual = false}) async {
    if (_loggedIn || _loginAttempting) return;
    _loginAttempting = true;
    try {
      final ck = await _extractCookies();
      if (ck == null || ck.isEmpty) {
        if (manual) _showError('未检测到登录信息，请确认已在微信中完成扫码验证');
        return;
      }
      // 关键：验证会话真实有效，防止二维码登录页的残留 Cookie 被误判为登录成功
      final valid = await StoreSyncService.validateCookie(
        baseUrl: _norm(widget.baseUrl),
        cookie: ck,
      );
      if (!valid) {
        debugPrint('[WechatLogin] 会话验证未通过，等待扫码…');
        if (manual) _showError('未检测到有效登录，请用微信完成扫码后重试');
        return;
      }
      await widget.sessionManager.saveCookie(widget.storeKey, ck, via: 'wechat');
      widget.onLoggedIn(ck);
      _loggedIn = true;
      // 登录后立即从页面 DOM 提取门店列表（比 HTTP 正则更可靠）
      if (!_storesLoaded) {
        _storesLoaded = true;
        final stores = await _extractStores(ck);
        widget.onStoresLoaded?.call(stores);
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('微信登录成功，会话已保存（长期有效）'),
          backgroundColor: AppConstants.successColor,
          duration: Duration(seconds: 2),
        ),
      );
      await Future.delayed(const Duration(milliseconds: 500));
      if (mounted) Navigator.of(context).pop(true);
    } finally {
      _loginAttempting = false;
    }
  }

  /// 从 WebView 抓取该域名下的完整 Cookie（重试 6 次）
  Future<String?> _extractCookies() async {
    for (int attempt = 0; attempt < 6; attempt++) {
      if (attempt > 0) await Future.delayed(const Duration(milliseconds: 500));
      try {
        final cs = await CookieManager.instance()
            .getCookies(url: WebUri(_norm(widget.baseUrl)));
        if (cs.isNotEmpty) {
          return cs.map((c) => '${c.name}=${c.value}').join('; ');
        }
      } catch (_) {}
      if (Platform.isIOS) {
        try {
          // iOS 原生通道：直接从 WKWebsiteDataStore 读 Cookie，
          // 解决 CookieManager/document.cookie 抓不到会话 Cookie 的问题
          const ch = MethodChannel('com.cashcarry/cookies');
          final ck = await ch.invokeMethod('getCookies', {
            'url': _norm(widget.baseUrl),
          }) as String?;
          if (ck != null && ck.isNotEmpty) return ck;
        } catch (_) {}
      }
      if (_ctrl != null && attempt >= 4) {
        try {
          final ck =
              await _ctrl!.evaluateJavascript(source: 'document.cookie') as String?;
          if (ck != null && ck.isNotEmpty) return ck;
        } catch (_) {}
      }
    }
    return null;
  }

  void _showError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: AppConstants.errorColor,
        duration: const Duration(seconds: 4),
      ),
    );
  }

  /// window.open 拦截：银豹某些弹窗用 window.open，直接跳当前页
  static const String _openOverrideScript = '''
window.open=function(u,t,f){if(u&&typeof u==="string"&&u!==""&&u!=="about:blank"){window.location.href=u;}return window;};
''';

  /// JS 轮询：页面 URL 变化或检测到 Cookie 时通知 Flutter
  static const String _jsPollingScript = '''
(function(){
  if(window.__smarteye_polling) return;
  window.__smarteye_polling = true;

  var _lastUrl = window.location.href;
  var _checkCount = 0;

  setInterval(function(){
    _checkCount++;
    var currentUrl = window.location.href;

    if (currentUrl !== _lastUrl) {
      _lastUrl = currentUrl;
      window.flutter_inappwebview.callHandler("onJsDetect", currentUrl);
      return;
    }

    if (_checkCount % 5 === 0) {
      var pwFields = document.querySelectorAll("input[type=\\"password\\"]");
      var submitBtns = document.querySelectorAll("button[type=\\"submit\\"], input[type=\\"submit\\"]");
      var hasAuthForm = pwFields.length > 0 && submitBtns.length > 0;

      if (!hasAuthForm && document.cookie.length > 0) {
        window.flutter_inappwebview.callHandler("onJsDetect", currentUrl);
      }
    }
  }, 1000);
})();
''';

  Widget _buildInstructionBar() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      color: AppConstants.primaryColor.withValues(alpha: 0.05),
      child: Column(children: [
        if (_loading)
          const Text(
            '正在加载银豹登录页…',
            style: TextStyle(fontSize: 13, color: AppConstants.textSecondary),
          )
        else ...[
          const Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.qr_code_scanner, size: 18, color: AppConstants.primaryColor),
              SizedBox(width: 6),
              Expanded(
                child: Text(
                  '请用另一台手机打开微信，扫描屏幕上的二维码完成验证',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: AppConstants.primaryColor,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          const Text(
            '二维码不支持截图识别，必须用另一台手机实时扫码；'
            '若会话仍有效会直接进入后台，无需重新扫码',
            style: TextStyle(fontSize: 11, color: AppConstants.textSecondary),
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _manualCheck,
              icon: const Icon(Icons.check_circle_outline, size: 16),
              label: const Text('已完成扫码，点击验证登录', style: TextStyle(fontSize: 13)),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppConstants.primaryColor,
                side: const BorderSide(color: AppConstants.primaryColor),
                padding: const EdgeInsets.symmetric(vertical: 10),
              ),
            ),
          ),
        ],
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('微信扫码登录', style: TextStyle(fontSize: 16)),
        actions: [
          if (_loading)
            const Padding(
              padding: EdgeInsets.only(right: 16),
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
        ],
      ),
      body: Column(children: [
        _buildInstructionBar(),
        Expanded(
          child: InAppWebView(
            initialUrlRequest: null, // 等 Cookie 注入后再导航
            initialSettings: InAppWebViewSettings(
              javaScriptEnabled: true,
              userAgent: _ua,
              sharedCookiesEnabled: true,
            ),
            initialUserScripts: UnmodifiableListView([
              UserScript(
                source: _openOverrideScript,
                injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
              ),
              UserScript(
                source: _jsPollingScript,
                injectionTime: UserScriptInjectionTime.AT_DOCUMENT_END,
              ),
            ]),
            onWebViewCreated: (c) {
              _ctrl = c;
              _seedAndLoad(c);
              c.addJavaScriptHandler(handlerName: 'onJsDetect', callback: _onJsDetect);
            },
            shouldOverrideUrlLoading: _onUrlOverride,
            onUpdateVisitedHistory: _onUpdateVisitedHistory,
            onLoadStop: _onLoadStop,
          ),
        ),
      ]),
    );
  }
}