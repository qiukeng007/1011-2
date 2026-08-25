import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import '../services/login_diag.dart';
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
///
/// 门店提取时机（与 smart_eye_stock 一致）：
/// 只在页面加载完成（onLoadStop）之后才做登录验证与门店提取，
/// 避免 URL 变化事件在页面还没渲染时就用旧 Cookie 误判登录成功，
/// 导致提取门店时页面是空的（iOS 上更明显）。
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
  bool _storesLoaded = false;
  bool _pageReady = false;

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

  Future<void> _diag(String msg) async {
    await LoginDiagLogger().log(msg);
  }

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
        await _diag('已注入本地Cookie ${saved.split(';').length} 条');
      } else {
        await _diag('本地无保存的Cookie，直接打开登录页');
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
    // 与 smart_eye_stock 一致：页面未加载完成前不做登录检测，
    // 避免 URL 刚变化（页面还是空的）时就触发提取
    if (!_pageReady) return;
    final u = url.toString();
    if (_isOAuthPage(u)) return;
    if (_isAuthPage(u)) _injectFill();
    if (u.contains('/Product/Manage') || u.contains('/product/manage')) {
      _tryLogin(currentUrl: u);
    }
  }

  void _onLoadStop(InAppWebViewController c, Uri? url) {
    if (url == null) return;
    final u = url.toString();
    _pageReady = true;
    setState(() => _loading = false);
    if (_isOAuthPage(u)) return;
    if (_isAuthPage(u)) _injectFill();
    if (u.contains('/Product/Manage') || u.contains('/product/manage')) {
      // 已登录但门店还没提取到：页面这次重新加载完成，正好从新 DOM 提取
      if (_loggedIn && !_storesLoaded) {
        _scheduleStoreRetry();
        return;
      }
      _tryLogin(currentUrl: u);
    }
  }

  void _onJsDetect(List<dynamic> args) {
    if (_loggedIn || !_pageReady) return;
    try {
      final data = args.isNotEmpty ? args[0] as String : '';
      if (_isOAuthPage(data)) return;
      _tryLogin(currentUrl: data);
    } catch (_) {}
  }

  /// 手动验证（扫码完成后用户点击按钮）
  Future<void> _manualCheck() async {
    if (_loggedIn) return;
    await _diag('用户手动点击验证');
    String currentUrl = '';
    if (_ctrl != null) {
      try {
        final u = await _ctrl!.getUrl();
        currentUrl = u?.toString() ?? '';
      } catch (_) {}
    }
    await _tryLogin(currentUrl: currentUrl, manual: true);
  }

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
        if(window.__cashcarry_filled) return;
        var emp=document.querySelector('span[data-type="2"]');if(emp)emp.click();
        setTimeout(function(){
          var pw=document.querySelectorAll('input[type="password"]');
          if(pw.length===0) return;
          window.__cashcarry_filled=true;
          var a=document.getElementById('txt_userName')||document.querySelector('input[placeholder*="账号"]');
          if(a && $accountJs !== ''){a.value=$accountJs;a.dispatchEvent(new Event('input',{bubbles:true}));a.dispatchEvent(new Event('change',{bubbles:true}));}
          var j=document.getElementById('txt_cashierJobName');
          if(j && $employeeJs !== ''){j.value=$employeeJs;j.dispatchEvent(new Event('input',{bubbles:true}));j.dispatchEvent(new Event('change',{bubbles:true}));}
          for(var i=0;i<pw.length;i++){pw[i].value=$passwordJs;pw[i].dispatchEvent(new Event('input',{bubbles:true}));pw[i].dispatchEvent(new Event('change',{bubbles:true}));}
          setTimeout(function(){
            var btn=document.querySelector('button[type="submit"]')||document.querySelector('input[type="submit"]')||document.querySelector('button.btn-primary')||document.querySelector('a.btn-primary')||document.querySelector('button[class*="login"]')||document.querySelector('button[class*="submit"]')||document.querySelector('a[class*="login"]');
            if(btn)btn.click();else{var fs=document.querySelectorAll('form');for(var f=0;f<fs.length;f++)try{fs[f].submit()}catch(e){}}
          },400);
        },500);
      })();
    ''');
  }

  /// 从当前页面 DOM 提取门店列表
  /// 1) 精确选择器（与智能眼一致）重试 3 次
  /// 2) 宽泛选择器 + 轮询等待（下拉框延迟渲染兜底）
  /// 3) 始终再用 HTTP 抓取一次，与 JS 结果按门店ID合并去重，
  ///    保证即使页面下拉框只渲染了部分门店，也能补齐全量门店
  Future<List<PospalSubStore>> _extractStores(String cookie) async {
    final merged = <String, PospalSubStore>{};
    void merge(List<PospalSubStore> list) {
      for (final s in list) {
        merged.putIfAbsent(s.id, () => s);
      }
    }

    // 1) 精确选择器，重试 3 次
    for (int attempt = 0; attempt < 3; attempt++) {
      try {
        if (_ctrl != null) {
          final result = await _ctrl!.evaluateJavascript(
            source: StoreSyncService.jsExtractStores,
          );
          final raw = result?.toString() ?? 'null';
          final stores = StoreSyncService.parseStoresValue(result);
          await _diag('JS精确提取(第${attempt + 1}次): $raw → ${stores.length}个');
          if (stores.isNotEmpty) {
            merge(stores);
            break;
          }
        }
      } catch (e) {
        await _diag('JS精确提取异常(第${attempt + 1}次): $e');
      }
      if (attempt < 2) {
        await Future.delayed(const Duration(milliseconds: 600));
      }
    }
    // 2) 宽泛选择器 + 轮询等待
    try {
      if (_ctrl != null) {
        final result = await _ctrl!.callAsyncJavaScript(
          functionBody: StoreSyncService.jsExtractStoresPoll,
        );
        final raw = result?.value?.toString() ?? 'null';
        final stores = StoreSyncService.parseStoresValue(result?.value);
        await _diag('JS宽泛轮询提取: $raw → ${stores.length}个');
        if (stores.isNotEmpty) merge(stores);
      }
    } catch (e) {
      await _diag('JS宽泛轮询提取异常: $e');
    }
    // 3) HTTP 提取：始终执行，用于补齐 JS 漏掉的门店
    try {
      final stores = await StoreSyncService.fetchStores(
        baseUrl: _norm(widget.baseUrl),
        cookie: cookie,
      );
      await _diag('HTTP提取: ${stores.length}个');
      merge(stores);
    } catch (e) {
      await _diag('HTTP提取异常: $e');
    }
    await _diag('门店提取合并结果: ${merged.length}个');
    return merged.values.toList();
  }

  /// 登录成功后门店为空时，延迟重试提取（等页面下拉框渲染完成）
  void _scheduleStoreRetry() {
    Future.delayed(const Duration(milliseconds: 1500), () async {
      if (!mounted || !_loggedIn || _storesLoaded || _ctrl == null) return;
      await _diag('登录成功后延迟重试提取门店');
      try {
        final ck = await widget.sessionManager.getCookie(widget.storeKey);
        if (ck == null || ck.isEmpty) return;
        final stores = await _extractStores(ck);
        if (!mounted || _storesLoaded) return;
        if (stores.isNotEmpty) {
          _storesLoaded = true;
          widget.onStoresLoaded?.call(stores);
        } else {
          // 再补一次
          await Future.delayed(const Duration(milliseconds: 2000));
          if (!mounted || !_loggedIn || _storesLoaded || _ctrl == null) return;
          final ck2 = await widget.sessionManager.getCookie(widget.storeKey);
          if (ck2 == null || ck2.isEmpty) return;
          final s2 = await _extractStores(ck2);
          if (!mounted || _storesLoaded) return;
          if (s2.isNotEmpty) {
            _storesLoaded = true;
            widget.onStoresLoaded?.call(s2);
          }
        }
      } catch (_) {}
    });
  }

  Future<void> _tryLogin({String currentUrl = '', bool manual = false}) async {
    if (_loggedIn || _loginAttempting) return;
    _loginAttempting = true;
    try {
      await _diag('开始登录验证 currentUrl=$currentUrl manual=$manual');
      final ck = await _extractCookies();
      if (ck == null || ck.isEmpty) {
        await _diag('未提取到 Cookie，等待扫码…');
        if (manual) _showError('未检测到登录信息，请确认已在微信中完成扫码验证');
        return;
      }
      // 关键：验证会话真实有效，防止二维码登录页的残留 Cookie 被误判为登录成功
      Map<String, dynamic>? report;
      var valid = await StoreSyncService.validateCookie(
        baseUrl: _norm(widget.baseUrl),
        cookie: ck,
        onReport: (r) => report = r,
      );
      await _diag('Cookie验证报告: ${jsonEncode(report ?? const {})}');

      // 登录成功后，会话可能尚未完全落定（首次登录时更明显）：
      // 稍等片刻重新抓取一份更完整的 Cookie，并再次验证，
      // 避免保存到不完整会话导致只能看到主店、看不到分店
      var finalCk = ck;
      if (valid) {
        for (int i = 0; i < 3; i++) {
          await Future.delayed(const Duration(milliseconds: 1000));
          final fresh = await _extractCookies();
          if (fresh == null || fresh.isEmpty) break;
          // Cookie 不再变长说明会话已稳定，无需再等
          if (fresh.length <= finalCk.length) break;
          final ok2 = await StoreSyncService.validateCookie(
            baseUrl: _norm(widget.baseUrl),
            cookie: fresh,
          );
          if (ok2) {
            finalCk = fresh;
            await _diag('会话落定后重新抓取 Cookie: ${finalCk.length}字符');
            break;
          }
        }
      }

      // 从页面 DOM 提取门店：页面若已进入 /Product/Manage，
      // DOM 里的门店下拉框就是「确实已登录」的最可靠证据（iOS 上
      // HTTP 验证可能因 Cookie 同步延迟而失败，但页面其实已登录）
      var stores = await _extractStores(finalCk);

      if (!valid && stores.isEmpty) {
        await _diag('验证未通过且页面无门店数据，等待扫码…');
        if (manual) _showError('未检测到有效登录，请用微信完成扫码后重试');
        return;
      }

      // 门店下拉框是页面加载后异步渲染的：首次登录时可能还没渲染完，
      // 弹回配置页前多等几次，确保拿到全部门店（避免只显示一个门店）
      if (stores.isEmpty) {
        await _diag('门店下拉框可能未渲染完，等待重试…');
        for (int i = 0; i < 4 && stores.isEmpty; i++) {
          await Future.delayed(const Duration(seconds: 2));
          if (!mounted) return;
          stores = await _extractStores(finalCk);
        }
      }

      await widget.sessionManager.saveCookie(widget.storeKey, finalCk, via: 'wechat');
      widget.onLoggedIn(finalCk);
      _loggedIn = true;
      await _diag('登录成功，Cookie ${finalCk.length} 字符，提取门店 ${stores.length}个');

      if (!_storesLoaded && stores.isNotEmpty) {
        _storesLoaded = true;
        widget.onStoresLoaded?.call(stores);
      } else if (!_storesLoaded) {
        _scheduleStoreRetry();
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

  /// 从 WebView 抓取该域名下的完整 Cookie（多来源取最长，重试 6 次）
  Future<String?> _extractCookies() async {
    for (int attempt = 0; attempt < 6; attempt++) {
      if (attempt > 0) await Future.delayed(const Duration(milliseconds: 500));
      String? best;
      int bestLen = 0;
      String bestSource = '';
      // 1) CookieManager（插件，iOS 读 WKWebsiteDataStore）
      try {
        final cs = await CookieManager.instance()
            .getCookies(url: WebUri(_norm(widget.baseUrl)));
        if (cs.isNotEmpty) {
          final ck = cs.map((c) => '${c.name}=${c.value}').join('; ');
          if (ck.length > bestLen) {
            best = ck;
            bestLen = ck.length;
            bestSource = 'CookieManager(${cs.length}个)';
          }
        }
      } catch (_) {}
      // 2) iOS 原生通道（直接读 WKWebsiteDataStore）
      if (Platform.isIOS) {
        try {
          const ch = MethodChannel('com.cashcarry/cookies');
          final ck = await ch.invokeMethod('getCookies', {
            'url': _norm(widget.baseUrl),
          }) as String?;
          if (ck != null && ck.isNotEmpty && ck.length > bestLen) {
            best = ck;
            bestLen = ck.length;
            bestSource = 'iOS原生通道';
          }
        } catch (_) {}
      }
      // 3) document.cookie（不含 HttpOnly，最后手段）；
      //    仅当 WebView 当前页面属于本后台域名时采用，避免把 OAuth 中间页
      //    （user.pospal.cn）的 Cookie 误当成本后台会话
      if (attempt >= 2 && _ctrl != null) {
        try {
          String curUrl = '';
          try {
            curUrl = (await _ctrl!.getUrl())?.toString() ?? '';
          } catch (_) {}
          final host = Uri.parse(_norm(widget.baseUrl)).host;
          if (curUrl.contains(host)) {
            final ck = await _ctrl!.evaluateJavascript(
                source: 'document.cookie') as String?;
            if (ck != null && ck.isNotEmpty && ck.length > bestLen) {
              best = ck;
              bestLen = ck.length;
              bestSource = 'document.cookie';
            }
          }
        } catch (_) {}
      }
      if (best != null && best.isNotEmpty) {
        await _diag('Cookie来源(第${attempt + 1}次): $bestSource，${best.length}字符');
        return best;
      }
    }
    await _diag('Cookie 提取失败（6次均无结果）');
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

  /// 复制诊断日志到剪贴板（供发回排查）
  Future<void> _copyDiagLogs() async {
    try {
      final text = await LoginDiagLogger().exportText();
      await Clipboard.setData(ClipboardData(text: text));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('诊断日志已复制到剪贴板，请粘贴发回'),
          duration: Duration(seconds: 3),
        ),
      );
    } catch (_) {}
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
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: _copyDiagLogs,
              icon: const Icon(Icons.bug_report_outlined, size: 14),
              label: const Text('诊断日志', style: TextStyle(fontSize: 12)),
              style: TextButton.styleFrom(
                foregroundColor: AppConstants.textSecondary,
                padding: const EdgeInsets.symmetric(horizontal: 8),
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
