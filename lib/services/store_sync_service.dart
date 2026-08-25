import 'dart:convert';
import 'dart:io';

/// 银豹子门店信息
class PospalSubStore {
  final String id;
  final String name;
  const PospalSubStore({required this.id, required this.name});
}

/// 门店同步服务（移植自 smart_eye_stock 的 StoreService）
///
/// 总账号（微信扫码）登录后，从银豹商品管理页 HTML 提取该账号下的
/// 所有门店列表（含门店ID），供「ID数据管理」使用。
class StoreSyncService {
  static const String _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  /// 从 Product/Manage 页面提取门店列表
  /// - 优先解析子门店下拉框 li[data-userid] / li[optionvalue]
  /// - 无子门店时回退为主店（currentUserId + currentShopName）
  static Future<List<PospalSubStore>> fetchStores({
    required String baseUrl,
    required String cookie,
  }) async {
    final url = Uri.parse(
        '${baseUrl.replaceAll(RegExp(r'/+$'), '')}/Product/Manage');
    final client = HttpClient();
    try {
      final req = await client.getUrl(url);
      req.headers.set('User-Agent', _ua);
      req.headers.set('Cookie', cookie);
      req.headers.set('Accept', 'text/html,application/xhtml+xml');
      final resp = await req.close().timeout(const Duration(seconds: 10));
      final body = await resp.transform(utf8.decoder).join();

      if (resp.statusCode != 200) return [];

      final stores = <PospalSubStore>[];

      // 主门店 ID
      final userIdMatch =
          RegExp(r'var\s+currentUserId\s*=\s*(\d+)\s*;').firstMatch(body);
      final mainId = userIdMatch?.group(1);

      // 子门店下拉框：<li ... data-userid="123" ...>名称</li>
      // 兼容 optionvalue 属性与单/双引号写法
      final liRegex = RegExp(
          r"""<li[^>]*(?:data-userid|optionvalue)\s*=\s*["']?(\d+)["']?[^>]*>([^<]+)</li>""",
          caseSensitive: false);
      final seen = <String>{};
      for (final m in liRegex.allMatches(body)) {
        final id = m.group(1)!;
        final name = m.group(2)!.trim().replaceAll('&nbsp;', ' ').trim();
        if (name.isEmpty || seen.contains(id)) continue;
        seen.add(id);
        stores.add(PospalSubStore(id: id, name: name));
      }

      // 无子门店下拉框时回退为主店
      if (stores.isEmpty && mainId != null) {
        final nameMatch =
            RegExp(r'currentShopName\s*=\s*"([^"]*)"').firstMatch(body);
        stores.add(PospalSubStore(
          id: mainId,
          name: nameMatch?.group(1) ?? '总店',
        ));
      }

      return stores;
    } finally {
      client.close();
    }
  }

  /// 验证会话是否真实有效（严格模式）
  /// GET /Product/Manage：页面必须包含商品管理页强特征
  /// （currentUserId / currentShopName / LoadProductsByPage）才算有效；
  /// 出现登录页特征则直接判无效，避免把二维码登录页残留 Cookie 误判为登录成功。
  /// 可通过 [onReport] 回调把页面特征报告给调用方（用于诊断日志）。
  static Future<bool> validateCookie({
    required String baseUrl,
    required String cookie,
    void Function(Map<String, dynamic> report)? onReport,
  }) async {
    final url = Uri.parse(
        '${baseUrl.replaceAll(RegExp(r'/+$'), '')}/Product/Manage');
    final client = HttpClient();
    try {
      final req = await client.getUrl(url);
      req.headers.set('User-Agent', _ua);
      req.headers.set('Cookie', cookie);
      req.headers.set('Accept', 'text/html,application/xhtml+xml');
      req.followRedirects = false;
      final resp = await req.close().timeout(const Duration(seconds: 10));

      // 302 跳转到登录页
      final loc = resp.headers.value('location') ?? '';
      final redirectToLogin = loc.isNotEmpty &&
          RegExp(r'signin|login', caseSensitive: false).hasMatch(loc);

      if (resp.statusCode != 200 || redirectToLogin) {
        onReport?.call({
          'statusCode': resp.statusCode,
          'redirect': loc,
          'valid': false,
          'reason': redirectToLogin ? 'redirect-to-login' : 'http-${resp.statusCode}',
        });
        return false;
      }

      final body = await resp.transform(utf8.decoder).join();

      // 商品管理页强特征（登录页不会出现）
      final hasCurrentUserId =
          RegExp(r'currentUserId\s*[=:]', caseSensitive: false).hasMatch(body);
      final hasCurrentShopName =
          RegExp(r'currentShopName\s*=', caseSensitive: false).hasMatch(body);
      final hasLoadProducts = body.contains('LoadProductsByPage');

      // 明确的登录页特征
      final loginMarkers = [
        'regularSignIn_box',
        'loginBox',
        'submitLoginBtn',
        '__RequestVerificationToken',
        'loginForm',
      ];
      final isLoginPage = loginMarkers.any(body.contains);

      final valid = (hasCurrentUserId || hasCurrentShopName || hasLoadProducts) &&
          !isLoginPage;

      onReport?.call({
        'statusCode': resp.statusCode,
        'bodyLength': body.length,
        'hasCurrentUserId': hasCurrentUserId,
        'hasCurrentShopName': hasCurrentShopName,
        'hasLoadProducts': hasLoadProducts,
        'isLoginPage': isLoginPage,
        'valid': valid,
      });
      return valid;
    } catch (e) {
      onReport?.call({'error': '$e', 'valid': false});
      return false;
    } finally {
      client.close();
    }
  }

  /// 从登录页 WebView 的 DOM 提取门店列表（与 smart_eye_stock 相同的选择器）
  static const String jsExtractStores =
      "JSON.stringify([...document.querySelectorAll('ul[style*=\"width:284px\"] li[optionvalue]')].map(function(li){return{id:li.getAttribute('optionvalue'),name:li.textContent.replace(/&nbsp;/g,' ').trim()};}))";

  /// 宽泛选择器 + 轮询等待的提取脚本（配合 callAsyncJavaScript 使用），
  /// 兼容下拉框延迟渲染、属性写法差异等情况，最长等待约 8 秒，
  static const String jsExtractStoresPoll = '''
var selectors = [
  'ul[style*="width:284px"] li[optionvalue]',
  'ul[style*="width: 284px"] li[optionvalue]',
  'li[optionvalue][data-userid]',
  'li[optionvalue]',
  'li[data-userid]'
];
function extract() {
  var seen = {};
  var out = [];
  for (var s = 0; s < selectors.length; s++) {
    var nodes = document.querySelectorAll(selectors[s]);
    for (var i = 0; i < nodes.length; i++) {
      var li = nodes[i];
      var id = li.getAttribute('optionvalue') || li.getAttribute('data-userid');
      if (!id || seen[id]) continue;
      seen[id] = 1;
      var name = (li.textContent || '').replace(/&nbsp;/g, ' ').trim();
      if (!name) name = li.getAttribute('data-name') || '';
      if (name) out.push({id: id, name: name});
    }
  }
  return out;
}
var start = Date.now();
var lastCount = -1;
var stableCount = 0;
while (true) {
  var list = extract();
  if (list.length === lastCount) {
    stableCount++;
  } else {
    stableCount = 0;
    lastCount = list.length;
  }
  // 门店数量连续 3 次一致才认为渲染完成（避免只渲染一半就返回）
  if ((list.length > 0 && stableCount >= 3) || Date.now() - start > 8000) {
    return JSON.stringify(list);
  }
  await new Promise(function (r) { setTimeout(r, 400); });
}
''';

  /// 解析 JS 提取返回值（兼容 String/List 两种格式）
  static List<PospalSubStore> parseStoresValue(Object? value) {
    if (value is String) return parseStoresJson(value);
    if (value is List) {
      final stores = <PospalSubStore>[];
      for (final item in value) {
        if (item is Map) {
          final id = (item['id'] ?? '').toString();
          final name = (item['name'] ?? '').toString();
          if (id.isNotEmpty) {
            stores.add(PospalSubStore(id: id, name: name));
          }
        }
      }
      return stores;
    }
    return const [];
  }

  /// 解析 JS 提取结果 JSON 为门店列表
  static List<PospalSubStore> parseStoresJson(String? raw) {
    final stores = <PospalSubStore>[];
    if (raw == null || raw.trim().isEmpty) return stores;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        for (final item in decoded) {
          if (item is Map) {
            final id = (item['id'] ?? '').toString();
            final name = (item['name'] ?? '').toString();
            if (id.isNotEmpty) {
              stores.add(PospalSubStore(id: id, name: name));
            }
          }
        }
      }
    } catch (_) {}
    return stores;
  }
}
