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
  /// - 优先解析子门店下拉框 <li data-userid="id">名称</li>
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
      final liRegex = RegExp(
          r'<li[^>]*data-userid="(\d+)"[^>]*>([^<]+)</li>',
          caseSensitive: false);
      for (final m in liRegex.allMatches(body)) {
        final name = m.group(2)!.trim().replaceAll('&nbsp;', ' ').trim();
        if (name.isEmpty) continue;
        stores.add(PospalSubStore(id: m.group(1)!, name: name));
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

  /// 验证会话是否真实有效
  /// GET /Product/Manage：未跳转登录页且页面含商品管理特征才算有效
  /// （防止把二维码登录页的残留 Cookie 误判为登录成功）
  /// 从登录页 WebView 的 DOM 提取门店列表（与 smart_eye_stock 相同的选择器）
  static const String jsExtractStores =
      "JSON.stringify([...document.querySelectorAll('ul[style*=\"width:284px\"] li[optionvalue]')].map(function(li){return{id:li.getAttribute('optionvalue'),name:li.textContent.replace(/&nbsp;/g,' ').trim()};}))";

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

  static Future<bool> validateCookie({
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
      req.followRedirects = false;
      final resp = await req.close().timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200) return false;

      // 302 跳转到登录页
      final loc = resp.headers.value('location');
      if (loc != null &&
          RegExp(r'signin|login', caseSensitive: false).hasMatch(loc)) {
        return false;
      }

      final body = await resp.transform(utf8.decoder).join();

      // 商品管理页特征
      if (RegExp(r'currentUserId\s*[=:]', caseSensitive: false)
          .hasMatch(body)) {
        return true;
      }
      if (body.contains('Product') ||
          body.contains('product') ||
          body.contains('商品') ||
          body.contains('库存') ||
          body.contains('条码') ||
          body.contains('LoadProductsByPage')) {
        return true;
      }

      // 明确的登录页特征
      if (body.contains('regularSignIn_box') ||
          body.contains('loginBox') ||
          body.contains('submitLoginBtn') ||
          body.contains('__RequestVerificationToken')) {
        return false;
      }

      return false;
    } catch (_) {
      return false;
    } finally {
      client.close();
    }
  }
}