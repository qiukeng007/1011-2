import 'dart:convert';
import 'dart:io';
import '../models/store_config.dart';
import '../models/product_result.dart';
import '../models/query_log.dart';
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

  QueryService(this._sessionManager) {
    _httpClient = HttpClient();
    _httpClient.autoUncompress = true;
    _httpClient.connectionTimeout = const Duration(seconds: 15);
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
      return const ProductResult(ok: false, error: '未登录，请先工号登录');
    }

    try {
      // Step 1: 获取 userId（优先从缓存读取，避免每次查询都 GET /Product/Manage）
      final userId = await _getUserId(baseUrl, store.storeKey, cookie, timer: timer);
      if (userId == null) {
        timer?.record('获取userId', detail: '失败');
        return ProductResult(
          ok: false,
          error: '${store.name} 无法获取门店信息，请重新登录',
        );
      }

      // Step 2: 调用 LoadProductsByPage 搜索条码
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
            error: '${store.name} 登录已失效，请重新工号登录',
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

      // 查找匹配条码的商品
      final matched = products.where((p) =>
          p['barcode'] == code || p['barcode']?.trim() == code).toList();

      Map<String, dynamic>? hit;

      if (matched.isNotEmpty) {
        hit = matched.first;
      } else if (products.length == 1) {
        // 无精确匹配但仅一个商品 → 扩展码对应不同主条码
        hit = products.first;
      } else if (products.isEmpty) {
        return ProductResult(ok: false, error: '未找到该条码商品');
      } else {
        return ProductResult(ok: false, error: '条码不精确，匹配到${products.length}个商品');
      }

      final allCols = hit['_allColumns'] as String?;

      final product = ProductData(
        barcode: hit['barcode'] ?? code,
        name: hit['name'] ?? '',
        specification: hit['specification'] ?? '',
        category: hit['category'] ?? '',
        stock: hit['stock'],
        unit: hit['unit'] ?? '—',
        supplier: hit['supplier'] ?? '',
        sellPrice: hit['sellPrice'],
        buyPrice: hit['buyPrice'],
        uid: hit['uid'],
        multipleMatches: matched.length > 1 ? matched.length : null,
        allColumns: allCols,
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

      // 检查是否跳转到登录页
      if (response.headers.value('location') != null &&
          RegExp(r'signin|login', caseSensitive: false).hasMatch(response.headers.value('location')!)) {
        return false; // Cookie 已过期
      }

      // 刷新 userId 缓存
      final userId = _extractUserIdFromBody(body);
      if (userId != null) {
        await _sessionManager.saveUserId(store.storeKey, userId);
      }
      return true;
    } catch (_) {
      return true; // 网络异常不判定过期，保留现有 Cookie
    }
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

    // Step 2: 匹配每个商品行 <tr data="..." data-uid="...">
    final rowRegex = RegExp(
      r'<tr\s+data="(\d+)"\s+data-uid="(\d+)"[^>]*>([\s\S]*?)</tr>',
      caseSensitive: false,
    );

    for (final rowMatch in rowRegex.allMatches(html)) {
      final uid = rowMatch.group(2);
      final rowHtml = rowMatch.group(3) ?? '';

      // 提取所有 <td> 内容
      final tdRegex = RegExp(
        r'<td[^>]*>([\s\S]*?)</td>',
        caseSensitive: false,
      );
      final tds = tdRegex.allMatches(rowHtml).map((m) =>
          _stripHtml(m.group(1)?.trim() ?? '')).toList();

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
        'name': colVal(tds, 'name') ?? '',
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
      final tds = tdRegex.allMatches(rowHtml).map((m) =>
          _stripHtml(m.group(1)?.trim() ?? '')).toList();

      if (tds.length < 15) continue;

      final allColsBuf = StringBuffer();
      for (var i = 0; i < tds.length; i++) {
        if (i > 0) allColsBuf.write(' | ');
        allColsBuf.write('[$i]${tds[i]}');
      }

      final product = <String, dynamic>{
        'uid': uid,
        'name': _getTd(tds, 3),
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

  /// 去除 HTML 标签，保留文本内容
  String _stripHtml(String html) {
    return html
        .replaceAll(RegExp(r'<[^>]*>'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
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
    double newStock,
  ) async {
    final baseUrl = store.baseUrl.replaceAll(RegExp(r'/$'), '');
    final code = barcode.trim();
    if (code.isEmpty) return '条码为空';

    final cookie = await _sessionManager.getCookie(store.storeKey);
    if (cookie == null || cookie.isEmpty) return '未登录';

    try {
      // 1. 获取 userId
      final userId = await _getUserId(baseUrl, store.storeKey, cookie);
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
      final productIdMatch = RegExp(r'<tr\s+data="(\d+)"').firstMatch(contentView);
      if (productIdMatch == null) return '未找到该商品';

      final productId = productIdMatch.group(1)!;

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

  /// URL 编码表单数据
  String _encodeForm(Map<String, String> data) {
    return data.entries
        .map((e) =>
            '${Uri.encodeComponent(e.key)}=${Uri.encodeComponent(e.value)}')
        .join('&');
  }
}
