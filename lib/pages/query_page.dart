import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/store_config.dart';
import '../models/product_result.dart';
import '../models/restock_prefill_data.dart';
import '../services/login_service.dart';
import '../services/query_service.dart';
import '../services/session_manager.dart';
import '../services/query_logger.dart';
import '../services/operation_log_service.dart';
import '../models/query_log.dart';
import '../widgets/barcode_icon.dart';
import '../widgets/printer_widgets.dart';
import '../widgets/transfer_store_card.dart';
import '../models/printer_config.dart';
import '../services/print_service.dart';
import '../widgets/scanner_view.dart';
import '../widgets/store_card.dart';
import '../utils/constants.dart';

/// 数字转中文大写（一二三.五格式）
String _numberToChinese(double value) {
  const digits = ['零', '一', '二', '三', '四', '五', '六', '七', '八', '九'];
  final parts = value.toStringAsFixed(2).split('.');
  final intPart = parts[0];
  final decPart = parts[1];

  final buffer = StringBuffer();
  for (var i = 0; i < intPart.length; i++) {
    buffer.write(digits[intPart.codeUnitAt(i) - 0x30]);
  }
  buffer.write('.');
  for (var i = 0; i < decPart.length; i++) {
    buffer.write(digits[decPart.codeUnitAt(i) - 0x30]);
  }
  return buffer.toString();
}

/// 查询页面（条码输入 + 结果展示 + 登录状态）
class QueryPage extends StatefulWidget {
  final List<StoreConfig> configs;
  final List<PrinterConfig> printerConfigs;
  final QueryService queryService;
  final SessionManager sessionManager;
  final LoginService loginService;
  final void Function(RestockPrefillData data)? onNavigateToRestock;
  final Set<String> verifiedKeys;
  final bool verifying;

  const QueryPage({
    super.key,
    required this.configs,
    this.printerConfigs = const [],
    required this.queryService,
    required this.sessionManager,
    required this.loginService,
    this.onNavigateToRestock,
    this.verifiedKeys = const {},
    this.verifying = false,
  });

  @override
  State<QueryPage> createState() => _QueryPageState();
}

class _QueryPageState extends State<QueryPage> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  final TextEditingController _barcodeController = TextEditingController();
  final FocusNode _barcodeFocus = FocusNode();
  final ScrollController _scrollController = ScrollController();
  bool _querying = false;
  String? _error;
  MultiStoreResult? _lastResult;
  // 调货状态
  int _transferQty = 0;
  String? _transferTarget;
  String? _transferSource;

  // 顶部通知横幅
  String? _bannerMsg;
  bool _bannerError = false;
  Timer? _bannerTimer;

  void _showBanner(String msg, {bool isError = false}) {
    _bannerTimer?.cancel();
    setState(() { _bannerMsg = msg; _bannerError = isError; });
    _bannerTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _bannerMsg = null);
    });
  }

  @override
  void initState() {
    super.initState();
    _checkLoginStatuses();
    _startKeepAlive();
  }

  void _startKeepAlive() {
    _keepAliveTimer?.cancel();
    _keepAliveTimer = Timer.periodic(const Duration(minutes: 3), (_) {
      _doKeepAlive();
    });
  }

  /// 重置保活计时器（每次扫码或保活重登后调用，避免空闲时重复请求）
  void _restartKeepAliveTimer() {
    if (!mounted) return;
    _keepAliveTimer?.cancel();
    _keepAliveTimer = Timer.periodic(const Duration(minutes: 3), (_) {
      _doKeepAlive();
    });
  }

  Future<void> _doKeepAlive() async {
    final expiredConfigs = <StoreConfig>[];
    for (final config in widget.configs) {
      final valid = await widget.queryService.keepAlive(config);
      if (!valid) expiredConfigs.add(config);
    }
    if (expiredConfigs.isNotEmpty) {
      final names = expiredConfigs.map((c) => c.name).join('、');
      _showBanner('保活: $names 已过期，正在重新登录…');
      // 并发重登所有过期门店
      final results = await Future.wait(
        expiredConfigs.map((c) => widget.loginService.login(c).then((_) => null).catchError((e) => e.toString()))
      );
      final fails = results.whereType<String>().toList();
      if (mounted) {
        _checkLoginStatuses();
        if (fails.isEmpty) {
          _showBanner('保活: ${expiredConfigs.length} 个门店已重新连接 ✓');
        } else {
          _showBanner('保活: ${fails.length} 个门店重连失败', isError: true);
        }
      }
    }
    _restartKeepAliveTimer();
  }

  bool _hasIp(String id) => widget.printerConfigs.any((p) => p.id == id && p.ip.isNotEmpty);

  // 实时计时器
  DateTime? _queryStartTime;
  String _elapsedText = '';
  bool _timerRunning = false;

  // 登录状态
  Map<String, bool> _loginStatuses = {};

  // 保活定时器：每 5 分钟静默刷新 session，防止掉线
  Timer? _keepAliveTimer;

  @override
  void didUpdateWidget(QueryPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.configs != widget.configs || oldWidget.verifiedKeys != widget.verifiedKeys) {
      _checkLoginStatuses();
    }
  }

  @override
  void dispose() {
    _timerRunning = false;
    _keepAliveTimer?.cancel();
    _bannerTimer?.cancel();
    _barcodeController.dispose();
    _barcodeFocus.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _checkLoginStatuses() async {
    // 仅本地缓存快速检查，不发起 HTTP 请求
    // HTTP Cookie 验证开销大（每个门店一次 GET），改为在搜索时按需处理过期
    final statuses = <String, bool>{};
    for (final config in widget.configs) {
      if (widget.verifiedKeys.contains(config.storeKey)) {
        statuses[config.storeKey] = true;
      } else {
        final cookie = await widget.sessionManager.getCookie(config.storeKey);
        statuses[config.storeKey] = cookie != null;
      }
    }
    if (mounted) setState(() => _loginStatuses = statuses);
  }

  Future<void> _query(String barcode) async {
    if (barcode.trim().isEmpty) return;
    _barcodeFocus.unfocus(); // 收起键盘
    _cancelTransfer(); // 新搜索清空调货状态

    setState(() {
      _querying = true;
      _error = null;
      _lastResult = null;
      _queryStartTime = DateTime.now();
      _elapsedText = '';
    });

    _timerRunning = true;
    _startElapsedTimer();

    // 收集所有诊断数据（含重登）
    final allDiags = <StoreQueryDiagnostics>[];
    bool reLoginHappened = false;
    int reLoginMs = 0;

    try {
      var result = await widget.queryService.queryAllStores(
        widget.configs,
        barcode.trim(),
      );
      if (result.diagnostics != null) {
        allDiags.addAll(result.diagnostics!);
      }

      // 检测是否需要自动重新登录（并发）
      if (mounted) {
        final needRelogin = result.stores.values.where((s) =>
            s.error != null &&
            (s.error!.contains('登录') || s.error!.contains('门店信息')));
        if (needRelogin.isNotEmpty) {
          reLoginHappened = true;
          final reloginStart = DateTime.now();
          // 只重登真正过期的门店（storeName → StoreConfig）
          final nameToConfig = <String, StoreConfig>{};
          for (final c in widget.configs) { nameToConfig[c.name] = c; }
          final expiredConfigs = needRelogin
              .map((s) => nameToConfig[s.storeName])
              .whereType<StoreConfig>()
              .toList();
          final reloginNames = expiredConfigs.map((c) => c.name).join('、');
          setState(() => _elapsedText = '正在重新登录…');
          _showBanner('$reloginNames 登录过期，正在重新登录…');

          // 仅重登过期的门店
          await Future.wait(
            expiredConfigs.map((c) => widget.loginService.login(c).catchError((_) {}))
          );

          reLoginMs = DateTime.now().difference(reloginStart).inMilliseconds;

          // 重新查询
          if (mounted) {
            setState(() => _elapsedText = '重新查询中…');
            _showBanner('重新登录完成，继续查询…');
            result = await widget.queryService.queryAllStores(
              widget.configs,
              barcode.trim(),
            );
            if (result.diagnostics != null) {
              allDiags.addAll(result.diagnostics!);
            }
          }
        }
      }

      if (mounted) {
        _timerRunning = false;
        // 用 _queryStartTime 算真实总耗时，不是最后一次 queryAllStores 的内部耗时
        final trueTotalMs = DateTime.now().difference(_queryStartTime!).inMilliseconds;
        setState(() {
          _lastResult = result;
          _querying = false;
          _elapsedText = '查询耗时：${(trueTotalMs / 1000).toStringAsFixed(2)} 秒';
        });

        // 保存合并后的诊断日志（包含重登耗时）
        String? slowestStore;
        int slowestMs = 0;
        for (final d in allDiags) {
          if (d.totalMs > slowestMs) {
            slowestMs = d.totalMs;
            slowestStore = d.storeName;
          }
        }
        final logEntry = QueryLogEntry(
          timestamp: _queryStartTime!,
          barcode: barcode.trim(),
          storeCount: widget.configs.length,
          stores: allDiags,
          totalElapsedMs: trueTotalMs,
          reLoginTriggered: reLoginHappened,
          reLoginMs: reLoginHappened ? reLoginMs : null,
          slowestStore: slowestStore,
          slowestStoreMs: slowestMs > 0 ? slowestMs : null,
        );
        QueryLogger().add(logEntry);

        // 记录操作日志
        final storeNames = _lastResult!.stores.values.map((s) => s.storeName).join('、');
        OperationLogService.add(
          store: storeNames,
          action: '多店查询',
          barcode: barcode.trim(),
          detail: _elapsedText,
        );

        _restartKeepAliveTimer();
        _checkLoginStatuses();
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_scrollController.hasClients) {
            _scrollController.animateTo(0,
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeOut);
          }
        });
      }
    } catch (e) {
      if (mounted) {
        _timerRunning = false;
        setState(() {
          _error = '查询失败：$e';
          _elapsedText = '';
          _querying = false;
        });
      }
    }
  }

  /// 实时计时器：每100ms更新一次已用时间
  void _startElapsedTimer() async {
    while (_timerRunning && mounted) {
      await Future.delayed(const Duration(milliseconds: 100));
      if (!_timerRunning || !mounted) break;
      if (_queryStartTime == null) break;
      final elapsed = DateTime.now().difference(_queryStartTime!);
      final secs = elapsed.inMilliseconds / 1000.0;
      if (mounted) {
        setState(() {
          _elapsedText = '查询中… ${secs.toStringAsFixed(1)} 秒';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Stack(
      children: [
        SingleChildScrollView(
          controller: _scrollController,
          padding: const EdgeInsets.all(12),
          child: Column(
            children: [
              // ===== 查询结果区（最上面） =====
              if (_lastResult != null)
            _buildResultSection(_lastResult!)
          else
            _buildEmptyResultPlaceholder(),

          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: _buildErrorCard(_error!),
            ),

          // ===== 条码输入 + 扫码（下方） =====
          const SizedBox(height: 8),
          _buildSearchCard(),

          // ===== 登录状态（底部） =====
          const SizedBox(height: 8),
          _buildSessionSection(),
        ],
      ),
    ),
    // 顶部通知横幅
    if (_bannerMsg != null)
      Positioned(
        top: 0, left: 0, right: 0,
        child: _buildBanner(),
      ),
  ],
);
  }

  Widget _buildBanner() {
    return Material(
      color: _bannerError ? Colors.red : AppConstants.successColor,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              Icon(
                _bannerError ? Icons.error_outline : Icons.check_circle,
                size: 16, color: Colors.white,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _bannerMsg ?? '',
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyResultPlaceholder() {
    return Column(
      children: [
        // 商品信息占位
        Card(
          elevation: 1,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppConstants.radiusMd)),
          child: const Padding(
            padding: EdgeInsets.all(20),
            child: Center(
              child: Text('输入条码查询商品信息', style: TextStyle(fontSize: 14, color: AppConstants.textSecondary)),
            ),
          ),
        ),
        const SizedBox(height: 8),
        // 库存占位
        Card(
          elevation: 1,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppConstants.radiusMd)),
          child: const Padding(
            padding: EdgeInsets.all(20),
            child: Center(
              child: Text('门店库存将显示在这里', style: TextStyle(fontSize: 14, color: AppConstants.textSecondary)),
            ),
          ),
        ),
      ],
    );
  }

  // ==================== 结果区 ====================

  Widget _buildResultSection(MultiStoreResult r) {
    // 找到第一个有数据的门店
    final firstData = r.stores.values
        .where((s) => s.ok && s.data != null && s.data!.name.isNotEmpty)
        .firstOrNull
        ?.data;

    // 按 store1, store2, store3 固定顺序排列门店库存
    final sortedStoreKeys = ['store1', 'store2', 'store3']
        .where((k) => r.stores.containsKey(k))
        .toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 商品信息
        if (firstData != null) _buildProductInfo(firstData, r.barcode),

        // 多条结果提示
        if (firstData?.multipleMatches != null && firstData!.multipleMatches! > 1)
          _buildMultipleHint(firstData.multipleMatches!),

        // 标题 + 方向提示同行
        const SizedBox(height: 12),
        Row(
          children: [
            const Text(
              '门店库存',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
            if (_transferQty != 0) ...[
              const Spacer(),
              _hintDot(Colors.green),
              const SizedBox(width: 2),
              const Text('增加', style: TextStyle(fontSize: 10, color: AppConstants.textSecondary)),
              const SizedBox(width: 8),
              _hintDot(Colors.red),
              const SizedBox(width: 2),
              const Text('调出', style: TextStyle(fontSize: 10, color: AppConstants.textSecondary)),
            ],
          ],
        ),
        const SizedBox(height: 6),
        // 卡片行（自适应宽度，填满屏幕）
        Row(
          children: _buildStoreCardsWithArrows(sortedStoreKeys, r),
        ),
        // 确认调货栏
        if (_transferQty != 0) ...[
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _cancelTransfer,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppConstants.textSecondary,
                    side: const BorderSide(color: AppConstants.textSecondary),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppConstants.radiusSm)),
                    padding: const EdgeInsets.symmetric(vertical: 10),
                  ),
                  child: const Text('取消'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 2,
                child: ElevatedButton(
                  onPressed: _confirmTransfer,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppConstants.primaryColor,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppConstants.radiusSm)),
                    padding: const EdgeInsets.symmetric(vertical: 10),
                  ),
                  child: _querying
                      ? const Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)),
                            SizedBox(width: 8),
                            Text('提交中…', style: TextStyle(fontSize: 13)),
                          ],
                        )
                      : Text('提交 ${_confirmBtnText()}', style: const TextStyle(fontSize: 13)),
                ),
              ),
            ],
          ),
        ],

        // 补货 + 打印按钮
        const SizedBox(height: 10),
        SizedBox(width: double.infinity, child: _actionBtn('补货', Icons.add_shopping_cart, AppConstants.primaryColor, () => _handleRestock(r))),
        const SizedBox(height: 6),
        Row(children: [
          if (_hasIp('p1')) Expanded(child: _actionBtn('大价签80', Icons.print, const Color(0xFFFF9800), () => _handleDirectPrint(r, 'p1'))),
          if (_hasIp('p1') && _hasIp('p2')) const SizedBox(width: 6),
          if (_hasIp('p2')) Expanded(child: _actionBtn('中价签双列', Icons.print, const Color(0xFF00897B), () => _handleDirectPrint(r, 'p2'))),
        ]),
        if (_hasIp('p3') || _hasIp('p4')) const SizedBox(height: 6),
        Row(children: [
          if (_hasIp('p3')) Expanded(child: _actionBtn('中价签单列', Icons.print, const Color(0xFF00897B), () => _handleDirectPrint(r, 'p3'))),
          if (_hasIp('p3') && _hasIp('p4')) const SizedBox(width: 6),
          if (_hasIp('p4')) Expanded(child: _actionBtn('小价签', Icons.print, Colors.grey, () => _handleDirectPrint(r, 'p4'))),
        ]),
        // 调试面板
        if (firstData?.rawKeys != null)
          _buildDebugPanel(firstData!),

        // 全部未找到提示
        if (r.stores.values.every((s) => !s.ok || s.data?.name.isEmpty == true))
          _buildNotFoundHint(),

        const SizedBox(height: 16),
      ],
    );
  }

  Widget _buildProductInfo(ProductData data, String barcode) {
    return Card(
      elevation: 1,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppConstants.radiusMd),
      ),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 商品名称（带#时过滤显示货号在下方）
            _buildProductName(data.name),
            const SizedBox(height: 6),
            // 信息行
            _buildInfoRow(Icons.view_week, '条码', data.barcode.isNotEmpty ? data.barcode : barcode),
            if (data.supplier.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Row(
                  children: [
                    const Icon(Icons.business, size: 14, color: Color(0xFF28a745)),
                    const SizedBox(width: 6),
                    const Text('供货商：', style: TextStyle(fontSize: 13, color: AppConstants.textSecondary)),
                    Expanded(
                      child: Text(
                        data.supplier,
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Color(0xFF28a745)),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            _buildInfoRow(Icons.scale, '单位', data.unit),
            // 进价 + 售价同行
            if (data.buyPrice != null || data.sellPrice != null)
              _buildPriceRow(data.buyPrice, data.sellPrice),
          ],
        ),
      ),
    );
  }

  final Map<String, String> _transCache = {};

  Widget _buildProductName(String name) {
    if (name.isEmpty) {
      return const Text('(未命名商品)',
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold));
    }

    // 过滤#货号
    final parts = name.split('#');
    final productName = parts[0].trim();
    final articleNo = parts.length > 1 ? parts.sublist(1).map((s) => s.trim()).where((s) => s.isNotEmpty).join(' #') : '';

    // 触发翻译（仅英文名）
    final needTrans = _needsTranslation(productName);
    if (needTrans && !_transCache.containsKey(productName)) {
      _translate(productName);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          productName.isNotEmpty ? productName : '(未命名商品)',
          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
        ),
        // 翻译结果
        if (needTrans && _transCache.containsKey(productName))
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              _transCache[productName]!,
              style: const TextStyle(fontSize: 14, color: Color(0xFFE65100), fontWeight: FontWeight.w500),
            ),
          ),
        // 货号
        if (articleNo.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              '#$articleNo',
              style: const TextStyle(fontSize: 12, color: Colors.red, fontWeight: FontWeight.w600),
            ),
          ),
      ],
    );
  }

  bool _needsTranslation(String text) {
    if (text.isEmpty) return false;
    // 包含中文字符的不需要翻译
    if (RegExp(r'[一-鿿]').hasMatch(text)) return false;
    // 只有数字/符号的不翻译
    if (!RegExp(r'[A-Za-z]{3,}').hasMatch(text)) return false;
    return true;
  }

  Future<void> _translate(String text) async {
    try {
      final httpClient = HttpClient();
      httpClient.connectionTimeout = const Duration(seconds: 5);
      String? result = await _tryGoogleTranslate(httpClient, text);

      // 翻不出来 → 去掉#货号和数字，只留英文再试
      if (result == null || result.isEmpty || result.toLowerCase() == text.toLowerCase()) {
        String clean = text
            .replaceAll(RegExp(r'\S*#\S*'), ' ')
            .replaceAll(RegExp(r'\b\d+\b'), ' ')
            .replaceAll(RegExp(r'[^a-zA-Z\s]'), ' ')
            .trim();
        if (clean.length > 2 && !clean.toLowerCase().contains(text.toLowerCase())) {
          result = await _tryGoogleTranslate(httpClient, clean);
        }
      }

      httpClient.close();

      if (result != null && result.isNotEmpty && result.toLowerCase() != text.toLowerCase()) {
        _transCache[text] = result;
        if (mounted) setState(() {});
      }
    } catch (_) {}
  }

  Future<String?> _tryGoogleTranslate(HttpClient httpClient, String text) async {
    try {
      final url = 'https://translate.googleapis.com/translate_a/single?client=gtx&sl=en&tl=zh-CN&dt=t&q=${Uri.encodeComponent(text)}';
      final req = await httpClient.getUrl(Uri.parse(url));
      req.headers.set('User-Agent', 'Mozilla/5.0');
      final resp = await req.close().timeout(const Duration(seconds: 5));
      if (resp.statusCode == 200) {
        final body = await resp.transform(utf8.decoder).join();
        final json = jsonDecode(body) as List<dynamic>;
        if (json.isNotEmpty && json[0] is List && (json[0] as List).isNotEmpty) {
          final first = (json[0] as List)[0];
          if (first is List && first.isNotEmpty) {
            return first[0].toString();
          }
        }
      }
    } catch (_) {}
    return null;
  }

  Widget _buildInfoRow(IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        children: [
          Icon(icon, size: 14, color: AppConstants.textSecondary),
          const SizedBox(width: 6),
          Text(
            '$label：',
            style: const TextStyle(
              fontSize: 13,
              color: AppConstants.textSecondary,
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontSize: 13),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  /// 进价 + 售价同行
  Widget _buildPriceRow(double? buyPrice, double? sellPrice) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        children: [
          if (buyPrice != null) ...[
            const Icon(Icons.shopping_cart, size: 14, color: AppConstants.textSecondary),
            const SizedBox(width: 4),
            const Text('进价：', style: TextStyle(fontSize: 12, color: AppConstants.textSecondary)),
            Text(
              'R${_numberToChinese(buyPrice)}',
              style: const TextStyle(fontSize: 12, color: Color(0xFF8B4513)),
            ),
            const SizedBox(width: 12),
          ],
          if (sellPrice != null) ...[
            const Icon(Icons.monetization_on, size: 14, color: Colors.red),
            const SizedBox(width: 4),
            const Text('售价：', style: TextStyle(fontSize: 12, color: AppConstants.textSecondary)),
            Text(
              'R${sellPrice.toStringAsFixed(2)}',
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.red),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildMultipleHint(int count) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Card(
        color: AppConstants.warningColor.withValues(alpha: 0.1),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            children: [
              const Icon(Icons.warning_amber, color: AppConstants.warningColor, size: 18),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '查询到 $count 条匹配结果，当前显示第一条',
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppConstants.warningColor,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildNotFoundHint() {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Card(
        color: AppConstants.warningColor.withValues(alpha: 0.08),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              const Icon(Icons.info_outline, color: AppConstants.textSecondary, size: 18),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  '未找到该条码商品，或当前工号无商品查看权限',
                  style: TextStyle(
                    fontSize: 13,
                    color: AppConstants.textSecondary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDebugPanel(ProductData data) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Card(
        elevation: 0,
        color: AppConstants.bgColor,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppConstants.radiusSm),
          side: BorderSide(color: AppConstants.dividerColor),
        ),
        child: ExpansionTile(
          title: Text(
            '🔍 原始数据字段 (${data.rawKeys?.split(',').length ?? 0}个)',
            style: const TextStyle(fontSize: 12, color: AppConstants.textSecondary),
          ),
          dense: true,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    data.rawKeys ?? '',
                    style: const TextStyle(
                      fontSize: 10,
                      fontFamily: 'monospace',
                      color: AppConstants.textSecondary,
                    ),
                  ),
                  if (data.numericFields != null && data.numericFields!.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      '数字字段: ${data.numericFields}',
                      style: const TextStyle(
                        fontSize: 10,
                        fontFamily: 'monospace',
                        color: AppConstants.textSecondary,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ==================== 补货对话框 ====================

  Widget _actionBtn(String label, IconData icon, Color color, VoidCallback onTap) {
    return SizedBox(
      height: 36,
      child: ElevatedButton.icon(
        onPressed: onTap,
        icon: Icon(icon, size: 16),
        label: Text(label, style: const TextStyle(fontSize: 12)),
        style: ElevatedButton.styleFrom(backgroundColor: color, foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppConstants.radiusSm)),
            padding: const EdgeInsets.symmetric(horizontal: 10)),
      ),
    );
  }

  Future<void> _handleDirectPrint(MultiStoreResult r, String printerId) async {
    final firstData = r.stores.values.where((s) => s.ok && s.data != null).firstOrNull?.data;
    if (firstData == null) return;

    // 用缓存的打印机配置，不重复读磁盘
    final printer = widget.printerConfigs.where((p) => p.id == printerId).firstOrNull;
    if (printer == null || printer.ip.isEmpty) {
      _showBanner('请先在配置页设置打印机IP', isError: true);
      return;
    }
    final pcAddr = '${printer.ip}:18888';
    final barcode = firstData.barcode.isNotEmpty ? firstData.barcode : r.barcode;
    final json = jsonEncode({
      'barcode': barcode, 'name': firstData.name,
      'price': firstData.sellPrice?.toStringAsFixed(2) ?? '',
      'supplier': firstData.supplier, 'unit': firstData.unit,
      'templateId': printerId,
      'showPrice': printerId == 'p1' ? '1' : '0',
      'qty': '1',
    });

    if (printerId == 'p1') {
      // 大价签直接发
      final err = await _postJson(pcAddr, json);
      if (mounted) _showBanner(err ?? '已发送到电脑 ✓', isError: err != null);
    } else {
      showDialog(context: context, builder: (_) => _PcPrintDialog(
        json: json, pcAddr: pcAddr,
        onResult: (err) {
          if (mounted) _showBanner(err ?? '已发送到电脑 ✓', isError: err != null);
        },
      ));
    }
  }

  Future<String?> _postJson(String addr, String json) async {
    try {
      final parts = addr.split(':');
      final ip = parts[0];
      final port = int.tryParse(parts.length > 1 ? parts[1] : '18888') ?? 18888;
      final body = utf8.encode(json);
      // 头+体一次性合并，避免拆包
      final all = utf8.encode(
          'POST / HTTP/1.1\r\n'
          'Host: $addr\r\n'
          'Content-Type: application/json\r\n'
          'Content-Length: ${body.length}\r\n'
          'Connection: close\r\n'
          '\r\n') + body;
      final socket = await Socket.connect(ip, port, timeout: const Duration(seconds: 5));
      socket.add(all);
      await socket.flush();
      await socket.close();
      return null;
    } catch (e) {
      return '连接失败: $e';
    }
  }

  void _handleRestock(MultiStoreResult r) {
    final firstData = r.stores.values
        .where((s) => s.ok && s.data != null)
        .firstOrNull
        ?.data;
    final barcode = (firstData?.barcode.isNotEmpty == true)
        ? firstData!.barcode
        : r.barcode;
    if (mounted && widget.onNavigateToRestock != null) {
      widget.onNavigateToRestock!(RestockPrefillData(
        barcode: barcode,
        supplier: firstData?.supplier ?? '',
        productName: firstData?.name ?? '',
        specification: firstData?.specification ?? '',
        buyPrice: firstData?.buyPrice,
        sellPrice: firstData?.sellPrice,
      ));
    }
  }

  // ==================== 搜索卡片 ====================

  Widget _buildSearchCard() {
    return Card(
      elevation: 1,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppConstants.radiusMd),
      ),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text(
                  '商品条码',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                if (!_querying && _elapsedText.isNotEmpty)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.timer_outlined, size: 13, color: AppConstants.textSecondary),
                      const SizedBox(width: 3),
                      Text(
                        _elapsedText,
                        style: const TextStyle(fontSize: 12, color: AppConstants.textSecondary),
                      ),
                    ],
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                // 输入框
                Expanded(
                  child: GestureDetector(
                    onDoubleTap: () {
                      _barcodeController.selection = TextSelection(
                        baseOffset: 0,
                        extentOffset: _barcodeController.text.length,
                      );
                    },
                    child: TextField(
                      controller: _barcodeController,
                      focusNode: _barcodeFocus,
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(
                        hintText: '扫描或输入条码',
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 12,
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(AppConstants.radiusSm),
                        ),
                      ),
                      style: const TextStyle(fontSize: 16),
                      textInputAction: TextInputAction.search,
                      onSubmitted: (v) => _query(v),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                // 扫码按钮
                SizedBox(
                  height: 42,
                  child: ElevatedButton(
                    onPressed: (_querying || widget.verifying)
                        ? null
                        : () async {
                            final result = await Navigator.of(context).push<String>(
                              MaterialPageRoute(
                                builder: (_) => ScannerView(
                                  onDetect: (b) => Navigator.pop(context, b),
                                  onClose: () => Navigator.pop(context),
                                ),
                              ),
                            );
                            if (result != null) {
                              _barcodeController.text = result;
                              _query(result);
                            }
                          },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppConstants.primaryColor,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(
                            AppConstants.radiusSm),
                      ),
                    ),
                    child: BarcodeIcon(size: 22, color: Colors.white),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            // 查询按钮
            SizedBox(
              width: double.infinity,
              height: 42,
              child: ElevatedButton(
                onPressed: (_querying || widget.verifying)
                    ? null
                    : () => _query(_barcodeController.text),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppConstants.primaryColor,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius:
                        BorderRadius.circular(AppConstants.radiusSm),
                  ),
                ),
                child: _querying
                    ? Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            _elapsedText.isNotEmpty ? _elapsedText : '查询中…',
                            style: const TextStyle(fontSize: 14),
                          ),
                        ],
                      )
                    : const Text(
                        '查询多店',
                        style: TextStyle(fontSize: 16),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ==================== 调货逻辑 ====================

  List<String> _getStoreKeys() {
    return ['store1', 'store2', 'store3']
        .where((k) => _lastResult?.stores.containsKey(k) ?? false)
        .toList();
  }

  int _getDelta(String storeKey) {
    final keys = _getStoreKeys();
    if (_transferQty == 0) return 0;
    if (keys.length == 2) {
      if (storeKey == keys[0]) return _transferQty;
      return -_transferQty;
    }
    if (storeKey == _transferTarget && _transferSource != null) return _transferQty.abs();
    if (storeKey == _transferSource) return -_transferQty.abs();
    return 0;
  }

  TransferBtnType _getBtnType(String storeKey) {
    final keys = _getStoreKeys();
    if (keys.length == 2) return TransferBtnType.add;
    if (_transferQty == 0) return TransferBtnType.add;
    if (storeKey == _transferTarget || storeKey == _transferSource) return TransferBtnType.add;
    return TransferBtnType.swap;
  }

  void _onTransferTap(String storeKey) {
    _barcodeFocus.unfocus(); // 输入框失去焦点
    final keys = _getStoreKeys();

    if (keys.length == 2) {
      // 2店：无弹窗，直接对冲
      if (storeKey == keys[0]) {
        _transferQty++;
      } else {
        _transferQty--;
      }
    } else {
      // 3+店
      if (_transferSource == null) {
        // 未选来源 → 弹窗
        _showSourcePicker(storeKey);
        return;
      }

      if (storeKey == _transferTarget) {
        // 目标店：累加
        _transferQty = _transferQty.abs() + 1;
      } else if (storeKey == _transferSource) {
        // 来源店：减少调货量（对冲）
        _transferQty = _transferQty.abs() - 1;
      } else {
        // 非参与店：切换来源
        _showSourcePicker(_transferTarget!);
        return;
      }
    }

    if (_transferQty == 0) _cancelTransfer();
    setState(() {});
  }

  Widget _hintDot(Color color) {
    return Container(
      width: 10, height: 10,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: color, width: 2),
      ),
    );
  }

  List<Widget> _buildStoreCardsWithArrows(List<String> keys, MultiStoreResult r) {
    final widgets = <Widget>[];
    for (int i = 0; i < keys.length; i++) {
      final key = keys[i];
      final entry = r.stores[key]!;
      widgets.add(Expanded(
        child: TransferStoreCard(
          storeName: entry.storeName,
          result: entry,
          delta: _getDelta(key),
          btnType: _getBtnType(key),
          disabled: !entry.ok || entry.data == null,
          onTap: () => _onTransferTap(key),
        ),
      ));

      if (i < keys.length - 1) {
        final a = keys[i];
        final b = keys[i + 1];
        final showArrow = _transferQty != 0 && _showArrowAt(a, b);
        widgets.add(_buildArrow(showArrow, a, b));
      }
    }
    return widgets;
  }

  bool _showArrowAt(String a, String b) {
    if (_transferQty == 0) return false;
    final keys = _getStoreKeys();
    // 找到源和目标
    String src, tgt;
    if (keys.length == 2) {
      src = _transferQty > 0 ? keys[1] : keys[0];
      tgt = _transferQty > 0 ? keys[0] : keys[1];
    } else {
      if (_transferSource == null || _transferTarget == null) return false;
      src = _transferSource!;
      tgt = _transferTarget!;
    }
    final srcIdx = keys.indexOf(src);
    final tgtIdx = keys.indexOf(tgt);
    final aIdx = keys.indexOf(a);
    final bIdx = keys.indexOf(b);
    final lo = srcIdx < tgtIdx ? srcIdx : tgtIdx;
    final hi = srcIdx > tgtIdx ? srcIdx : tgtIdx;
    // 两个都在源→目标路径范围内
    return aIdx >= lo && aIdx <= hi && bIdx >= lo && bIdx <= hi;
  }

  Widget _buildArrow(bool active, String from, String to) {
    if (!active) return const SizedBox(width: 6);

    final keys = _getStoreKeys();
    String tgt;
    if (keys.length == 2) {
      tgt = _transferQty > 0 ? keys[0] : keys[1];
    } else {
      tgt = _transferTarget!;
    }
    final tgtIdx = keys.indexOf(tgt);
    // 箭头指向目标店方向
    final pointRight = tgtIdx > keys.indexOf(from);

    return Container(
      width: 20,
      alignment: Alignment.center,
      child: Icon(
        pointRight ? Icons.arrow_forward : Icons.arrow_back,
        size: 18,
        color: Colors.red,
      ),
    );
  }

  String _confirmBtnText() {
    final qty = _transferQty.abs();
    final keys = _getStoreKeys();

    String sourceName, targetName;
    if (keys.length == 2) {
      if (_transferQty > 0) {
        sourceName = _lastResult!.stores[keys[1]]!.storeName;
        targetName = _lastResult!.stores[keys[0]]!.storeName;
      } else {
        sourceName = _lastResult!.stores[keys[0]]!.storeName;
        targetName = _lastResult!.stores[keys[1]]!.storeName;
      }
    } else {
      sourceName = _lastResult!.stores[_transferSource!]!.storeName;
      targetName = _lastResult!.stores[_transferTarget!]!.storeName;
    }
    return '$sourceName → $targetName（${qty}件）';
  }

  void _cancelTransfer() {
    setState(() {
      _transferQty = 0;
      _transferTarget = null;
      _transferSource = null;
    });
  }

  void _showSourcePicker(String targetKey) {
    final keys = _getStoreKeys();
    final otherKeys = keys.where((k) => k != targetKey).toList();

    final storeNames = <String, String>{};
    if (_lastResult != null) {
      for (final k in keys) {
        storeNames[k] = _lastResult!.stores[k]?.storeName ?? k;
      }
    }

    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                '从哪个店调出到「${storeNames[targetKey] ?? targetKey}」？',
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
              ),
            ),
            ...otherKeys.map((k) => ListTile(
                  leading: const Icon(Icons.arrow_forward, color: Colors.red),
                  title: Text(storeNames[k] ?? k),
                  subtitle: _lastResult?.stores[k]?.data?.stock != null
                      ? Text('当前库存: ${_formatStockStr(_lastResult!.stores[k]!.data!.stock)} ${_lastResult!.stores[k]!.data!.unit}')
                      : null,
                  onTap: () {
                    Navigator.pop(ctx);
                    setState(() {
                      _transferTarget = targetKey;
                      _transferSource = k;
                      _transferQty = 1;
                    });
                  },
                )),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.close),
              title: const Text('取消'),
              onTap: () => Navigator.pop(ctx),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  String _formatStockStr(double? stock) {
    if (stock == null) return '—';
    if (stock == stock.roundToDouble()) return stock.toInt().toString();
    return stock.toStringAsFixed(2);
  }

  Future<void> _confirmTransfer() async {
    if (_transferQty == 0 || _lastResult == null) return;
    final qty = _transferQty.abs();
    final keys = _getStoreKeys();

    String targetKey, sourceKey;
    if (keys.length == 2) {
      if (_transferQty > 0) {
        targetKey = keys[0]; sourceKey = keys[1];
      } else {
        targetKey = keys[1]; sourceKey = keys[0];
      }
    } else {
      targetKey = _transferTarget!; sourceKey = _transferSource!;
    }

    final targetResult = _lastResult!.stores[targetKey];
    final sourceResult = _lastResult!.stores[sourceKey];
    if (targetResult == null || sourceResult == null) return;

    final targetConfig = _findConfig(targetResult.storeName);
    final sourceConfig = _findConfig(sourceResult.storeName);
    if (targetConfig == null || sourceConfig == null) {
      if (mounted) {
        _showBanner('找不到门店配置', isError: true);
      }
      return;
    }

    final barcode = (_lastResult!.stores.values
        .firstWhere((s) => s.data?.barcode.isNotEmpty == true,
            orElse: () => _lastResult!.stores.values.first)
        .data?.barcode ?? _lastResult!.barcode);
    if (barcode.isEmpty) return;

    setState(() => _querying = true);

    // 新库存
    final targetNew = (targetResult.data?.stock ?? 0) + qty;
    final sourceNew = (sourceResult.data?.stock ?? 0) - qty;

    // 两个店并发执行，互不阻塞
    final results = await Future.wait([
      widget.queryService.updateProductStock(sourceConfig, barcode, sourceNew),
      widget.queryService.updateProductStock(targetConfig, barcode, targetNew),
    ]);
    final sourceErr = results[0];
    final targetErr = results[1];

    if (mounted) {
      setState(() => _querying = false);

      if (sourceErr == null && targetErr == null) {
        _cancelTransfer();
        _showBanner('调货成功: ${sourceResult.storeName} → ${targetResult.storeName} ($qty件)');
        OperationLogService.add(
          store: '${sourceResult.storeName} → ${targetResult.storeName}',
          action: '调货',
          barcode: barcode,
          detail: '调出 $qty 件',
        );
        _query(barcode);
      } else {
        // 有失败 → 弹窗 + 可分享
        _showTransferFailDialog(
          barcode: barcode,
          sourceName: sourceResult.storeName,
          sourceOld: sourceResult.data?.stock ?? 0,
          sourceNew: sourceNew,
          targetName: targetResult.storeName,
          targetOld: targetResult.data?.stock ?? 0,
          targetNew: targetNew,
          qty: qty,
          sourceErr: sourceErr,
          targetErr: targetErr,
        );
      }
    }
  }

  void _showTransferFailDialog({
    required String barcode,
    required String sourceName,
    required double sourceOld,
    required double sourceNew,
    required String targetName,
    required double targetOld,
    required double targetNew,
    required int qty,
    String? sourceErr,
    String? targetErr,
  }) {
    final now = DateTime.now();
    final timeStr = '${now.year}-${now.month.toString().padLeft(2,'0')}-${now.day.toString().padLeft(2,'0')} '
        '${now.hour.toString().padLeft(2,'0')}:${now.minute.toString().padLeft(2,'0')}:${now.second.toString().padLeft(2,'0')}';

    final report = StringBuffer();
    report.writeln('【调货失败通知】');
    report.writeln('时间: $timeStr');
    report.writeln('条码: $barcode');
    report.writeln('数量: $qty 件');
    report.writeln('---');
    report.writeln('调出: $sourceName${sourceErr != null ? "（失败）" : "（成功）"}');
    report.writeln('  库存 ${_formatStockStr(sourceOld)} → ${_formatStockStr(sourceNew)}');
    if (sourceErr != null) report.writeln('  错误: $sourceErr');
    report.writeln('调入: $targetName${targetErr != null ? "（失败）" : "（成功）"}');
    report.writeln('  库存 ${_formatStockStr(targetOld)} → ${_formatStockStr(targetNew)}');
    if (targetErr != null) report.writeln('  错误: $targetErr');

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.error_outline, color: Colors.red, size: 20),
            SizedBox(width: 8),
            Text('调货失败', style: TextStyle(fontSize: 16)),
          ],
        ),
        content: SingleChildScrollView(
          child: Text(
            report.toString(),
            style: const TextStyle(fontSize: 13, fontFamily: 'monospace'),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('关闭'),
          ),
          TextButton.icon(
            onPressed: () async {
              Navigator.pop(ctx);
              try {
                final dir = Directory.systemTemp;
                final file = File('${dir.path}/调货失败_$barcode.txt');
                await file.writeAsString(report.toString());
                await Share.shareXFiles(
                  [XFile(file.path)],
                  subject: '调货失败通知 $barcode',
                );
              } catch (_) {
                _showBanner('分享失败，请截图发送', isError: true);
              }
            },
            icon: const Icon(Icons.share, size: 16),
            label: const Text('分享给管理员'),
          ),
        ],
      ),
    );
  }

  StoreConfig? _findConfig(String storeName) {
    for (final c in widget.configs) {
      if (c.name == storeName) return c;
    }
    return null;
  }

  // ==================== 错误卡片 ====================

  Widget _buildErrorCard(String error) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Card(
        color: AppConstants.errorColor.withValues(alpha: 0.1),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              const Icon(Icons.error_outline,
                  color: AppConstants.errorColor, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  error,
                  style: const TextStyle(
                    color: AppConstants.errorColor,
                    fontSize: 13,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ==================== 登录状态区 ====================

  Widget _buildSessionSection() {
    final loggedInCount = _loginStatuses.values.where((v) => v).length;
    final totalCount = widget.configs.length;

    return Card(
      elevation: 0,
      color: AppConstants.bgColor,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppConstants.radiusSm),
        side: BorderSide(color: AppConstants.dividerColor),
      ),
      child: ExpansionTile(
        title: Row(
          children: [
            Icon(
              totalCount > 0 && loggedInCount == totalCount
                  ? Icons.check_circle
                  : Icons.info_outline,
              size: 16,
              color: totalCount > 0 && loggedInCount == totalCount
                  ? AppConstants.successColor
                  : AppConstants.textSecondary,
            ),
            const SizedBox(width: 6),
            Text(
              '登录状态（$loggedInCount/$totalCount）',
              style: const TextStyle(
                fontSize: 13,
                color: AppConstants.textSecondary,
              ),
            ),
          ],
        ),
        dense: true,
        initiallyExpanded: totalCount > 0 && loggedInCount < totalCount,
        children: [
          if (widget.configs.isEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(14, 0, 14, 10),
              child: Text(
                '暂无门店配置，请切换到「配置」Tab 添加',
                style: TextStyle(fontSize: 12, color: AppConstants.textSecondary),
              ),
            )
          else
            ...widget.configs.map((config) {
              final loggedIn = _loginStatuses[config.storeKey] ?? false;
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
                child: Row(
                  children: [
                    Icon(
                      loggedIn ? Icons.check_circle : Icons.cancel,
                      size: 14,
                      color: loggedIn ? AppConstants.successColor : AppConstants.errorColor,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        config.name,
                        style: const TextStyle(fontSize: 12),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Text(
                      loggedIn ? '已登录' : '未登录',
                      style: TextStyle(
                        fontSize: 11,
                        color: loggedIn ? AppConstants.successColor : AppConstants.errorColor,
                      ),
                    ),
                  ],
                ),
              );
            }),
          const SizedBox(height: 6),
        ],
      ),
    );
  }
}

/// 电脑打印弹窗（仅数量 + 价格勾选，JSON 已预生成）
class _PcPrintDialog extends StatefulWidget {
  final String json;
  final String pcAddr;
  final void Function(String? error)? onResult;
  const _PcPrintDialog({required this.json, required this.pcAddr, this.onResult});
  @override State<_PcPrintDialog> createState() => _PcPrintDialogState();
}

class _PcPrintDialogState extends State<_PcPrintDialog> {
  final _qtyCtrl = TextEditingController(text: '1');
  bool _showPrice = false;
  bool _busy = false;
  late String _json;
  String _templateId = '';

  @override void initState() {
    super.initState();
    _templateId = RegExp(r'"templateId":"([^"]*)"').firstMatch(widget.json)?.group(1) ?? '';
    _json = widget.json;
    _loadPriceMemory();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _qtyCtrl.selection = TextSelection(baseOffset: 0, extentOffset: _qtyCtrl.text.length);
    });
  }
  @override void dispose() { _qtyCtrl.dispose(); super.dispose(); }

  Future<void> _loadPriceMemory() async {
    final prefs = await SharedPreferences.getInstance();
    final key = 'pc_print_sp_$_templateId';
    if (mounted) setState(() => _showPrice = prefs.getBool(key) ?? false);
  }

  Future<void> _savePriceMemory(bool v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('pc_print_sp_$_templateId', v);
  }

  Future<void> _doPrint() async {
    final qty = int.tryParse(_qtyCtrl.text) ?? 1;
    if (qty < 1) return;
    // 更新数量+价格
    _json = _json.replaceAll(RegExp(r'"showPrice":"[01]"'), '"showPrice":"${_showPrice ? "1" : "0"}"');
    _json = _json.replaceAll(RegExp(r'"qty":"\d+"'), '"qty":"$qty"');
    setState(() => _busy = true);
    try {
      final parts = widget.pcAddr.split(':');
      final ip = parts[0];
      final pt = int.tryParse(parts.length > 1 ? parts[1] : '18888') ?? 18888;
      final body = utf8.encode(_json);
      final all = utf8.encode(
          'POST / HTTP/1.1\r\n'
          'Host: ${widget.pcAddr}\r\n'
          'Content-Type: application/json\r\n'
          'Content-Length: ${body.length}\r\n'
          'Connection: close\r\n'
          '\r\n') + body;
      final s = await Socket.connect(ip, pt, timeout: const Duration(seconds: 5));
      s.add(all);
      await s.flush(); await s.close();
      if (mounted) {
        Navigator.pop(context);
        widget.onResult?.call(null);
      }
    } catch (e) {
      if (mounted) {
        Navigator.pop(context);
        widget.onResult?.call('连接失败: $e');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('打印', style: TextStyle(fontSize: 16)),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          const Text('数量:', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
          const SizedBox(width: 12),
          SizedBox(width: 100, child: TextField(
            controller: _qtyCtrl, keyboardType: TextInputType.number, autofocus: true,
            decoration: const InputDecoration(isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10), border: OutlineInputBorder()),
            onSubmitted: (_) => _doPrint(),
          )),
          if (_json.contains('"showPrice"')) ...[
            const SizedBox(width: 16),
            Row(mainAxisSize: MainAxisSize.min, children: [
              Checkbox(value: _showPrice, onChanged: (v) {
                setState(() {
                  _showPrice = v ?? true;
                  _qtyCtrl.selection = TextSelection(baseOffset: 0, extentOffset: _qtyCtrl.text.length);
                });
                _savePriceMemory(v ?? true);
              }, visualDensity: VisualDensity.compact),
              const Text('价格', style: TextStyle(fontSize: 13)),
            ]),
          ],
        ]),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        ElevatedButton(
          onPressed: _busy ? null : _doPrint,
          style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF1976D2), foregroundColor: Colors.white),
          child: _busy ? const SizedBox(width:16,height:16,child: CircularProgressIndicator(strokeWidth:2,color:Colors.white)) : const Text('打印'),
        ),
      ],
    );
  }
}


