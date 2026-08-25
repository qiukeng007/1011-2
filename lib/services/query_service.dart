import 'dart:convert';
import 'dart:io';
import '../models/store_config.dart';
import '../models/product_result.dart';
import '../models/query_log.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'session_manager.dart';
import 'query_logger.dart';

/// 条码查询服务
///
/// 银豹新版查询 API（2025年）：
/// 旧的查询接口（/Product/QueryProducts, /Product/QueryProductByBarcode 等）已废弃，
/// 全部返回 302 重定向到 /?error=404。
///
/// 新的查询流程：
/// 1. GET /Product/Manage 获取页面，提取 currentUserId（门店ID）
/// 2. POST /Product/LoadProductsByPage 提交查询参数（form-encoded）
///    参数：userId, enable, productTagUidsJson, keyword, groupBySpu,
///          categorysJson, supplierUid, categoryType, pageIndex, pageSize
/// 3. 解析返回的 HTML 表格提取商品数据
///
/// 也可先调用 /Product/LoadProductSummary 获取匹配数量。
class QueryService {
  final SessionManager _sessionManager;
  late final HttpClient _httpClient;

  static const String _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';
  /// 已预热（切换到目标门店会话）的门店ID集合，避免每次查询重复切店
  final Set<String> _warmedStores = {};

  /// 供货商名称→uid 缓存（storeKey → map），内存 + SharedPreferences 持久化
  final Map<String, Map<String, String>> _supplierUidCache = {};

  static const String _supplierUidCachePrefix = 'supplier_uid_map_';


  QueryService(this._sessionManager) {
    _httpClient = HttpClient();
    _httpClient.autoUncompress = true;
    _httpClient.connectionTimeout = const Duration(seconds: 15);
  }

  /// 通过 GET Product/Manage?userId= 把账号会话切换到目标门店（网页端切店方式）
  Future<void> _warmStoreSession(
    String baseUrl,
    String storeId,
    String cookie,
  ) async {
    try {
      final uri = Uri.parse('$baseUrl/Product/Manage?userId=$storeId');
      final request = await _httpClient.getUrl(uri);
      request.headers.set('User-Agent', _ua);
      request.headers.set('Accept', 'text/html,application/xhtml+xml');
      request.headers.set('Cookie', cookie);
      request.followRedirects = false;
      final response = await request.close().timeout(const Duration(seconds: 8));
      await _readBody(response);
    } catch (_) {}
  }

  /// 总账号模式直接使用门店ID（并切店预热），旧工号模式回退 _getUserId
  Future<String?> _resolveStoreUserId(StoreConfig store, String cookie) async {
    final baseUrl = store.baseUrl.replaceAll(RegExp(r'/$'), '');
    final userId = store.storeId.isNotEmpty
        ? store.storeId
        : await _getUserId(baseUrl, store.storeKey, cookie);
    if (store.storeId.isNotEmpty && !_warmedStores.contains(store.storeId)) {
      _warmedStores.add(store.storeId);
      await _warmStoreSession(baseUrl, store.storeId, cookie);
    }
    return userId;
  }


  /// 释放 HttpClient 资源
  void dispose() {
    _httpClient.close();
  }

  /// 查询单个门店的条码
  /// [timer] 可选，用于记录每步耗时诊断
  Future<ProductResult> queryByBarcode(
    StoreConfig store,
    String barcode, {
    QueryStepTimer? timer,
  }) async {
    final baseUrl = store.baseUrl.replaceAll(RegExp(r'/$'), '');
    final code = barcode.trim();
    if (code.isEmpty) {
      timer?.record('参数校验', detail: '条码为空');
      return const ProductResult(ok: false, error: '请输入商品条码');
    }

    timer?.record('加载Cookie');
    final cookie = await _sessionManager.getCookie(store.storeKey);
    if (cookie == null || cookie.isEmpty) {
      timer?.record('加载Cookie', detail: '未找到cookie');
      return const ProductResult(ok: false, error: '未登录，请先在设置里登录（工号或微信扫码）');
    }

    try {
      // Step 1: 获取 userId——总账号同步模式直接使用门店ID，缓存仅在缺失时兜底
      final userId = store.storeId.isNotEmpty
          ? store.storeId
          : await _getUserId(baseUrl, store.storeKey, cookie, timer: timer);
      if (userId == null) {
        timer?.record('获取userId', detail: '失败');
        return ProductResult(
          ok: false,
          error: '${store.name} 无法获取门店信息，请重新登录',
        );
      }

      // Step 2: 先切到目标门店会话（微信扫码后会话默认停在总店，需切店后查询才返回该店库存）
      if (store.storeId.isNotEmpty && !_warmedStores.contains(store.storeId)) {
        _warmedStores.add(store.storeId);
        await _warmStoreSession(baseUrl, store.storeId, cookie);
      }

      // Step 3: 调用 LoadProductsByPage 搜索条码
      final referer = '$baseUrl/Product/Manage';
      final pageData = _encodeForm({
        'userId': userId,
        'enable': '1',
        'productTagUidsJson': '[]',
        'keyword': code,
        'groupBySpu': 'false',
        'categorysJson': '[]',
        'supplierUid': '',
        'categoryType': '',
        'pageIndex': '1',
        'pageSize': '20',
        'orderColumn': '',
        'asc': 'true',
      });

      final uri = Uri.parse('$baseUrl/Product/LoadProductsByPage');
      final request = await _httpClient.postUrl(uri);
      request.headers.set('User-Agent', _ua);
      request.headers.set('Accept', 'application/json, text/javascript, */*');
      request.headers.set('Referer', referer);
      request.headers.set('Origin', baseUrl);
      request.headers.set('X-Requested-With', 'XMLHttpRequest');
      request.headers.set('Content-Type',
          'application/x-www-form-urlencoded; charset=UTF-8');
      request.headers.set('Cookie', cookie);
      request.followRedirects = false;

      request.write(pageData);

      final response = await request.close().timeout(const Duration(seconds: 15));
      final statusCode = response.statusCode;
      final body = await _readBody(response);
      timer?.record('POST搜索', detail: 'HTTP $statusCode, 响应${body.length}字节');

      // 检查是否登录失效
      if (statusCode == 302 || statusCode == 301) {
        final location = response.headers.value('location') ?? '';
        if (RegExp(r'signin|login', caseSensitive: false).hasMatch(location)) {
          timer?.record('会话检查', detail: 'cookie过期需重登');
          // 清除过期 cookie 和 userId 缓存
          await _sessionManager.deleteCookie(store.storeKey);
          return ProductResult(
            ok: false,
            error: '${store.name} 登录已失效，请重新登录',
          );
        }
      }

      if (statusCode != 200) {
        timer?.record('HTTP状态', detail: '非200: $statusCode');
        return ProductResult(
          ok: false,
          error: '${store.name} 查询失败 (HTTP $statusCode)',
        );
      }

      // 解析 JSON 响应
      Map<String, dynamic> data;
      try {
        data = jsonDecode(body) as Map<String, dynamic>;
      } catch (_) {
        timer?.record('JSON解析', detail: '格式异常');
        return ProductResult(
          ok: false,
          error: '${store.name} 查询返回格式异常',
        );
      }

      if (data['successed'] != true) {
        timer?.record('查询结果', detail: 'successed!=true');
        return ProductResult(
          ok: false,
          error: '${store.name} 查询失败',
        );
      }

      // 从 HTML 表格中解析商品数据
      final contentView = data['contentView'] as String? ?? '';
      if (contentView.isEmpty) {
        timer?.record('HTML解析', detail: 'contentView为空');
        return ProductResult(
          ok: false,
          error: '未找到该条码商品',
        );
      }

      final products = _parseProductTable(contentView);
      timer?.record('HTML解析', detail: '${contentView.length}字节→${products.length}条商品');

      if (products.isEmpty) {
        return ProductResult(
          ok: false,
          error: '未找到该条码商品',
        );
      }

      // 查找匹配条码的商品（精确匹配优先；无精确匹配时用整页结果兜底）
      final matched = products.where((p) =>
          p['barcode'] == code || p['barcode']?.trim() == code).toList();

      final pool = matched.isNotEmpty ? matched : products;
      if (pool.isEmpty) {
        return ProductResult(ok: false, error: '未找到该条码商品');
      }

      // 构建候选商品列表（多条匹配时供用户弹窗选择）
      final candidateProducts = pool.map((raw) {
        return ProductData(
          barcode: raw['barcode'] ?? code,
          name: raw['name'] ?? '',
          specification: raw['specification'] ?? '',
          category: raw['category'] ?? '',
          stock: raw['stock'],
          unit: raw['unit'] ?? '—',
          supplier: raw['supplier'] ?? '',
          sellPrice: raw['sellPrice'],
          buyPrice: raw['buyPrice'],
          uid: raw['uid'],
          imageUrl: raw['imageUrl'] ?? '',
          allColumns: raw['_allColumns'] as String?,
        );
      }).toList();

      // 诊断：库存为 0/缺失时记录原始列数据，便于确认是否查错门店或列错位
      final primaryCols = candidateProducts.first.allColumns;
      if ((candidateProducts.first.stock == null || candidateProducts.first.stock == 0) &&
          primaryCols != null &&
          primaryCols.isNotEmpty) {
        timer?.record('库存明细', detail: primaryCols);
      }

      final product = candidateProducts.first.copyWith(
        multipleMatches: candidateProducts.length > 1 ? candidateProducts.length : null,
        candidates: candidateProducts.length > 1 ? candidateProducts : null,
      );

      return ProductResult(ok: true, data: product);
    } catch (e) {
      timer?.record('异常', detail: e.toString());
      return ProductResult(
        ok: false,
        error: '${store.name} 查询异常：${e.toString()}',
      );
    }
  }

  /// 获取 userId：优先从 SessionManager 缓存读取，缓存 miss 时才发 HTTP
  Future<String?> _getUserId(String baseUrl, String storeKey, String cookie, {QueryStepTimer? timer}) async {
    // 1. 尝试缓存
    final cached = await _sessionManager.getUserId(storeKey);
    if (cached != null && cached.isNotEmpty) {
      timer?.record('获取userId', detail: '缓存命中');
      return cached;
    }

    // 2. 缓存 miss → 发 HTTP 提取
    timer?.record('获取userId', detail: '缓存未命中，发起HTTP');
    final userId = await _fetchUserId(baseUrl, cookie, _httpClient);
    if (userId != null) {
      timer?.record('提取userId', detail: 'userId=$userId');
      await _sessionManager.saveUserId(storeKey, userId);
    }
    return userId;
  }

  /// 保活：静默 GET /Product/Manage，刷新 session 并更新 userId 缓存
  /// 返回 true = Cookie 有效，false = 已过期需重登
  Future<bool> keepAlive(StoreConfig store) async {
    for (int attempt = 0; attempt < 2; attempt++) {
      try {
        final baseUrl = store.baseUrl.replaceAll(RegExp(r'/$'), '');
        final cookie = await _sessionManager.getCookie(store.storeKey);
        if (cookie == null || cookie.isEmpty) return false;

        final uri = Uri.parse('$baseUrl/Product/Manage');
        final request = await _httpClient.getUrl(uri);
        request.headers.set('User-Agent', _ua);
        request.headers.set('Accept', 'text/html,application/xhtml+xml');
        request.headers.set('Cookie', cookie);
        request.followRedirects = false;

        final response = await request.close().timeout(const Duration(seconds: 10));
        final body = await _readBody(response);

        if (response.statusCode != 200) return false;

        // ??????????
        if (response.headers.value('location') != null &&
            RegExp(r'signin|login', caseSensitive: false).hasMatch(response.headers.value('location')!)) {
          return false; // Cookie ???
        }

        // ?? userId ??
        final userId = _extractUserIdFromBody(body);
        if (userId != null) {
          await _sessionManager.saveUserId(store.storeKey, userId);
        }
        return true;
      } catch (_) {
        if (attempt == 0) {
          await Future.delayed(const Duration(seconds: 2));
        }
      }
    }
    return false; // ??????????
  }

  /// 从 Product/Manage 页面 HTML 提取 currentUserId
  String? _extractUserIdFromBody(String body) {
    final m1 = RegExp(r'var\s+currentUserId\s*=\s*(\d+)\s*;', caseSensitive: false).firstMatch(body);
    if (m1 != null) return m1.group(1);
    final m2 = RegExp(r'''currentUserId['"]?\s*[:=]\s*['"]?(\d+)['"]?''', caseSensitive: false).firstMatch(body);
    if (m2 != null) return m2.group(1);
    final m3 = RegExp(r'id="hf_storeId"\s+value="(\d+)"', caseSensitive: false).firstMatch(body);
    if (m3 != null) return m3.group(1);
    final m4 = RegExp(r'''data-storeid\s*=\s*['"](\d+)['"]''', caseSensitive: false).firstMatch(body);
    if (m4 != null) return m4.group(1);
    return null;
  }

  /// 从商品管理页提取 currentUserId（HTTP 请求，仅在缓存 miss 时使用）
  Future<String?> _fetchUserId(
    String baseUrl,
    String cookie,
    HttpClient httpClient,
  ) async {
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

      // 检查是否被重定向到登录页
      if (response.headers.value('location') != null &&
          RegExp(r'signin|login', caseSensitive: false)
              .hasMatch(response.headers.value('location')!)) {
        return null;
      }

      // 提取 currentUserId (多种格式)
      // 格式1: var currentUserId = 12345;
      final userIdMatch = RegExp(
        r'var\s+currentUserId\s*=\s*(\d+)\s*;',
        caseSensitive: false,
      ).firstMatch(body);
      if (userIdMatch != null) {
        return userIdMatch.group(1);
      }

      // 格式2: currentUserId: 12345 (JSON格式)
      // 使用 [\\'\"] 匹配引号，避免 Dart raw string 转义问题
      final userIdMatch2 = RegExp(
        r'''currentUserId['"]?\s*[:=]\s*['"]?(\d+)['"]?''',
        caseSensitive: false,
      ).firstMatch(body);
      if (userIdMatch2 != null) {
        return userIdMatch2.group(1);
      }

      // 备选：从 hf_storeId 提取
      final storeIdMatch = RegExp(
        r'id="hf_storeId"\s+value="(\d+)"',
        caseSensitive: false,
      ).firstMatch(body);
      if (storeIdMatch != null) {
        return storeIdMatch.group(1);
      }

      // 备选：从 data-storeid 属性提取
      final dataStoreIdMatch = RegExp(
        r'''data-storeid\s*=\s*['"](\d+)['"]''',
        caseSensitive: false,
      ).firstMatch(body);
      if (dataStoreIdMatch != null) {
        return dataStoreIdMatch.group(1);
      }

      return null;
    } catch (_) {
      return null;
    }
  }

  /// 解析 LoadProductsByPage 返回的 HTML 表格
  ///
  /// 使用 `<thead>` 中 `<th>` 的 `data` 属性动态建立列名→索引映射，
  /// 避免不同门店因列配置不同（启用/禁用自定义列）导致的索引偏移问题。
  ///
  /// 常见列名（data 属性值）：
  ///   name, barcode, attribute4(货号), extBarcode(扩展码), brandName(品牌),
  ///   attribute6(规格), pinyin(拼音码), categoryName(分类),
  ///   stock(库存), baseUnitName(主单位),
  ///   sellPrice(销售价), buyPrice(进货价), wholeSalePrice(批发价),
  ///   memberPrice(会员价), isCustomerDiscount(会员折扣),
  ///   supplierName(供货商), produceDate(生产日期), shelfLife(保质期),
  ///   createDate(创建日期), customField1/2/3(自定义字段)
  List<Map<String, dynamic>> _parseProductTable(String html) {
    final products = <Map<String, dynamic>>[];

    // Step 1: 解析表头，建立列名→索引映射
    final colMap = _parseTableHeader(html);
    if (colMap.isEmpty) {
      // 如果表头解析失败，回退到旧逻辑
      return _parseProductTableLegacy(html);
    }

    // 辅助函数：按列名取值
    String? colVal(List<String> tds, String name) {
      final idx = colMap[name];
      if (idx == null || idx >= tds.length) return null;
      return tds[idx];
    }

    // 按列名取原始（未去标签）HTML，名称列需要读取属性
    String? colValRaw(List<String> rawTds, String name) {
      final idx = colMap[name];
      if (idx == null || idx >= rawTds.length) return null;
      return rawTds[idx];
    }

    // Step 2: 匹配每个商品行 <tr data="..." data-uid="...">
    final rowRegex = RegExp(
      r'<tr\s+data="(\d+)"\s+data-uid="(\d+)"[^>]*>([\s\S]*?)</tr>',
      caseSensitive: false,
    );

    for (final rowMatch in rowRegex.allMatches(html)) {
      final uid = rowMatch.group(2);
      final rowHtml = rowMatch.group(3) ?? '';

      // 提取所有 <td> 内容（保留原始HTML，名称列需读取 title/data-name 完整名称）
      final tdRegex = RegExp(
        r'<td[^>]*>([\s\S]*?)</td>',
        caseSensitive: false,
      );
      final rawTds = tdRegex.allMatches(rowHtml).map((m) =>
          m.group(1)?.trim() ?? '').toList();
      final tds = rawTds.map(_stripHtml).toList();

      if (tds.length < 10) continue;

      // 构建所有列原始数据（用于调试列索引偏移）
      final allColsBuf = StringBuffer();
      for (var i = 0; i < tds.length; i++) {
        if (i > 0) allColsBuf.write(' | ');
        // 尝试查找该索引对应的列名
        String? colName;
        for (final entry in colMap.entries) {
          if (entry.value == i) {
            colName = entry.key;
            break;
          }
        }
        if (colName != null) {
          allColsBuf.write('[$i:$colName]${tds[i]}');
        } else {
          allColsBuf.write('[$i]${tds[i]}');
        }
      }

      final product = <String, dynamic>{
        'uid': uid,
        'name': _extractFullName(colValRaw(rawTds, 'name') ?? ''),
        'barcode': colVal(tds, 'barcode') ?? '',
        'attribute4': colVal(tds, 'attribute4') ?? '', // 货号
        'extBarcode': colVal(tds, 'extBarcode') ?? '',
        'brandName': colVal(tds, 'brandName') ?? '',
        'specification': colVal(tds, 'attribute6') ?? '', // 规格
        'pinyin': colVal(tds, 'pinyin') ?? '',
        'category': colVal(tds, 'categoryName') ?? '',
        'stock': _parseNum(colVal(tds, 'stock') ?? ''),
        'unit': colVal(tds, 'baseUnitName') ?? '—',
        'sellPrice': _parseNum(colVal(tds, 'sellPrice') ?? ''),
        'buyPrice': _parseNum(colVal(tds, 'buyPrice') ?? ''),
        'wholeSalePrice': _parseNum(colVal(tds, 'wholeSalePrice') ?? ''),
        'memberPrice': _parseNum(colVal(tds, 'memberPrice') ?? ''),
        'supplier': colVal(tds, 'supplierName') ?? '',
        'createdDatetime': colVal(tds, 'createDate') ?? '',
        'imageUrl': _extractImageUrl(rowHtml),
        '_allColumns': allColsBuf.toString(),
      };

      products.add(product);
    }

    return products;
  }

  /// 解析 HTML 表头 `<thead>` 中的 `<th>` 元素，
  /// 提取 `data` 属性值作为列名，建立 列名→索引 映射。
  ///
  /// 注意：必须匹配 ALL `<th>` 元素（包括没有 data 属性的），
  /// 因为 idx 需要对应 <td> 在行中的实际位置。
  /// 例如：<th>序号</th>（无 data, idx=0）, <th>操作</th>（无 data, idx=1）,
  ///       <th data="name">商品名称</th>（idx=2）
  /// 对应的 <td> 列表：tds[0]=序号, tds[1]=操作, tds[2]=商品名称
  Map<String, int> _parseTableHeader(String html) {
    final colMap = <String, int>{};

    // 匹配 <thead> 中的 <th> 元素
    final theadMatch = RegExp(
      r'<thead[^>]*>([\s\S]*?)</thead>',
      caseSensitive: false,
    ).firstMatch(html);
    if (theadMatch == null) return colMap;

    final theadHtml = theadMatch.group(1) ?? '';

    // 匹配 ALL <th> 元素（包括没有 data 属性的），记录索引
    // 使用 <th\b 来匹配所有 <th 开头的标签
    final thRegex = RegExp(
      r'<th\b',
      caseSensitive: false,
    );
    // 同时提取 data 属性值
    final dataRegex = RegExp(
      r'data="([^"]*)"',
      caseSensitive: false,
    );

    var idx = 0;
    int searchStart = 0;
    while (true) {
      final thMatch = thRegex.firstMatch(theadHtml.substring(searchStart));
      if (thMatch == null) break;

      // 从当前 <th 开始，查找该 <th> 标签内的 data 属性
      final thTagStart = searchStart + thMatch.start;
      final thTagEnd = theadHtml.indexOf('>', thTagStart);
      if (thTagEnd == -1) break;

      final thTag = theadHtml.substring(thTagStart, thTagEnd + 1);
      final dataMatch = dataRegex.firstMatch(thTag);
      if (dataMatch != null) {
        final colName = dataMatch.group(1)?.trim();
        if (colName != null && colName.isNotEmpty) {
          colMap[colName] = idx;
        }
      }

      idx++;
      searchStart = thTagEnd + 1;
    }

    return colMap;
  }

  /// 旧版解析逻辑（固定列索引），作为表头解析失败时的回退方案
  List<Map<String, dynamic>> _parseProductTableLegacy(String html) {
    final products = <Map<String, dynamic>>[];

    final rowRegex = RegExp(
      r'<tr\s+data="(\d+)"\s+data-uid="(\d+)"[^>]*>([\s\S]*?)</tr>',
      caseSensitive: false,
    );

    for (final rowMatch in rowRegex.allMatches(html)) {
      final uid = rowMatch.group(2);
      final rowHtml = rowMatch.group(3) ?? '';

      final tdRegex = RegExp(
        r'<td[^>]*>([\s\S]*?)</td>',
        caseSensitive: false,
      );
      final rawTds = tdRegex.allMatches(rowHtml).map((m) =>
          m.group(1)?.trim() ?? '').toList();
      final tds = rawTds.map(_stripHtml).toList();

      if (tds.length < 15) continue;

      final allColsBuf = StringBuffer();
      for (var i = 0; i < tds.length; i++) {
        if (i > 0) allColsBuf.write(' | ');
        allColsBuf.write('[$i]${tds[i]}');
      }

      final product = <String, dynamic>{
        'uid': uid,
        'name': _extractFullName(_getTd(rawTds, 3)),
        'barcode': _getTd(tds, 4),
        'attribute4': _getTd(tds, 5),
        'extBarcode': _getTd(tds, 6),
        'brandName': _getTd(tds, 7),
        'specification': _getTd(tds, 8),
        'pinyin': _getTd(tds, 9),
        'category': _getTd(tds, 10),
        'stock': _parseNum(_getTd(tds, 11)),
        'unit': _getTd(tds, 12),
        'sellPrice': _parseNum(_getTd(tds, 13)),
        'sellPrice2': _parseNum(_getTd(tds, 14)),
        'customerPrice': _parseNum(_getTd(tds, 15)),
        'isCustomerDiscount': _getTd(tds, 16),
        'supplier': _getTd(tds, 17),
        'createdDatetime': _getTd(tds, 20),
        'imageUrl': _extractImageUrl(rowHtml),
        '_allColumns': allColsBuf.toString(),
      };

      products.add(product);
    }

    return products;
  }

  /// 安全获取 td 列表中的值
  String _getTd(List<String> tds, int index) {
    if (index >= tds.length) return '';
    return tds[index];
  }

  /// 去除 HTML 标签并反转义 HTML 实体，保留文本内容
  /// 名称单元格可能只显示截断文本，完整名称通常在 title / data-name 属性中。
  /// 收集所有候选（title / data-original-title / data-name / 单元格文本），取最长者。
  String _extractFullName(String rawHtml) {
    if (rawHtml.isEmpty) return '';
    // 收集所有可能的完整名称候选，最后取最长的一个：
    // 银豹名称列通常用 title / data-name 属性保存完整名称，单元格文本可能被截断。
    final candidates = <String>[];
    void addCandidate(String? s) {
      if (s == null) return;
      final t = _htmlUnescape(s.trim());
      if (t.isNotEmpty) candidates.add(t);
    }

    // 1) <a> 超链接上的 title（支持单引号/双引号）
    final aTitleM = RegExp(
      '<a[^>]*title\\s*=\\s*["\\\']([^"\\\']*)["\\\']',
      caseSensitive: false,
    ).firstMatch(rawHtml);
    addCandidate(aTitleM?.group(1));

    // 2) 任意标签上的 title / data-original-title / data-name
    for (final attr in ['title', 'data-original-title', 'data-name']) {
      final m = RegExp(
        '$attr\\s*=\\s*["\\\']([^"\\\']*)["\\\']',
        caseSensitive: false,
      ).firstMatch(rawHtml);
      addCandidate(m?.group(1));
    }

    // 3) 单元格文本
    addCandidate(_stripHtml(rawHtml));

    if (candidates.isEmpty) return '';
    candidates.sort((a, b) => b.length.compareTo(a.length));
    return candidates.first;
  }

  String _stripHtml(String html) {
    return _htmlUnescape(html)
        .replaceAll(RegExp(r'<[^>]*>'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  /// 从商品行HTML提取商品图片URL
  String? _extractImageUrl(String rowHtml) {
    final imgMatch = RegExp(r'<img[^>]+src="([^"]+)"', caseSensitive: false).firstMatch(rowHtml);
    if (imgMatch != null) {
      final src = imgMatch.group(1)!;
      if (src.startsWith('http')) return src;
      if (src.startsWith('/')) return src;
    }
    return null;
  }

  /// 解析数字（处理 "-" 和空值）
  double? _parseNum(String value) {
    if (value.isEmpty || value == '-' || value == '—') return null;
    return double.tryParse(value);
  }

  /// 读取响应体
  Future<String> _readBody(HttpClientResponse response) async {
    final bytes = <int>[];
    await for (final chunk in response) {
      bytes.addAll(chunk);
    }
    return utf8.decode(bytes);
  }

  /// 并发查询所有门店
  Future<MultiStoreResult> queryAllStores(
    List<StoreConfig> stores,
    String barcode,
  ) async {
    final startTime = DateTime.now();
    final results = <String, StoreStockResult>{};

    // 为每个门店创建独立的计时器
    final storeTimers = <String, QueryStepTimer>{};
    for (int i = 0; i < stores.length; i++) {
      storeTimers['store${i + 1}'] = QueryStepTimer(stores[i].name);
    }

    // 并发查询所有门店
    final futures = <Future<void>>[];
    for (int i = 0; i < stores.length; i++) {
      final store = stores[i];
      final key = 'store${i + 1}';
      final timer = storeTimers[key]!;
      futures.add(_querySingleStore(store, barcode, key, results, timer: timer));
    }

    await Future.wait(futures);

    final elapsed = DateTime.now().difference(startTime).inMilliseconds;
    final totalElapsedMs = elapsed;

    // 收集诊断数据（由上层 _query() 统一保存日志）
    final storeDiags = <StoreQueryDiagnostics>[];

    for (int i = 0; i < stores.length; i++) {
      final key = 'store${i + 1}';
      final storeResult = results[key];
      if (storeResult == null) continue;

      final timer = storeTimers[key]!;
      final diag = timer.done(
        success: storeResult.ok,
        error: storeResult.error,
      );
      storeDiags.add(diag);
    }

    return MultiStoreResult(
      barcode: barcode,
      stores: results,
      elapsedSeconds: totalElapsedMs / 1000.0,
      diagnostics: storeDiags,
    );
  }

  Future<void> _querySingleStore(
    StoreConfig store,
    String barcode,
    String key,
    Map<String, StoreStockResult> results, {
    QueryStepTimer? timer,
  }) async {
    try {
      final result = await queryByBarcode(store, barcode, timer: timer);
      results[key] = StoreStockResult(
        storeName: store.name,
        data: result.data,
        error: result.error,
        ok: result.ok,
      );
    } catch (e) {
      timer?.record('异常', detail: e.toString());
      results[key] = StoreStockResult(
        storeName: store.name,
        error: e.toString(),
        ok: false,
      );
    }
  }

  /// 修改商品库存
  ///
  /// 流程：搜索条码→提取 productId→FindProduct 获取完整数据→修改 stock→SaveProduct 保存
  ///
  /// 返回 null 表示成功，否则返回错误信息。
  Future<String?> updateProductStock(
    StoreConfig store,
    String barcode,
    double newStock, {
    String? productUid,
  }) async {
    final baseUrl = store.baseUrl.replaceAll(RegExp(r'/$'), '');
    final code = barcode.trim();
    if (code.isEmpty) return '条码为空';

    final cookie = await _sessionManager.getCookie(store.storeKey);
    if (cookie == null || cookie.isEmpty) return '未登录';

    try {
      // 1. 获取 userId
      final userId = await _resolveStoreUserId(store, cookie);
      if (userId == null) return '无法获取门店信息';

      // 2. 搜索条码获取 productId
      final pageData = _encodeForm({
        'userId': userId,
        'enable': '1',
        'productTagUidsJson': '[]',
        'keyword': code,
        'groupBySpu': 'false',
        'categorysJson': '[]',
        'supplierUid': '',
        'categoryType': '',
        'pageIndex': '1',
        'pageSize': '20',
        'orderColumn': '',
        'asc': 'true',
      });

      final searchUri = Uri.parse('$baseUrl/Product/LoadProductsByPage');
      final searchReq = await _httpClient.postUrl(searchUri);
      searchReq.headers.set('User-Agent', _ua);
      searchReq.headers.set('Accept', 'application/json, text/javascript, */*');
      searchReq.headers.set('Referer', '$baseUrl/Product/Manage');
      searchReq.headers.set('Origin', baseUrl);
      searchReq.headers.set('X-Requested-With', 'XMLHttpRequest');
      searchReq.headers.set('Content-Type',
          'application/x-www-form-urlencoded; charset=UTF-8');
      searchReq.headers.set('Cookie', cookie);
      searchReq.followRedirects = false;
      searchReq.write(pageData);
      final searchResp = await searchReq.close().timeout(const Duration(seconds: 15));
      final searchBody = await _readBody(searchResp);

      if (searchResp.statusCode != 200) {
        return '搜索失败 (HTTP ${searchResp.statusCode})';
      }

      Map<String, dynamic> searchData;
      try {
        searchData = jsonDecode(searchBody) as Map<String, dynamic>;
      } catch (_) {
        return '搜索返回格式异常';
      }

      final contentView = searchData['contentView'] as String? ?? '';
      // 优先按商品 uid 精准定位（同一条码多个商品时更新用户选中的那一个）
      String? productId;
      if (productUid != null && productUid.isNotEmpty) {
        final uidRowRegex = RegExp(
            r'<tr\s+data="(\d+)"\s+data-uid="(\d+)"[^>]*>');
        for (final m in uidRowRegex.allMatches(contentView)) {
          if (m.group(2) == productUid) {
            productId = m.group(1);
            break;
          }
        }
      }
      productId ??=
          RegExp(r'<tr\s+data="(\d+)"').firstMatch(contentView)?.group(1);
      if (productId == null) return '未找到该商品';

      // 3. FindProduct 获取完整数据
      final findUri = Uri.parse('$baseUrl/Product/FindProduct');
      final findReq = await _httpClient.postUrl(findUri);
      findReq.headers.set('User-Agent', _ua);
      findReq.headers.set('Accept', 'application/json, text/javascript, */*');
      findReq.headers.set('Referer', '$baseUrl/Product/Manage');
      findReq.headers.set('Origin', baseUrl);
      findReq.headers.set('X-Requested-With', 'XMLHttpRequest');
      findReq.headers.set('Content-Type',
          'application/x-www-form-urlencoded; charset=UTF-8');
      findReq.headers.set('Cookie', cookie);
      findReq.followRedirects = false;
      findReq.write('productId=$productId');
      final findResp = await findReq.close().timeout(const Duration(seconds: 15));
      final findBody = await _readBody(findResp);

      if (findResp.statusCode != 200) {
        return '获取商品数据失败 (HTTP ${findResp.statusCode})';
      }

      Map<String, dynamic> findData;
      try {
        findData = jsonDecode(findBody) as Map<String, dynamic>;
      } catch (_) {
        return '商品数据解析失败';
      }

      final product = findData['product'] as Map<String, dynamic>?;
      if (product == null) return '商品数据为空';

      // 4. 修改库存
      product['stock'] = newStock;
      product['stockQuantity'] = newStock;

      // 5. SaveProduct 保存
      final productJson = jsonEncode(product);
      final saveData = 'userId=$userId&productJson=${Uri.encodeComponent(productJson)}';

      final saveUri = Uri.parse('$baseUrl/Product/SaveProduct');
      final saveReq = await _httpClient.postUrl(saveUri);
      saveReq.headers.set('User-Agent', _ua);
      saveReq.headers.set('Accept', 'application/json, text/javascript, */*');
      saveReq.headers.set('Referer', '$baseUrl/Product/Manage');
      saveReq.headers.set('Origin', baseUrl);
      saveReq.headers.set('X-Requested-With', 'XMLHttpRequest');
      saveReq.headers.set('Content-Type',
          'application/x-www-form-urlencoded; charset=UTF-8');
      saveReq.headers.set('Cookie', cookie);
      saveReq.followRedirects = false;
      saveReq.write(saveData);
      final saveResp = await saveReq.close().timeout(const Duration(seconds: 15));
      final saveBody = await _readBody(saveResp);

      if (saveResp.statusCode != 200) {
        return '保存失败 (HTTP ${saveResp.statusCode})';
      }

      try {
        final saveResult = jsonDecode(saveBody) as Map<String, dynamic>;
        if (saveResult['successed'] == true) {
          return null; // 成功
        }
        return saveResult['msg'] as String? ?? '保存失败';
      } catch (_) {
        return '保存响应异常';
      }
    } catch (e) {
      return '${store.name} 修改库存异常：${e.toString()}';
    }
  }

  /// 修改商品供货商（与修改库存同一流程：搜索→FindProduct→改字段→SaveProduct）
  /// 新供货商设为商品默认供货商（替换原绑定列表）
  ///
  /// 返回 null 表示成功，否则返回错误信息。
  Future<String?> updateProductSupplier(
    StoreConfig store,
    String barcode,
    String newSupplierName, {
    String? productUid,
  }) async {
    final baseUrl = store.baseUrl.replaceAll(RegExp(r'/$'), '');
    final code = barcode.trim();
    if (code.isEmpty) return '条码为空';

    final cookie = await _sessionManager.getCookie(store.storeKey);
    if (cookie == null || cookie.isEmpty) return '未登录';

    try {
      // 1. 获取 userId
      final userId = await _resolveStoreUserId(store, cookie);
      if (userId == null) return '无法获取门店信息';

      // 2. 获取供货商 uid 映射（缓存优先 → 未命中实时拉取并自动重试 1 次）
      final cachedUidMap = _supplierUidCache[store.storeKey] ??
          await _loadSupplierUidCache(store.storeKey);
      if (cachedUidMap.isNotEmpty) {
        _supplierUidCache[store.storeKey] = cachedUidMap;
      }
      String? newSupplierUid;
      if (cachedUidMap.isNotEmpty) {
        newSupplierUid = _matchSupplierUid(newSupplierName, cachedUidMap);
      }
      if (newSupplierUid == null) {
        // 缓存未命中：实时拉取，失败自动重试 1 次
        Map<String, String> uidMap = const {};
        String errorDiag = '无法获取银豹供货商列表';
        for (var attempt = 0; attempt < 2; attempt++) {
          final fetched = await _fetchSupplierUidMap(baseUrl, cookie, userId);
          if (fetched.uidMap.isNotEmpty) {
            uidMap = fetched.uidMap;
            _supplierUidCache[store.storeKey] = uidMap;
            await _saveSupplierUidCache(store.storeKey, uidMap);
            break;
          }
          errorDiag = '无法获取银豹供货商列表（${fetched.error}）';
        }
        if (uidMap.isEmpty) {
          return errorDiag;
        }
        newSupplierUid = _matchSupplierUid(newSupplierName, uidMap);
        if (newSupplierUid == null) {
          final sample = uidMap.keys.take(8).join('、');
          return '银豹供货商列表中未找到「$newSupplierName」（当前共 ${uidMap.length} 个：$sample…）';
        }
      }

      // 3. 搜索条码获取 productId
      final pageData = _encodeForm({
        'userId': userId,
        'enable': '1',
        'productTagUidsJson': '[]',
        'keyword': code,
        'groupBySpu': 'false',
        'categorysJson': '[]',
        'supplierUid': '',
        'categoryType': '',
        'pageIndex': '1',
        'pageSize': '20',
        'orderColumn': '',
        'asc': 'true',
      });

      final searchUri = Uri.parse('$baseUrl/Product/LoadProductsByPage');
      final searchReq = await _httpClient.postUrl(searchUri);
      searchReq.headers.set('User-Agent', _ua);
      searchReq.headers.set('Accept', 'application/json, text/javascript, */*');
      searchReq.headers.set('Referer', '$baseUrl/Product/Manage');
      searchReq.headers.set('Origin', baseUrl);
      searchReq.headers.set('X-Requested-With', 'XMLHttpRequest');
      searchReq.headers.set('Content-Type',
          'application/x-www-form-urlencoded; charset=UTF-8');
      searchReq.headers.set('Cookie', cookie);
      searchReq.followRedirects = false;
      searchReq.write(pageData);
      final searchResp = await searchReq.close().timeout(const Duration(seconds: 15));
      final searchBody = await _readBody(searchResp);

      if (searchResp.statusCode != 200) {
        return '搜索失败 (HTTP ${searchResp.statusCode})';
      }

      Map<String, dynamic> searchData;
      try {
        searchData = jsonDecode(searchBody) as Map<String, dynamic>;
      } catch (_) {
        return '搜索返回格式异常';
      }

      final contentView = searchData['contentView'] as String? ?? '';
      // 优先按商品 uid 精准定位（同一条码多个商品时更新用户选中的那一个）
      String? productId;
      if (productUid != null && productUid.isNotEmpty) {
        final uidRowRegex = RegExp(
            r'<tr\s+data="(\d+)"\s+data-uid="(\d+)"[^>]*>');
        for (final m in uidRowRegex.allMatches(contentView)) {
          if (m.group(2) == productUid) {
            productId = m.group(1);
            break;
          }
        }
      }
      productId ??=
          RegExp(r'<tr\s+data="(\d+)"').firstMatch(contentView)?.group(1);
      if (productId == null) return '未找到该商品';


      // 4. FindProduct 获取完整数据
      final findUri = Uri.parse('$baseUrl/Product/FindProduct');
      final findReq = await _httpClient.postUrl(findUri);
      findReq.headers.set('User-Agent', _ua);
      findReq.headers.set('Accept', 'application/json, text/javascript, */*');
      findReq.headers.set('Referer', '$baseUrl/Product/Manage');
      findReq.headers.set('Origin', baseUrl);
      findReq.headers.set('X-Requested-With', 'XMLHttpRequest');
      findReq.headers.set('Content-Type',
          'application/x-www-form-urlencoded; charset=UTF-8');
      findReq.headers.set('Cookie', cookie);
      findReq.followRedirects = false;
      findReq.write('productId=$productId');
      final findResp = await findReq.close().timeout(const Duration(seconds: 15));
      final findBody = await _readBody(findResp);

      if (findResp.statusCode != 200) {
        return '获取商品数据失败 (HTTP ${findResp.statusCode})';
      }

      Map<String, dynamic> findData;
      try {
        findData = jsonDecode(findBody) as Map<String, dynamic>;
      } catch (_) {
        return '商品数据解析失败';
      }

      final product = findData['product'] as Map<String, dynamic>?;
      if (product == null) return '商品数据为空';

      // 5. 修改供货商字段（新供货商设为默认，替换原绑定列表）
      product['supplierUid'] = newSupplierUid;
      product['supplierName'] = newSupplierName;
      product['supplierRangeList'] = [
        {
          'supplierUid': newSupplierUid,
          'supplierName': newSupplierName,
          'isDefault': '1',
        },
      ];

      // 6. SaveProduct 保存
      final productJson = jsonEncode(product);
      final saveData = 'userId=$userId&productJson=${Uri.encodeComponent(productJson)}';

      final saveUri = Uri.parse('$baseUrl/Product/SaveProduct');
      final saveReq = await _httpClient.postUrl(saveUri);
      saveReq.headers.set('User-Agent', _ua);
      saveReq.headers.set('Accept', 'application/json, text/javascript, */*');
      saveReq.headers.set('Referer', '$baseUrl/Product/Manage');
      saveReq.headers.set('Origin', baseUrl);
      saveReq.headers.set('X-Requested-With', 'XMLHttpRequest');
      saveReq.headers.set('Content-Type',
          'application/x-www-form-urlencoded; charset=UTF-8');
      saveReq.headers.set('Cookie', cookie);
      saveReq.followRedirects = false;
      saveReq.write(saveData);
      final saveResp = await saveReq.close().timeout(const Duration(seconds: 15));
      final saveBody = await _readBody(saveResp);

      if (saveResp.statusCode != 200) {
        return '保存失败 (HTTP ${saveResp.statusCode})';
      }

      try {
        final saveResult = jsonDecode(saveBody) as Map<String, dynamic>;
        if (saveResult['successed'] == true) {
          return null; // 成功
        }
        return saveResult['msg'] as String? ?? '保存失败';
      } catch (_) {
        return '保存响应异常';
      }
    } catch (e) {
      return '${store.name} 修改供货商异常：${e.toString()}';
    }
  }

  /// 修改商品名称（与修改库存同一流程：搜索→FindProduct→改字段→SaveProduct）
  ///
  /// 返回 null 表示成功，否则返回错误信息。
  Future<String?> updateProductName(
    StoreConfig store,
    String barcode,
    String newName, {
    String? productUid,
  }) async {
    final baseUrl = store.baseUrl.replaceAll(RegExp(r'/$'), '');
    final code = barcode.trim();
    if (code.isEmpty) return '条码为空';
    final newNameTrim = newName.trim();
    if (newNameTrim.isEmpty) return '商品名称不能为空';

    final cookie = await _sessionManager.getCookie(store.storeKey);
    if (cookie == null || cookie.isEmpty) return '未登录';

    try {
      // 1. 获取 userId
      final userId = await _resolveStoreUserId(store, cookie);
      if (userId == null) return '无法获取门店信息';

      // 2. 搜索条码获取 productId
      final pageData = _encodeForm({
        'userId': userId,
        'enable': '1',
        'productTagUidsJson': '[]',
        'keyword': code,
        'groupBySpu': 'false',
        'categorysJson': '[]',
        'supplierUid': '',
        'categoryType': '',
        'pageIndex': '1',
        'pageSize': '20',
        'orderColumn': '',
        'asc': 'true',
      });

      final searchUri = Uri.parse('$baseUrl/Product/LoadProductsByPage');
      final searchReq = await _httpClient.postUrl(searchUri);
      searchReq.headers.set('User-Agent', _ua);
      searchReq.headers.set('Accept', 'application/json, text/javascript, */*');
      searchReq.headers.set('Referer', '$baseUrl/Product/Manage');
      searchReq.headers.set('Origin', baseUrl);
      searchReq.headers.set('X-Requested-With', 'XMLHttpRequest');
      searchReq.headers.set('Content-Type',
          'application/x-www-form-urlencoded; charset=UTF-8');
      searchReq.headers.set('Cookie', cookie);
      searchReq.followRedirects = false;
      searchReq.write(pageData);
      final searchResp = await searchReq.close().timeout(const Duration(seconds: 15));
      final searchBody = await _readBody(searchResp);

      if (searchResp.statusCode != 200) {
        return '搜索失败 (HTTP ${searchResp.statusCode})';
      }

      Map<String, dynamic> searchData;
      try {
        searchData = jsonDecode(searchBody) as Map<String, dynamic>;
      } catch (_) {
        return '搜索返回格式异常';
      }

      final contentView = searchData['contentView'] as String? ?? '';
      // 优先按商品 uid 精准定位（同一条码多个商品时更新用户选中的那一个）
      String? productId;
      if (productUid != null && productUid.isNotEmpty) {
        final uidRowRegex = RegExp(
            r'<tr\s+data="(\d+)"\s+data-uid="(\d+)"[^>]*>');
        for (final m in uidRowRegex.allMatches(contentView)) {
          if (m.group(2) == productUid) {
            productId = m.group(1);
            break;
          }
        }
      }
      productId ??=
          RegExp(r'<tr\s+data="(\d+)"').firstMatch(contentView)?.group(1);
      if (productId == null) return '未找到该商品';

      // 3. FindProduct 获取完整数据
      final findUri = Uri.parse('$baseUrl/Product/FindProduct');
      final findReq = await _httpClient.postUrl(findUri);
      findReq.headers.set('User-Agent', _ua);
      findReq.headers.set('Accept', 'application/json, text/javascript, */*');
      findReq.headers.set('Referer', '$baseUrl/Product/Manage');
      findReq.headers.set('Origin', baseUrl);
      findReq.headers.set('X-Requested-With', 'XMLHttpRequest');
      findReq.headers.set('Content-Type',
          'application/x-www-form-urlencoded; charset=UTF-8');
      findReq.headers.set('Cookie', cookie);
      findReq.followRedirects = false;
      findReq.write('productId=$productId');
      final findResp = await findReq.close().timeout(const Duration(seconds: 15));
      final findBody = await _readBody(findResp);

      if (findResp.statusCode != 200) {
        return '获取商品数据失败 (HTTP ${findResp.statusCode})';
      }

      Map<String, dynamic> findData;
      try {
        findData = jsonDecode(findBody) as Map<String, dynamic>;
      } catch (_) {
        return '商品数据解析失败';
      }

      final product = findData['product'] as Map<String, dynamic>?;
      if (product == null) return '商品数据为空';

      // 4. 修改名称字段
      product['name'] = newNameTrim;
      if (product.containsKey('productName')) {
        product['productName'] = newNameTrim;
      }

      // 5. SaveProduct 保存
      final productJson = jsonEncode(product);
      final saveData = 'userId=$userId&productJson=${Uri.encodeComponent(productJson)}';

      final saveUri = Uri.parse('$baseUrl/Product/SaveProduct');
      final saveReq = await _httpClient.postUrl(saveUri);
      saveReq.headers.set('User-Agent', _ua);
      saveReq.headers.set('Accept', 'application/json, text/javascript, */*');
      saveReq.headers.set('Referer', '$baseUrl/Product/Manage');
      saveReq.headers.set('Origin', baseUrl);
      saveReq.headers.set('X-Requested-With', 'XMLHttpRequest');
      saveReq.headers.set('Content-Type',
          'application/x-www-form-urlencoded; charset=UTF-8');
      saveReq.headers.set('Cookie', cookie);
      saveReq.followRedirects = false;
      saveReq.write(saveData);
      final saveResp = await saveReq.close().timeout(const Duration(seconds: 15));
      final saveBody = await _readBody(saveResp);

      if (saveResp.statusCode != 200) {
        return '保存失败 (HTTP ${saveResp.statusCode})';
      }

      try {
        final saveResult = jsonDecode(saveBody) as Map<String, dynamic>;
        if (saveResult['successed'] == true) {
          return null; // 成功
        }
        return saveResult['msg'] as String? ?? '保存失败';
      } catch (_) {
        return '保存响应异常';
      }
    } catch (e) {
      return '${store.name} 修改名称异常：${e.toString()}';
    }
  }
  /// 更新商品操作记录，统一写入商品描述（description）：
  /// 更新照片 / 更新库存 / 更新供货商 三行，各类型更新时只替换对应行，保持三行。
  /// 返回 null 表示成功，否则返回错误信息。
  Future<String?> updateProductOperationNote(
    StoreConfig store,
    String barcode,
    String operatorName,
    String actionLabel, {
    String? productUid,
  }) async {
    final baseUrl = store.baseUrl.replaceAll(RegExp(r'/$'), '');
    final code = barcode.trim();
    if (code.isEmpty) return '条码为空';

    final cookie = await _sessionManager.getCookie(store.storeKey);
    if (cookie == null || cookie.isEmpty) return '未登录';

    try {
      // 1. 获取 userId
      final userId = await _resolveStoreUserId(store, cookie);
      if (userId == null) return '无法获取门店信息';

      // 2. 搜索条码获取 productId
      final pageData = _encodeForm({
        'userId': userId,
        'enable': '1',
        'productTagUidsJson': '[]',
        'keyword': code,
        'groupBySpu': 'false',
        'categorysJson': '[]',
        'supplierUid': '',
        'categoryType': '',
        'pageIndex': '1',
        'pageSize': '20',
        'orderColumn': '',
        'asc': 'true',
      });

      final searchUri = Uri.parse('$baseUrl/Product/LoadProductsByPage');
      final searchReq = await _httpClient.postUrl(searchUri);
      searchReq.headers.set('User-Agent', _ua);
      searchReq.headers.set('Accept', 'application/json, text/javascript, */*');
      searchReq.headers.set('Referer', '$baseUrl/Product/Manage');
      searchReq.headers.set('Origin', baseUrl);
      searchReq.headers.set('X-Requested-With', 'XMLHttpRequest');
      searchReq.headers.set('Content-Type',
          'application/x-www-form-urlencoded; charset=UTF-8');
      searchReq.headers.set('Cookie', cookie);
      searchReq.followRedirects = false;
      searchReq.write(pageData);
      final searchResp = await searchReq.close().timeout(const Duration(seconds: 15));
      final searchBody = await _readBody(searchResp);

      if (searchResp.statusCode != 200) {
        return '搜索失败 (HTTP ${searchResp.statusCode})';
      }

      Map<String, dynamic> searchData;
      try {
        searchData = jsonDecode(searchBody) as Map<String, dynamic>;
      } catch (_) {
        return '搜索返回格式异常';
      }

      final contentView = searchData['contentView'] as String? ?? '';
      // 优先按商品 uid 精准定位（同一条码多个商品时更新用户选中的那一个）
      String? productId;
      if (productUid != null && productUid.isNotEmpty) {
        final uidRowRegex = RegExp(
            r'<tr\s+data="(\d+)"\s+data-uid="(\d+)"[^>]*>');
        for (final m in uidRowRegex.allMatches(contentView)) {
          if (m.group(2) == productUid) {
            productId = m.group(1);
            break;
          }
        }
      }
      productId ??=
          RegExp(r'<tr\s+data="(\d+)"').firstMatch(contentView)?.group(1);
      if (productId == null) return '未找到该商品';

      // 3. FindProduct 获取完整数据
      final findUri = Uri.parse('$baseUrl/Product/FindProduct');
      final findReq = await _httpClient.postUrl(findUri);
      findReq.headers.set('User-Agent', _ua);
      findReq.headers.set('Accept', 'application/json, text/javascript, */*');
      findReq.headers.set('Referer', '$baseUrl/Product/Manage');
      findReq.headers.set('Origin', baseUrl);
      findReq.headers.set('X-Requested-With', 'XMLHttpRequest');
      findReq.headers.set('Content-Type',
          'application/x-www-form-urlencoded; charset=UTF-8');
      findReq.headers.set('Cookie', cookie);
      findReq.followRedirects = false;
      findReq.write('productId=$productId');
      final findResp = await findReq.close().timeout(const Duration(seconds: 15));
      final findBody = await _readBody(findResp);

      if (findResp.statusCode != 200) {
        return '获取商品数据失败 (HTTP ${findResp.statusCode})';
      }

      Map<String, dynamic> findData;
      try {
        findData = jsonDecode(findBody) as Map<String, dynamic>;
      } catch (_) {
        return '商品数据解析失败';
      }

      final product = findData['product'] as Map<String, dynamic>?;
      if (product == null) return '商品数据为空';

      // 4. 合并记录：统一写入商品描述，同类型记录替换一行，无则追加，保持三行
      const fieldName = 'description';
      final now = DateTime.now();
      final dateStr =
          '${now.year}.${now.month.toString().padLeft(2, '0')}.${now.day.toString().padLeft(2, '0')}';
      final newLine = '$dateStr $operatorName：$actionLabel';
      final lines = ((product[fieldName] as String?) ?? '')
          .split('\n')
          .map((l) => l.trimRight())
          .toList();
      // 库存兼容旧行「修改商品库存」：任一写法命中都替换为「更新库存」
      final idx = actionLabel == '更新库存'
          ? lines.indexWhere(
              (l) => l.contains('更新库存') || l.contains('修改商品库存'))
          : lines.indexWhere((l) => l.contains(actionLabel));
      if (idx >= 0) {
        lines[idx] = newLine;
      } else {
        lines.add(newLine);
      }
      product[fieldName] =
          lines.where((l) => l.trim().isNotEmpty).join('\n');

      // 5. SaveProduct 保存
      final productJson = jsonEncode(product);
      final saveData = 'userId=$userId&productJson=${Uri.encodeComponent(productJson)}';

      final saveUri = Uri.parse('$baseUrl/Product/SaveProduct');
      final saveReq = await _httpClient.postUrl(saveUri);
      saveReq.headers.set('User-Agent', _ua);
      saveReq.headers.set('Accept', 'application/json, text/javascript, */*');
      saveReq.headers.set('Referer', '$baseUrl/Product/Manage');
      saveReq.headers.set('Origin', baseUrl);
      saveReq.headers.set('X-Requested-With', 'XMLHttpRequest');
      saveReq.headers.set('Content-Type',
          'application/x-www-form-urlencoded; charset=UTF-8');
      saveReq.headers.set('Cookie', cookie);
      saveReq.followRedirects = false;
      saveReq.write(saveData);
      final saveResp = await saveReq.close().timeout(const Duration(seconds: 15));
      final saveBody = await _readBody(saveResp);

      if (saveResp.statusCode != 200) {
        return '保存失败 (HTTP ${saveResp.statusCode})';
      }

      try {
        final saveResult = jsonDecode(saveBody) as Map<String, dynamic>;
        if (saveResult['successed'] == true) {
          return null; // 成功
        }
        return saveResult['msg'] as String? ?? '保存失败';
      } catch (_) {
        return '保存响应异常';
      }
    } catch (e) {
      return '${store.name} 更新描述异常：${e.toString()}';
    }
  }

  // ==================== 供货商 UID 缓存（静默获取） ====================

  Future<Map<String, String>> _loadSupplierUidCache(String storeKey) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('$_supplierUidCachePrefix$storeKey');
      if (raw == null || raw.isEmpty) return const {};
      final data = jsonDecode(raw) as Map<String, dynamic>;
      return data.map((k, v) => MapEntry(k, v.toString()));
    } catch (_) {
      return const {};
    }
  }

  Future<void> _saveSupplierUidCache(
      String storeKey, Map<String, String> uidMap) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          '$_supplierUidCachePrefix$storeKey', jsonEncode(uidMap));
    } catch (_) {
      // 缓存失败不影响功能
    }
  }

  /// 静默刷新某门店供货商 UID 映射并缓存（失败静默忽略，供补货同步供货商使用）
  Future<void> silentRefreshSupplierUid(StoreConfig store) async {
    try {
      final baseUrl = store.baseUrl.replaceAll(RegExp(r'/$'), '');
      final cookie = await _sessionManager.getCookie(store.storeKey);
      if (cookie == null || cookie.isEmpty) return;
      final userId = await _resolveStoreUserId(store, cookie);
      if (userId == null) return;
      final fetched = await _fetchSupplierUidMap(baseUrl, cookie, userId);
      if (fetched.uidMap.isEmpty) return;
      _supplierUidCache[store.storeKey] = fetched.uidMap;
      await _saveSupplierUidCache(store.storeKey, fetched.uidMap);
    } catch (_) {
      // 静默忽略
    }
  }

  /// 从银豹获取供货商名称→uid 映射
  /// 首选 LoadSuppliers 全量列表（含未授权供货商）；失败回退 LoadSupplierDDLJson
  /// 返回 (uidMap, error)：uidMap 非空即成功，error 为失败诊断信息
  Future<({Map<String, String> uidMap, String error})> _fetchSupplierUidMap(
    String baseUrl,
    String cookie,
    String userId,
  ) async {
    // 首选 LoadSuppliers 全量列表（与登录自动获取一致，含未授权供货商）；
    // LoadSupplierDDLJson 只返回「已授权」下拉项，会漏掉未授权供货商（如 E115）
    final primary = await _loadSupplierUidsFromView(baseUrl, cookie, userId);
    if (primary.uidMap.isNotEmpty) return primary;

    String diag = 'LoadSuppliers：${primary.error}';
    try {
      final req = await _httpClient
          .postUrl(Uri.parse('$baseUrl/Supplier/LoadSupplierDDLJson'));
      req.headers.set('User-Agent', _ua);
      req.headers.set('Accept', 'application/json, text/javascript, */*');
      req.headers.set('Referer', '$baseUrl/Product/Manage');
      req.headers.set('Origin', baseUrl);
      req.headers.set('X-Requested-With', 'XMLHttpRequest');
      req.headers.set('Content-Type',
          'application/x-www-form-urlencoded; charset=UTF-8');
      req.headers.set('Cookie', cookie);
      req.followRedirects = false;
      req.write(_encodeForm({'userId': userId, 'withNumber': 'true'}));
      final resp = await req.close().timeout(const Duration(seconds: 15));
      if (resp.statusCode != 200) {
        diag = '$diag；LoadSupplierDDLJson HTTP ${resp.statusCode}';
      } else {
        final body = await _readBody(resp);
        final data = jsonDecode(body) as Map<String, dynamic>?;
        if (data == null) {
          diag = '$diag；LoadSupplierDDLJson 响应非 JSON';
        } else {
          final result = <String, String>{};
          // 优先解析 suppliersJson（纯名称列表）
          final suppliersJson = data['suppliersJson'];
          if (suppliersJson is String && suppliersJson.isNotEmpty) {
            try {
              final list = jsonDecode(suppliersJson) as List<dynamic>;
              for (final item in list) {
                if (item is Map<String, dynamic>) {
                  final name = (item['name'] ?? item['originalName'])?.toString();
                  final uid = (item['uid'] ?? item['value'])?.toString();
                  if (name != null && name.isNotEmpty && uid != null && uid.isNotEmpty) {
                    result[name] = uid;
                  }
                }
              }
            } catch (_) {}
          }
          // 回退解析 supplierDDL（text/value）
          if (result.isEmpty) {
            final ddl = data['supplierDDL'];
            if (ddl is List) {
              for (final item in ddl) {
                if (item is Map<String, dynamic>) {
                  final text = item['text']?.toString();
                  final value = item['value']?.toString();
                  if (text != null && value != null && value.isNotEmpty) {
                    result[_htmlUnescape(text)] = value;
                  }
                }
              }
            }
          }
          if (result.isNotEmpty) {
            return (uidMap: result, error: '');
          }
          diag = '$diag；LoadSupplierDDLJson 未解析到供货商';
        }
      }
    } catch (e) {
      diag = '$diag；LoadSupplierDDLJson 异常：$e';
    }
    return (uidMap: const <String, String>{}, error: diag);
  }

  /// 调用 LoadSuppliers 接口解析 data-name / data-uid 映射（全量，含未授权供货商）
  /// 注意：必须传 supplierEnable=1，否则接口返回 HTTP 500
  Future<({Map<String, String> uidMap, String error})> _loadSupplierUidsFromView(
    String baseUrl,
    String cookie,
    String userId,
  ) async {
    try {
      final req = await _httpClient.postUrl(Uri.parse('$baseUrl/Supplier/LoadSuppliers'));
      req.headers.set('User-Agent', _ua);
      req.headers.set('Accept', 'application/json, text/javascript, */*; q=0.01');
      req.headers.set('Referer', '$baseUrl/Supplier/Manage');
      req.headers.set('Origin', baseUrl);
      req.headers.set('X-Requested-With', 'XMLHttpRequest');
      req.headers.set('Content-Type', 'application/x-www-form-urlencoded; charset=UTF-8');
      req.headers.set('Cookie', cookie);
      req.followRedirects = false;
      req.write(_encodeForm({
        'supplierEnable': '1',
        'businessMode': '',
        'keyword': '',
        'userId': userId,
      }));
      final resp = await req.close().timeout(const Duration(seconds: 15));
      if (resp.statusCode != 200) {
        return (uidMap: const <String, String>{}, error: 'LoadSuppliers HTTP ${resp.statusCode}');
      }
      final body = await _readBody(resp);
      final Object? decoded;
      try {
        decoded = jsonDecode(body);
      } catch (_) {
        return (uidMap: const <String, String>{}, error: 'LoadSuppliers 响应非 JSON');
      }
      final data = decoded as Map<String, dynamic>?;
      final view = data?['view'] as String? ?? '';
      if (view.isEmpty) {
        return (uidMap: const <String, String>{}, error: 'LoadSuppliers view 为空');
      }
      final result = <String, String>{};
      // 逐行提取 data-name / data-uid（不依赖属性先后顺序）
      final trRegex = RegExp(r'<tr[^>]*>', caseSensitive: false);
      final nameAttr = RegExp(r'data-name="([^"]+)"', caseSensitive: false);
      final uidAttr = RegExp(r'data-uid="(\d+)"', caseSensitive: false);
      for (final tr in trRegex.allMatches(view)) {
        final tag = tr.group(0)!;
        final nameM = nameAttr.firstMatch(tag);
        final uidM = uidAttr.firstMatch(tag);
        if (nameM == null || uidM == null) continue;
        final name = nameM.group(1)!.trim();
        final uid = uidM.group(1)!;
        if (name.isNotEmpty && uid.isNotEmpty) {
          result[_htmlUnescape(name)] = uid;
        }
      }
      if (result.isEmpty) {
        return (uidMap: const <String, String>{}, error: 'LoadSuppliers 表格未解析到 data-name/data-uid');
      }
      return (uidMap: result, error: '');
    } catch (e) {
      return (uidMap: const <String, String>{}, error: 'LoadSuppliers 异常：$e');
    }
  }

  /// 供货商名称匹配：精确 → 规范化（忽略 &、空格、大小写）→ 词边界包含
  static String? _matchSupplierUid(String name, Map<String, String> uidMap) {
    final exact = uidMap[name];
    if (exact != null) return exact;
    final normalized = _normSupplierName(name);
    for (final entry in uidMap.entries) {
      if (_normSupplierName(entry.key) == normalized) {
        return entry.value;
      }
    }
    // 词边界包含匹配（如 "E115 - 某某"）
    if (normalized.length < 2) return null;
    final boundary = RegExp(r'[a-z0-9]');
    for (final entry in uidMap.entries) {
      final key = _normSupplierName(entry.key);
      final idx = key.indexOf(normalized);
      if (idx == -1) continue;
      final before = idx > 0 ? key.substring(idx - 1, idx) : '';
      final afterIdx = idx + normalized.length;
      final after = afterIdx < key.length ? key.substring(afterIdx, afterIdx + 1) : '';
      final boundaryOk = (before.isEmpty || !boundary.hasMatch(before)) &&
          (after.isEmpty || !boundary.hasMatch(after));
      if (boundaryOk && key.length - normalized.length <= 20) {
        return entry.value;
      }
    }
    return null;
  }

  /// 供货商名称规范化（用于容错匹配）
  static String _normSupplierName(String s) => s
      .replaceAll('&', '')
      .replaceAll(' ', '')
      .replaceAll('\u3000', '')
      .toLowerCase();

  /// 反转义常见 HTML 实体（供货商下拉文本、商品名称等）
  static String _htmlUnescape(String input) {
    return input
        .replaceAll('&amp;', '&')
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAllMapped(RegExp(r'&#x([0-9a-fA-F]+);'), (m) {
          final cp = int.parse(m.group(1)!, radix: 16);
          return String.fromCharCodes([cp]);
        })
        .replaceAllMapped(RegExp(r'&#(\d+);'), (m) {
          final cp = int.parse(m.group(1)!);
          return String.fromCharCodes([cp]);
        });
  }

/// 上传商品图片到银豹（独立接口 /Product/UploadProductImage，与修改库存不同）
/// 流程：搜索条码获取 productId → multipart 上传图片
/// 返回 (error, imageUrl)：error 为 null 表示成功，imageUrl 为完整可显示的图片地址
  Future<(String?, String?)> updateProductImage(
    StoreConfig store,
    String barcode,
    List<int> imageBytes,
    String imageName,
  ) async {
    final baseUrl = store.baseUrl.replaceAll(RegExp(r'/$'), '');
    final code = barcode.trim();
    if (code.isEmpty) return ('条码为空', null);

    final cookie = await _sessionManager.getCookie(store.storeKey);
    if (cookie == null || cookie.isEmpty) return ('未登录', null);

    try {
      // 1. 获取 userId
      final userId = await _resolveStoreUserId(store, cookie);
      if (userId == null) return ('无法获取门店信息', null);

      // 2. 搜索条码获取 productId
      final pageData = _encodeForm({
        'userId': userId,
        'enable': '1',
        'productTagUidsJson': '[]',
        'keyword': code,
        'groupBySpu': 'false',
        'categorysJson': '[]',
        'supplierUid': '',
        'categoryType': '',
        'pageIndex': '1',
        'pageSize': '20',
        'orderColumn': '',
        'asc': 'true',
      });

      final searchUri = Uri.parse('$baseUrl/Product/LoadProductsByPage');
      final searchReq = await _httpClient.postUrl(searchUri);
      searchReq.headers.set('User-Agent', _ua);
      searchReq.headers.set('Accept', 'application/json, text/javascript, */*');
      searchReq.headers.set('Referer', '$baseUrl/Product/Manage');
      searchReq.headers.set('Origin', baseUrl);
      searchReq.headers.set('X-Requested-With', 'XMLHttpRequest');
      searchReq.headers.set('Content-Type',
          'application/x-www-form-urlencoded; charset=UTF-8');
      searchReq.headers.set('Cookie', cookie);
      searchReq.followRedirects = false;
      searchReq.write(pageData);
      final searchResp = await searchReq.close().timeout(const Duration(seconds: 15));
      final searchBody = await _readBody(searchResp);

      if (searchResp.statusCode != 200) {
        return ('搜索失败 (HTTP ${searchResp.statusCode})', null);
      }

      Map<String, dynamic> searchData;
      try {
        searchData = jsonDecode(searchBody) as Map<String, dynamic>;
      } catch (_) {
        return ('搜索返回格式异常', null);
      }

      final contentView = searchData['contentView'] as String? ?? '';
      final productIdMatch = RegExp(r'<tr\s+data="(\d+)"').firstMatch(contentView);
      if (productIdMatch == null) return ('未找到该商品', null);

      final productId = productIdMatch.group(1)!;

      // 3. 上传图片到银豹\uff08独立上传接口\uff0c不需要 SaveProduct）
      final uploadUri = Uri.parse(
          '$baseUrl/Product/UploadProductImage?userId=$userId&productId=$productId&forMulColorSize=false');
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 15);
      final request = await client.postUrl(uploadUri);
      final boundary = '----ImgBoundary${DateTime.now().millisecondsSinceEpoch}';
      request.headers.set('User-Agent', _ua);
      request.headers.set('Accept', 'application/json, text/javascript, */*');
      request.headers.set('Referer', '$baseUrl/Product/Manage');
      request.headers.set('Origin', baseUrl);
      request.headers.set('X-Requested-With', 'XMLHttpRequest');
      request.headers.contentType = ContentType(
        'multipart',
        'form-data',
        parameters: {'boundary': boundary},
      );
      request.headers.set('Cookie', cookie);
      request.followRedirects = false;

      final body = <int>[];
      body.addAll(utf8.encode('--$boundary\r\n'));
      body.addAll(utf8.encode(
          'Content-Disposition: form-data; name="file"; filename="$imageName"\r\n'));
      body.addAll(utf8.encode('Content-Type: image/jpeg\r\n\r\n'));
      body.addAll(imageBytes);
      body.addAll(utf8.encode('\r\n--$boundary--\r\n'));
      request.add(body);
      final resp = await request.close().timeout(const Duration(seconds: 60));
      final respBody = await _readBody(resp);

      if (resp.statusCode != 200) {
        return ('上传失败 (HTTP ${resp.statusCode})', null);
      }

      Map<String, dynamic> result;
      try {
        result = jsonDecode(respBody) as Map<String, dynamic>;
      } catch (_) {
        return ('上传响应解析失败：$respBody', null);
      }
      if (result['successed'] != true) {
        return ('上传失败：$respBody', null);
      }
      final msg = result['msg']?.toString() ?? '';
      if (msg.isEmpty) return ('上传失败：未返回图片路径', null);
      final path = msg.startsWith('/') ? msg : '/$msg';
      final imageUrl = '$_imageDomain$path';
      return (null, imageUrl);
    } catch (e) {
      return ('上传图片异常：${e.toString()}', null);
    }
  }

  /// 替换商品图片：先删除银豹商品全部旧图，再上传新图
  /// 银豹支持一商品多张图片，仅上传新图不会优先显示，需先删除旧图再上传替换
  /// 返回 (error, imageUrl)：error 为 null 表示成功，imageUrl 为完整可显示的图片地址
  Future<(String?, String?)> replaceProductImage(
    StoreConfig store,
    String barcode,
    List<int> imageBytes,
    String imageName, {
    String? productUid,
  }) async {
    final baseUrl = store.baseUrl.replaceAll(RegExp(r'/$'), '');
    final code = barcode.trim();
    if (code.isEmpty) return ('条码为空', null);

    final cookie = await _sessionManager.getCookie(store.storeKey);
    if (cookie == null || cookie.isEmpty) return ('未登录', null);

    try {
      // 1. 获取 userId
      final userId = await _resolveStoreUserId(store, cookie);
      if (userId == null) return ('无法获取门店信息', null);

      // 2. 搜索条码获取 productId
      final pageData = _encodeForm({
        'userId': userId,
        'enable': '1',
        'productTagUidsJson': '[]',
        'keyword': code,
        'groupBySpu': 'false',
        'categorysJson': '[]',
        'supplierUid': '',
        'categoryType': '',
        'pageIndex': '1',
        'pageSize': '20',
        'orderColumn': '',
        'asc': 'true',
      });

      final searchUri = Uri.parse('$baseUrl/Product/LoadProductsByPage');
      final searchReq = await _httpClient.postUrl(searchUri);
      searchReq.headers.set('User-Agent', _ua);
      searchReq.headers.set('Accept', 'application/json, text/javascript, */*');
      searchReq.headers.set('Referer', '$baseUrl/Product/Manage');
      searchReq.headers.set('Origin', baseUrl);
      searchReq.headers.set('X-Requested-With', 'XMLHttpRequest');
      searchReq.headers.set('Content-Type',
          'application/x-www-form-urlencoded; charset=UTF-8');
      searchReq.headers.set('Cookie', cookie);
      searchReq.followRedirects = false;
      searchReq.write(pageData);
      final searchResp = await searchReq.close().timeout(const Duration(seconds: 15));
      final searchBody = await _readBody(searchResp);

      if (searchResp.statusCode != 200) {
        return ('搜索失败 (HTTP ${searchResp.statusCode})', null);
      }

      Map<String, dynamic> searchData;
      try {
        searchData = jsonDecode(searchBody) as Map<String, dynamic>;
      } catch (_) {
        return ('搜索返回格式异常', null);
      }

      final contentView = searchData['contentView'] as String? ?? '';
      // 优先按商品 uid 精准定位（同一条码多个商品时更新用户选中的那一个）
      String? productId;
      if (productUid != null && productUid.isNotEmpty) {
        final uidRowRegex = RegExp(
            r'<tr\s+data="(\d+)"\s+data-uid="(\d+)"[^>]*>');
        for (final m in uidRowRegex.allMatches(contentView)) {
          if (m.group(2) == productUid) {
            productId = m.group(1);
            break;
          }
        }
      }
      productId ??=
          RegExp(r'<tr\s+data="(\d+)"').firstMatch(contentView)?.group(1);
      if (productId == null) return ('未找到该商品', null);

      // 3. FindProduct 获取商品旧图片列表（productimages[].id）
      final findUri = Uri.parse('$baseUrl/Product/FindProduct');
      final findReq = await _httpClient.postUrl(findUri);
      findReq.headers.set('User-Agent', _ua);
      findReq.headers.set('Accept', 'application/json, text/javascript, */*');
      findReq.headers.set('Referer', '$baseUrl/Product/Manage');
      findReq.headers.set('Origin', baseUrl);
      findReq.headers.set('X-Requested-With', 'XMLHttpRequest');
      findReq.headers.set('Content-Type',
          'application/x-www-form-urlencoded; charset=UTF-8');
      findReq.headers.set('Cookie', cookie);
      findReq.followRedirects = false;
      findReq.write('productId=$productId');
      final findResp = await findReq.close().timeout(const Duration(seconds: 15));
      final findBody = await _readBody(findResp);

      if (findResp.statusCode != 200) {
        return ('获取商品数据失败 (HTTP ${findResp.statusCode})', null);
      }

      Map<String, dynamic> findData;
      try {
        findData = jsonDecode(findBody) as Map<String, dynamic>;
      } catch (_) {
        return ('商品数据解析失败', null);
      }
      final product = findData['product'] as Map<String, dynamic>?;
      final oldImages = (product?['productimages'] as List?) ?? const <dynamic>[];

      // 4. 删除全部旧图（任一张删除失败则中止，保证替换一致性）
      for (final item in oldImages) {
        if (item is! Map<String, dynamic>) continue;
        final imgId = item['id']?.toString() ?? '';
        if (imgId.isEmpty || imgId == '0') continue;
        final delUri = Uri.parse('$baseUrl/Product/DeleteProductImage');
        final delReq = await _httpClient.postUrl(delUri);
        delReq.headers.set('User-Agent', _ua);
        delReq.headers.set('Accept', 'application/json, text/javascript, */*');
        delReq.headers.set('Referer', '$baseUrl/Product/Manage');
        delReq.headers.set('Origin', baseUrl);
        delReq.headers.set('X-Requested-With', 'XMLHttpRequest');
        delReq.headers.set('Content-Type',
            'application/x-www-form-urlencoded; charset=UTF-8');
        delReq.headers.set('Cookie', cookie);
        delReq.followRedirects = false;
        delReq.write(_encodeForm({
          'productImageId': imgId,
          'forMulColorSize': 'false',
        }));
        final delResp = await delReq.close().timeout(const Duration(seconds: 15));
        if (delResp.statusCode != 200) {
          return ('删除旧图失败 (HTTP ${delResp.statusCode})', null);
        }
        final delBody = await _readBody(delResp);
        try {
          final delResult = jsonDecode(delBody) as Map<String, dynamic>;
          if (delResult['successed'] == false) {
            return ('删除旧图失败：${delResult['msg'] ?? ''}', null);
          }
        } catch (_) {
          // 响应非 JSON 时按成功处理
        }
      }

      // 5. 上传新图（独立上传接口，不需要 SaveProduct）
      final uploadUri = Uri.parse(
          '$baseUrl/Product/UploadProductImage?userId=$userId&productId=$productId&forMulColorSize=false');
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 15);
      final request = await client.postUrl(uploadUri);
      final boundary = '----ImgBoundary${DateTime.now().millisecondsSinceEpoch}';
      request.headers.set('User-Agent', _ua);
      request.headers.set('Accept', 'application/json, text/javascript, */*');
      request.headers.set('Referer', '$baseUrl/Product/Manage');
      request.headers.set('Origin', baseUrl);
      request.headers.set('X-Requested-With', 'XMLHttpRequest');
      request.headers.contentType = ContentType(
        'multipart',
        'form-data',
        parameters: {'boundary': boundary},
      );
      request.headers.set('Cookie', cookie);
      request.followRedirects = false;

      final body = <int>[];
      body.addAll(utf8.encode('--$boundary\r\n'));
      body.addAll(utf8.encode(
          'Content-Disposition: form-data; name="file"; filename="$imageName"\r\n'));
      body.addAll(utf8.encode('Content-Type: image/jpeg\r\n\r\n'));
      body.addAll(imageBytes);
      body.addAll(utf8.encode('\r\n--$boundary--\r\n'));
      request.add(body);
      final resp = await request.close().timeout(const Duration(seconds: 60));
      final respBody = await _readBody(resp);

      if (resp.statusCode != 200) {
        return ('上传失败 (HTTP ${resp.statusCode})', null);
      }

      Map<String, dynamic> result;
      try {
        result = jsonDecode(respBody) as Map<String, dynamic>;
      } catch (_) {
        return ('上传响应解析失败：$respBody', null);
      }
      if (result['successed'] != true) {
        return ('上传失败：$respBody', null);
      }
      final msg = result['msg']?.toString() ?? '';
      if (msg.isEmpty) return ('上传失败：未返回图片路径', null);
      final path = msg.startsWith('/') ? msg : '/$msg';
      final imageUrl = '$_imageDomain$path';
      return (null, imageUrl);
    } catch (e) {
      return ('替换图片异常：${e.toString()}', null);
    }
  }

// 银豹 CDN 图片域名（后台 #imageDomain）
  static const String _imageDomain = 'https://img.pospal.cn/';

  String _encodeForm(Map<String, String> data) {
    return data.entries
        .map((e) =>
            '${Uri.encodeComponent(e.key)}=${Uri.encodeComponent(e.value)}')
        .join('&');
  }
}
