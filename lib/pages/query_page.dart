import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:barcode/barcode.dart';
import 'package:image/image.dart' as img;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/store_config.dart';
import '../models/product_result.dart';
import '../models/restock_prefill_data.dart';
import '../services/login_service.dart';
import '../services/product_image_cache.dart';
import '../services/query_service.dart';
import '../services/session_manager.dart';
import '../services/query_logger.dart';
import '../services/operation_log_service.dart';
import '../models/query_log.dart';
import '../widgets/barcode_icon.dart';
import '../widgets/crop_page.dart';
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
  final ValueNotifier<({String barcode, String imageUrl})?>? imageUpdateNotifier;
  final ValueNotifier<({String barcode, String supplier})?>? supplierUpdateNotifier;
  final List<String> supplierOptions;

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
    this.imageUpdateNotifier,
    this.supplierUpdateNotifier,
    this.supplierOptions = const [],
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

  /// 多条匹配时用户选择的商品（覆盖首页商品信息显示）
  ProductData? _chosenProduct;


  // 调货状态
  int _transferQty = 0;
  String? _transferTarget;
  String? _transferSource;

  // 一维码 PNG 缓存（按条码内容缓存，避免重复生成）
  final Map<String, Uint8List> _barcodeCache = {};

  // 用户上传的商品图片（条码 -> 图片URL）
  final Map<String, String> _productImageOverrides = {};
  bool _uploadingProductImage = false;

  // 查询页手动更换的供货商（条码 -> 新供货商名，仅本次展示覆盖）
  final Map<String, String> _supplierOverrides = {};
  final Map<String, String> _productNameOverrides = {};

  // 库存编辑
  String? _editStockKey;
  final _editStockController = TextEditingController();
  bool _editingStock = false;

  // 操作员姓名（用于商品操作记录描述）
  String _operatorName = '';

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

  /// 全屏遮罩 + 转圈加载提示（修改商品名称等耗时操作期间告知用户）
  VoidCallback _showBlockingLoading(String msg) {
    final overlay = OverlayEntry(
      builder: (ctx) => Positioned.fill(
        child: Container(
          color: Colors.black.withValues(alpha: 0.25),
          alignment: Alignment.center,
          child: Card(
            elevation: 4,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12)),
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2.5),
                  ),
                  const SizedBox(width: 14),
                  Flexible(
                    child: Text(
                      msg,
                      style: const TextStyle(fontSize: 14),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    Overlay.of(context, rootOverlay: true).insert(overlay);
    return () => overlay.remove();
  }

  @override
  void initState() {
    super.initState();
    widget.imageUpdateNotifier?.addListener(_handleRestockImageUpdate);
    widget.supplierUpdateNotifier?.addListener(_handleRestockSupplierUpdate);
    _loadOperatorName();
    _checkLoginStatuses();
    _startKeepAlive();
  }

  /// 补货提交新图片后由 HomePage 通知：更新本地覆盖并刷新显示
  void _handleRestockImageUpdate() {
    final v = widget.imageUpdateNotifier?.value;
    if (v == null || !mounted) return;
    setState(() {
      _productImageOverrides[v.barcode] = v.imageUrl;
    });
  }

  /// 补货提交更换供货商后由 HomePage 通知：更新本地覆盖并刷新显示
  void _handleRestockSupplierUpdate() {
    final v = widget.supplierUpdateNotifier?.value;
    if (v == null || !mounted) return;
    setState(() {
      _supplierOverrides[v.barcode] = v.supplier;
    });
  }

  /// 从补货配置读取操作员姓名
  Future<void> _loadOperatorName() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('restock_config');
      if (raw == null || raw.isEmpty) return;
      final cfg =
          RestockConfig.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      if (mounted && cfg.operatorName.trim().isNotEmpty) {
        setState(() => _operatorName = cfg.operatorName.trim());
      }
    } catch (_) {}
  }

  /// 确保已设置操作员姓名；未设置时弹窗填写并保存，返回 null 表示仍未填写
  Future<String?> _ensureOperatorName() async {
    if (_operatorName.trim().isNotEmpty) return _operatorName.trim();
    final ctrl = TextEditingController();
    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('操作员姓名'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: '请填写操作员姓名（用于商品操作记录）',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('确认'),
          ),
        ],
      ),
    );
    final name = ctrl.text.trim();
    if (name.isEmpty) return null;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('restock_config');
      var cfg = RestockConfig.fromJson((raw == null || raw.isEmpty)
          ? const {}
          : jsonDecode(raw) as Map<String, dynamic>);
      cfg = cfg.copyWith(operatorName: name);
      await prefs.setString('restock_config', jsonEncode(cfg.toJson()));
    } catch (_) {}
    if (mounted) setState(() => _operatorName = name);
    return name;
  }

  void _startKeepAlive() {
    _keepAliveTimer?.cancel();
    // 微信扫码登录可长期在线，无需频繁验证；改为 1 小时检查一次
    _keepAliveTimer = Timer.periodic(const Duration(minutes: 60), (_) {
      _doKeepAlive();
    });
  }

  /// 重置保活计时器（每次扫码或保活重登后调用，避免空闲时重复请求）
  void _restartKeepAliveTimer() {
    if (!mounted) return;
    _keepAliveTimer?.cancel();
    // 微信扫码登录可长期在线，无需频繁验证；改为 1 小时检查一次
    _keepAliveTimer = Timer.periodic(const Duration(minutes: 60), (_) {
      _doKeepAlive();
    });
  }

  Future<void> _doKeepAlive() async {
    final expiredConfigs = <StoreConfig>[];
    final needScan = <String>[];
    for (final config in widget.configs) {
      if (!config.enabled) continue; // 只保活勾选了搜索的门店
      final valid = await widget.queryService.keepAlive(config);
      if (!valid) {
        if (config.isValid) {
          expiredConfigs.add(config);
        } else {
          needScan.add(config.name);
        }
      }
    }
    if (needScan.isNotEmpty && mounted) {
      _showBanner('保活: ' + needScan.join('、') + ' 登录已过期，请在设置用微信扫码重新登录', isError: true);
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
    widget.imageUpdateNotifier?.removeListener(_handleRestockImageUpdate);
    widget.supplierUpdateNotifier?.removeListener(_handleRestockSupplierUpdate);
    _barcodeController.dispose();
    _barcodeFocus.dispose();
    _scrollController.dispose();
    _editStockController.dispose();
    super.dispose();
  }

  Future<void> _checkLoginStatuses() async {
    // 仅本地缓存快速检查，不发起 HTTP 请求
    // HTTP Cookie 验证开销大（每个门店一次 GET），改为在搜索时按需处理过期
    final statuses = <String, bool>{};
    for (final config in widget.configs) {
      if (!config.enabled) continue; // 只统计勾选了搜索的门店
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
    _productImageOverrides.clear(); // 新搜索清空图片缓存，展示服务器最新图片

    setState(() {
      _querying = true;
      _error = null;
      _lastResult = null;
      _chosenProduct = null;
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
      final enabledConfigs = widget.configs.where((c) => c.enabled).toList();
      if (enabledConfigs.isEmpty) {
        setState(() {
          _querying = false;
          _error = '未勾选任何搜索门店，请在设置 → ID数据管理中勾选要搜索的门店';
        });
        return;
      }
      var result = await widget.queryService.queryAllStores(
        enabledConfigs,
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
          final nameToConfig = <String, StoreConfig>{};
          for (final c in enabledConfigs) { nameToConfig[c.name] = c; }
          final expiredConfigs = needRelogin
              .map((s) => nameToConfig[s.storeName])
              .whereType<StoreConfig>()
              .toList();
          final reloginNames = expiredConfigs.map((c) => c.name).join('、');
          // 总账号（微信扫码）模式下没有工号密码，无法自动重登 → 提示去设置页扫码
          final reloginable = expiredConfigs
              .where((c) => c.cashierJobNumber.isNotEmpty && c.password.isNotEmpty)
              .toList();
          if (reloginable.isEmpty) {
            setState(() => _elapsedText = '登录已失效');
            _showBanner('$reloginNames 登录已失效，请到 设置 → 总店账号 → 微信扫码重新登录', isError: true);
          } else {
            reLoginHappened = true;
            final reloginStart = DateTime.now();
            setState(() => _elapsedText = '正在重新登录…');
            _showBanner('$reloginNames 登录过期，正在重新登录…');
            // 仅重登过期的门店
            await Future.wait(
              reloginable.map((c) => widget.loginService.login(c).catchError((_) {}))
            );
            reLoginMs = DateTime.now().difference(reloginStart).inMilliseconds;
            // 重新查询
            if (mounted) {
              setState(() => _elapsedText = '重新查询中…');
              _showBanner('重新登录完成，继续查询…');
              result = await widget.queryService.queryAllStores(
                enabledConfigs,
                barcode.trim(),
              );
              if (result.diagnostics != null) {
                allDiags.addAll(result.diagnostics!);
              }
            }
          }
        }      }

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

        // 后台预下载商品图片：只预下载显示用图（小体积，保证卡片秒开）；
        // 大原图不主动批量下载，点击放大预览或发起补货时按需下载
        final displayUrls = <String>{};
        for (final s in result.stores.values) {
          final u = s.data?.imageUrl ?? '';
          if (u.isNotEmpty && !u.contains('default_200x200')) {
            final full = u.startsWith('http') ? u : 'https://img.pospal.cn$u';
            displayUrls.add(full);
          }
        }
        for (final u in displayUrls) {
          ProductImageCache.preload(u);
        }

        // 多条匹配 → 弹窗让用户选择要查看的商品
        await _maybeShowCandidatePicker();

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
        GestureDetector(
          onTap: () => FocusScope.of(context).unfocus(),
          child: SingleChildScrollView(
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
      ),
    // 图片上传/更新中：全屏遮罩，禁止任何操作
    if (_uploadingProductImage)
      Positioned.fill(
        child: ColoredBox(
          color: Colors.black.withValues(alpha: 0.35),
          child: Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2.5),
                  ),
                  SizedBox(width: 12),
                  Text('正在上传图片，请稍候…', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                ],
              ),
            ),
          ),
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
    // 找到第一个有数据的门店（用户已选择商品时优先显示所选商品）
    final firstData = _chosenProduct ?? r.stores.values
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

        // 多条结果提示（用户尚未选择时）
        if (_chosenProduct == null &&
            firstData?.multipleMatches != null && firstData!.multipleMatches! > 1)
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

        // 库存编辑按钮
        if (_editStockKey != null && _transferQty == 0) ...[
          const SizedBox(height: 10),
          Row(children: [
            Expanded(child: _actionBtn('取消', Icons.cancel, Colors.grey, _cancelEditStock)),
            const SizedBox(width: 6),
            _editingStock
                ? Expanded(
                    child: SizedBox(
                      height: 36,
                      child: ElevatedButton(
                        onPressed: null,
                        style: ElevatedButton.styleFrom(backgroundColor: AppConstants.primaryColor),
                        child: const Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)),
                            SizedBox(width: 8),
                            Text('提交中…', style: TextStyle(fontSize: 13, color: Colors.white)),
                          ],
                        ),
                      ),
                    ),
                  )
                : Expanded(child: _actionBtn('确认修改', Icons.check, AppConstants.primaryColor, _confirmStockEdit)),
          ]),
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

  /// 生成一维码 PNG（对应商品条码，便于电脑扫码枪直接扫描）
  Uint8List? _barcodePng(String code) {
    if (code.isEmpty) return null;
    final cached = _barcodeCache[code];
    if (cached != null) return cached;
    try {
      const maxW = 180;
      const targetH = 20;
      const quietPx = 10; // 左右白色安静区，便于扫码枪/识别引擎定位
      final bc = Barcode.code128();
      // 先用大宽度获取模块布局，再按整数 module 像素重绘，保证条宽比例正确
      final recipe = bc.make(code, width: 1000.0, height: 100.0).toList();
      double minBarW = double.infinity;
      double maxRight = 0;
      for (final el in recipe) {
        if (el is BarcodeBar && el.black) {
          if (el.width < minBarW) minBarW = el.width;
          if (el.left + el.width > maxRight) maxRight = el.left + el.width;
        }
      }
      if (minBarW <= 0 || maxRight <= 0) return null;
      final modules = (maxRight / minBarW).round();
      var modulePx = (maxW / modules).floor();
      if (modulePx < 1) modulePx = 1;
      if (modulePx > 3) modulePx = 3;
      final imgW = modules * modulePx + quietPx * 2;
      final scale = modulePx / minBarW;
      final image = img.Image(imgW, targetH);
      img.fill(image, 0xFFFFFFFF);
      for (final el in recipe) {
        // 只画黑色条；fillRect 的 x2 为闭区间，需减 1 避免条宽多画
        if (el is BarcodeBar && el.black) {
          final x = (el.left * scale).round() + quietPx;
          final bw = (el.width * scale).round();
          if (bw > 0) {
            img.fillRect(image, x, 0, x + bw - 1, targetH, 0xFF000000);
          }
        }
      }
      final png = Uint8List.fromList(img.encodePng(image));
      _barcodeCache[code] = png;
      return png;
    } catch (_) {
      return null;
    }
  }

  Widget _buildProductInfo(ProductData data, String barcode) {
    final barcodePng = _barcodePng(data.barcode.isNotEmpty ? data.barcode : barcode);
    return Card(
      elevation: 1,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppConstants.radiusMd),
      ),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 商品名称
                  _buildProductName(
                      _productNameOverrides[_productKey(data)] ?? data.name,
                      data),
                  const SizedBox(height: 6),
                  // 信息行
                  _buildInfoRow(
                    Icons.view_week,
                    '条码',
                    data.barcode.isNotEmpty ? data.barcode : barcode,
                    onTap: () => _copyText(
                        data.barcode.isNotEmpty ? data.barcode : barcode),
                  ),
                  // 一维码（对应商品条码，便于电脑扫码枪直接扫描）
                  if (barcodePng != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Image.memory(
                          barcodePng,
                          gaplessPlayback: true,
                        ),
                      ),
                    ),
                  if (data.supplier.isNotEmpty)
                    InkWell(
                      onTap: () => _showSupplierPicker(data, _supplierOverrides[barcode] ?? data.supplier),
                      borderRadius: BorderRadius.circular(4),
                      child: Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Row(
                          children: [
                            const Icon(Icons.business, size: 14, color: Color(0xFF28a745)),
                            const SizedBox(width: 6),
                            const Text('供货商：', style: TextStyle(fontSize: 13, color: AppConstants.textSecondary)),
                            Expanded(
                              child: Text(
                                _supplierOverrides[barcode] ?? data.supplier,
                                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Color(0xFF28a745)),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const Icon(Icons.edit, size: 13, color: Color(0xFF28a745)),
                          ],
                        ),
                      ),
                    ),
                  _buildInfoRow(Icons.scale, '单位', data.unit),
                  // 进价 + 售价同行
                  if (data.buyPrice != null || data.sellPrice != null)
                    _buildPriceRow(data.buyPrice, data.sellPrice),
                ],
              ),
            ),
            const SizedBox(width: 10),
            _buildProductImageBox(data, barcode),
          ],
        ),
      ),
    );
  }

  Widget _buildProductImageBox(ProductData data, String barcode) {
    final overrideUrl = _productImageOverrides[barcode];
    final imageUrl = overrideUrl ?? data.imageUrl;
    final hasImage = imageUrl != null &&
        imageUrl.isNotEmpty &&
        !imageUrl.contains('default_200x200');
    return GestureDetector(
      onTap: hasImage
          ? () => _showProductImagePreview(data, barcode)
          : () => _addProductImage(data, barcode),
      child: Container(
        width: 70,
        height: 70,
        decoration: BoxDecoration(
          color: AppConstants.bgColor,
          borderRadius: BorderRadius.circular(9),
          border: Border.all(color: AppConstants.dividerColor),
        ),
        child: _uploadingProductImage
            ? const Center(
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              )
            : hasImage
                ? _CachedImage(
                    url: imageUrl!,
                    width: 70,
                    height: 70,
                    decodeWidth: 140,
                    decodeHeight: 140,
                  )
                : Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.camera_alt, size: 24, color: AppConstants.textSecondary),
                      const SizedBox(height: 2),
                      const Text(
                        '添加图片',
                        style: TextStyle(fontSize: 9, color: AppConstants.textSecondary),
                      ),
                    ],
                  ),
      ),
    );
  }

/// 无图时点击：拍照/导入图片 → CropPage 手动裁剪成正方形 → 逐个门店上传
  Future<void> _addProductImage(ProductData data, String barcode) async {
    if (widget.configs.isEmpty) {
      _showBanner('未配置门店', isError: true);
      return;
    }

    // 选择图片来源
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.camera_alt),
              title: const Text('拍照'),
              onTap: () => Navigator.pop(ctx, ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('从相册导入'),
              onTap: () => Navigator.pop(ctx, ImageSource.gallery),
            ),
          ],
        ),
      ),
    );
    if (source == null || !mounted) return;

    // 参照补货逻辑：选图后进入裁剪页，手动拖动正方形选框
    final picker = ImagePicker();
    final picked = await picker.pickImage(source: source, maxWidth: 1200, maxHeight: 1200);
    if (picked == null || !mounted) return;
    final croppedPath = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => CropPage(imagePath: picked.path)),
    );
    if (croppedPath == null || !mounted) return;

    final opName = await _ensureOperatorName();
    if (opName == null) {
      _showBanner('请填写操作员姓名后再上传图片', isError: true);
      return;
    }

    setState(() => _uploadingProductImage = true);
    try {
      // 银豹限制单图不超过 3MB，上传前统一压缩到 500KB 以内，体积小更稳定
      final bytes =
          _compressImageForUpload(await File(croppedPath).readAsBytes());
      // 所有门店并行上传（银豹图片按门店隔离，不会自动同步），失败自动重试 1 次
      // 静默重试直到成功（最多 5 次，失败自动重试，不中断不打扰）
      final results = await Future.wait(widget.configs.map((store) async {
        String? lastErr;
        for (var attempt = 0; attempt < 5; attempt++) {
          if (attempt > 0) {
            await Future.delayed(const Duration(seconds: 2));
          }
          try {
            final (err, url) = await widget.queryService.replaceProductImage(
              store,
              barcode,
              bytes,
              'IMG_${DateTime.now().millisecondsSinceEpoch}.jpg',
              productUid: data.uid?.toString(),
            );
            if (err == null && url != null) {
              return (name: store.name, ok: true, url: url, error: null as String?);
            }
            if (err == '未登录') {
              return (name: store.name, ok: false, url: null as String?, error: null as String?);
            }
            lastErr = err;
          } catch (e) {
            lastErr = e.toString();
          }
        }
        return (name: store.name, ok: false, url: null as String?, error: lastErr);
      }));
      var successCount = 0;
      final failedStores = <String>[];
      String? lastUrl;
      for (final r in results) {
        if (r.ok && r.url != null) {
          successCount++;
          lastUrl = r.url;
        } else if (r.error != null) {
          failedStores.add('${r.name}:${r.error}');
        }
      }
      if (successCount > 0 && lastUrl != null) {
        _productImageOverrides[barcode] = lastUrl;
        ProductImageCache.cache(lastUrl, bytes);
      }
      if (!mounted) return;
      if (successCount > 0) {
        // 同步写入操作记录描述（失败不阻断，只提示）
        final descErrors = <String>[];
        for (final store in widget.configs) {
          final err = await widget.queryService.updateProductOperationNote(
            store,
            barcode,
            opName,
            '更新照片',
            productUid: data.uid?.toString(),
          );
          if (err != null && err != '未登录') {
            descErrors.add('${store.name}：$err');
          }
        }
        if (!mounted) return;
        setState(() {});
        final baseMsg = successCount == widget.configs.length
            ? '图片上传成功 ✓（$successCount 个门店）'
            : '部分门店成功（$successCount/${widget.configs.length}）：${failedStores.join('；')}';
        _showBanner(descErrors.isEmpty
            ? baseMsg
            : '$baseMsg；描述未写入：${descErrors.join('；')}',
            isError: descErrors.isNotEmpty);
      } else {
        _showBanner('图片上传失败：${failedStores.join('；')}', isError: true);
      }
    } catch (e) {
      if (mounted) _showBanner('上传出错：$e', isError: true);
    } finally {
      if (mounted) setState(() => _uploadingProductImage = false);
    }
  }

  /// 上传图片统一压缩到 500KB 以内
  List<int> _compressImageForUpload(Uint8List bytes) {
    if (bytes.length < 512 * 1024) return bytes; // 已 ≤500KB
    try {
      final decoded = img.decodeImage(bytes);
      if (decoded == null) return bytes;
      final img2 = decoded.width >= decoded.height
          ? img.copyResize(decoded, width: 1200)
          : img.copyResize(decoded, height: 1200);
      // 逐级降质量直到 ≤500KB
      for (final q in [85, 70, 50, 35]) {
        final encoded = img.encodeJpg(img2, quality: q);
        if (encoded.length < 512 * 1024) return encoded;
      }
      // 仍超限：缩小到 800 再压
      final img3 = img2.width >= img2.height
          ? img.copyResize(img2, width: 800)
          : img.copyResize(img2, height: 800);
      return img.encodeJpg(img3, quality: 60);
    } catch (_) {
      return bytes;
    }
  }

  void _showProductImagePreview(ProductData data, String barcode) {
    final url = _productImageOverrides[barcode] ?? data.imageUrl ?? '';
    if (url.isEmpty) return;
    // 预览加载原图（去掉 _200x200 缩略图后缀），走缓存优先组件
    final full = url.startsWith('http') ? url : 'https://img.pospal.cn$url';
    final original = full.replaceAll('_200x200', '');
    showDialog(
      context: context,
      barrierColor: Colors.black87,
      builder: (ctx) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => Navigator.pop(ctx),
        child: SizedBox.expand(
          child: Stack(
            children: [
              Center(
                child: InteractiveViewer(
                  maxScale: 5,
                  child: _CachedImage(
                    url: original,
                    fit: BoxFit.contain,
                    radius: 0,
                    placeholder: const Icon(Icons.broken_image, size: 64, color: Colors.white70),
                  ),
                ),
              ),
              // 放大界面内选择是否更换照片
              Positioned(
                right: 16,
                bottom: 28,
                child: FloatingActionButton.extended(
                  heroTag: 'change_product_image',
                  backgroundColor: Colors.white.withValues(alpha: 0.92),
                  foregroundColor: Colors.black87,
                  icon: const Icon(Icons.camera_alt),
                  label: const Text('更换照片'),
                  onPressed: () {
                    Navigator.pop(ctx);
                    _addProductImage(data, barcode);
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  final Map<String, String> _transCache = {};

  /// 复制文本到剪贴板并提示
  void _copyText(String text) {
    Clipboard.setData(ClipboardData(text: text));
    _showBanner('已复制：$text');
  }

  /// 商品身份键：优先用商品唯一ID，避免同一条码多个商品互相覆盖
  String _productKey(ProductData d) {
    final uid = d.uid?.toString() ?? '';
    if (uid.isNotEmpty) return 'uid:$uid';
    return 'bc:${d.barcode}';
  }

  Widget _buildProductName(String name, ProductData data) {
    if (name.isEmpty) {
      return const Text('(未命名商品)',
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold));
    }

    // 商品名称完整显示（# 属于名称本身，不能按 # 拆分）
    final productName = name.trim();

    // 触发翻译（仅英文名）
    final needTrans = _needsTranslation(productName);
    if (needTrans && !_transCache.containsKey(productName)) {
      _translate(productName);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          // 单击复制，双击编辑商品名称并同步全部门店
          onTap: () => _copyText(name),
          onDoubleTap: () => _showProductNameEditor(data),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Flexible(
                child: Text(
                  productName.isNotEmpty ? productName : '(未命名商品)',
                  style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
                ),
              ),
              const SizedBox(width: 6),
              const Icon(Icons.edit_outlined,
                  size: 14, color: AppConstants.textSecondary),
            ],
          ),
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

  Widget _buildInfoRow(IconData icon, String label, String value,
      {VoidCallback? onTap}) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(4),
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
        color: AppConstants.warningColor.withValues(alpha: 0.16),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            children: [
              const Icon(Icons.warning_amber, color: Color(0xFF8A5300), size: 18),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '查询到 $count 条匹配结果，当前显示第一条',
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF7A4E00),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 当前要展示的商品：用户选择优先，否则取第一个有数据的门店
  ProductData? _currentProductData(MultiStoreResult r) {
    if (_chosenProduct != null) return _chosenProduct;
    return r.stores.values
        .where((s) => s.ok && s.data != null)
        .firstOrNull
        ?.data;
  }

  /// 搜索结果存在多个匹配商品时，弹窗让用户选择要查看的商品
  Future<void> _maybeShowCandidatePicker() async {
    final r = _lastResult;
    if (r == null) return;

    final storeNames = <String, String>{
      for (final e in r.stores.entries) e.key: e.value.storeName,
    };
    // 按 条码+名称 去重，收集所有门店返回的候选商品，并记录每个门店各自的库存，
    // 避免并发查询返回顺序不固定导致库存互相覆盖
    final unique = <String, _CandidateChoice>{};
    for (final e in r.stores.entries) {
      final s = e.value;
      if (!s.ok || s.data == null) continue;
      final cs = s.data!.candidates ?? <ProductData>[s.data!];
      for (final p in cs) {
        final key = '${p.barcode}\u0000${p.name}';
        final existing = unique[key];
        if (existing == null) {
          unique[key] = _CandidateChoice(
            product: p,
            storeStocks: {e.key: p.stock},
            storeNamesOfMatch: {e.key: s.storeName},
          );
        } else {
          // 同一个商品在各门店的库存分别记录，弹窗里按门店标注
          existing.storeStocks[e.key] = p.stock;
          existing.storeNamesOfMatch[e.key] = s.storeName;
        }
      }
    }
    if (unique.length < 2) return;

    final entries = unique.values.toList();
    final picked = await showDialog<_CandidateChoice>(
      context: context,
      builder: (ctx) => _CandidatePickerDialog(
        title: '找到 ${entries.length} 个匹配商品',
        entries: entries,
        storeNames: storeNames,
      ),
    );
    if (picked == null || !mounted) return;

    setState(() {
      _chosenProduct = picked.product;
      // 所有门店卡片统一显示所选商品，各自使用本店自己的库存；
      // 未返回该商品的门店显示“—”，避免不同商品混在同一行导致库存对不上
      final stores = Map<String, StoreStockResult>.from(_lastResult!.stores);
      for (final entry in stores.entries) {
        final old = entry.value;
        if (!old.ok || old.data == null) continue;
        final srcp = picked.product;
        stores[entry.key] = StoreStockResult(
          storeName: old.storeName,
          data: ProductData(
            barcode: srcp.barcode,
            name: srcp.name,
            specification: srcp.specification,
            category: srcp.category,
            stock: picked.storeStocks[entry.key],
            unit: srcp.unit,
            supplier: srcp.supplier,
            sellPrice: srcp.sellPrice,
            buyPrice: srcp.buyPrice,
            uid: srcp.uid,
            imageUrl: srcp.imageUrl,
            multipleMatches: srcp.multipleMatches,
            candidates: srcp.candidates,
            rawKeys: srcp.rawKeys,
            numericFields: srcp.numericFields,
            parseFailed: srcp.parseFailed,
            fromBrowser: srcp.fromBrowser,
            allColumns: srcp.allColumns,
          ),
          error: old.error,
          ok: old.ok,
        );
      }
      _lastResult = MultiStoreResult(
        barcode: _lastResult!.barcode,
        stores: stores,
        elapsedSeconds: _lastResult!.elapsedSeconds,
        diagnostics: _lastResult!.diagnostics,
      );
    });
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
    final firstData = _currentProductData(r);
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
    final firstData = _currentProductData(r);
    final barcode = (firstData?.barcode.isNotEmpty == true)
        ? firstData!.barcode
        : r.barcode;
    // 查询结果图片：仅真正的商品图才传递（排除系统无图占位 default_200x200）
    String? prefillImageUrl;
    final srcImage = _productImageOverrides[barcode] ?? firstData?.imageUrl ?? '';
    final hasRealImage =
        srcImage.isNotEmpty && !srcImage.contains('default_200x200');
    if (hasRealImage) {
      prefillImageUrl = srcImage.startsWith('http')
          ? srcImage
          : 'https://img.pospal.cn$srcImage';
      prefillImageUrl = prefillImageUrl!.replaceAll('_200x200', '');
    }
    if (mounted && widget.onNavigateToRestock != null) {
      widget.onNavigateToRestock!(RestockPrefillData(
        barcode: barcode,
        supplier: firstData?.supplier ?? '',
        productName: (firstData?.name ?? '').replaceAll('&', ''),
        specification: firstData?.specification ?? '',
        buyPrice: firstData?.buyPrice,
        sellPrice: firstData?.sellPrice,
        imageUrl: prefillImageUrl,
        uid: firstData?.uid?.toString(),
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
                      enabled: !_uploadingProductImage,
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
                        suffixIcon: IconButton(
                          icon: const Icon(Icons.search, size: 22),
                          onPressed: _uploadingProductImage
                              ? null
                              : () => _query(_barcodeController.text),
                        ),
                      ),
                      style: const TextStyle(fontSize: 16),
                      textInputAction: TextInputAction.search,
                      onSubmitted: (v) {
                        if (_uploadingProductImage) return;
                        _query(v);
                      },
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                // 扫码按钮
                SizedBox(
                  height: 42,
                  child: ElevatedButton(
                    onPressed: (_querying || widget.verifying || _uploadingProductImage)
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
                onPressed: (_querying || widget.verifying || _uploadingProductImage)
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
          onDoubleTap: () => _startEditStock(key),
          isEditing: _editStockKey == key,
          stockController: _editStockKey == key ? _editStockController : null,
          onEditConfirm: _onEditCheckTap,
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

  void _startEditStock(String storeKey) {
    if (_transferQty != 0) return;
    final storeData = _lastResult?.stores[storeKey]?.data;
    setState(() {
      _editStockKey = storeKey;
      _editStockController.text = storeData?.stock?.toString() ?? '';
      _editStockController.selection = TextSelection(baseOffset: 0, extentOffset: _editStockController.text.length);
    });
  }

  void _cancelEditStock() {
    setState(() {
      _editStockKey = null;
      _editStockController.clear();
    });
  }

  void _onEditCheckTap() {
    FocusScope.of(context).unfocus();
  }

  Future<void> _confirmStockEdit() async {
    if (_editStockKey == null || _lastResult == null) return;
    final text = _editStockController.text.trim();
    if (text.isEmpty) return;
    final qty = double.tryParse(text);
    if (qty == null || qty < 0) {
      _showBanner('请输入有效库存数量', isError: true);
      return;
    }
    final storeData = _lastResult!.stores[_editStockKey!];
    if (storeData == null || storeData.data == null) return;
    final config = _findConfig(storeData.storeName);
    if (config == null) {
      _showBanner('找不到门店配置', isError: true);
      return;
    }
    final opName = await _ensureOperatorName();
    if (opName == null) {
      _showBanner('请填写操作员姓名后再更新库存', isError: true);
      return;
    }
    final product = storeData.data!;
    final barcode =
        product.barcode.isNotEmpty ? product.barcode : _lastResult!.barcode;
    setState(() => _editingStock = true);
    try {
      final error = await widget.queryService.updateProductStock(
        config,
        barcode,
        qty,
        productUid: product.uid?.toString(),
      );
      if (error != null) {
        _showBanner(error, isError: true);
      } else {
        final descErr = await widget.queryService.updateProductOperationNote(
          config,
          barcode,
          opName,
          '更新库存',
          productUid: product.uid?.toString(),
        );
        _showBanner(descErr == null
            ? '库存已更新'
            : '库存已更新，描述未写入：$descErr',
            isError: descErr != null);
        _cancelEditStock();
        final code = _barcodeController.text.trim();
        if (code.isNotEmpty) {
          _query(code);
        }
      }
    } catch (e) {
      _showBanner('更新失败: $e', isError: true);
    } finally {
      setState(() => _editingStock = false);
    }
  }

  void _cancelTransfer() {
    setState(() {
      _transferQty = 0;
      _transferTarget = null;
      _transferSource = null;
    });
  }

  /// 点击结果卡片的供货商，弹出选择框更换供货商并同步到银豹
  void _showSupplierPicker(ProductData data, String current) {
    final options = widget.supplierOptions;
    if (options.isEmpty) {
      _showBanner('暂无供货商列表，请先在配置页同步/添加供货商', isError: true);
      return;
    }
    String selected = current;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        var keyword = '';
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            final filtered = keyword.trim().isEmpty
                ? options
                : options.where((o) => o.contains(keyword.trim())).toList();
            return SafeArea(
              child: Padding(
                padding: EdgeInsets.only(
                  left: 16,
                  right: 16,
                  top: 16,
                  bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '选择供货商',
                      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                    ),
                    if (current.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          '当前：$current',
                          style: const TextStyle(fontSize: 13, color: AppConstants.textSecondary),
                        ),
                      ),
                    const SizedBox(height: 8),
                    TextField(
                      decoration: const InputDecoration(
                        hintText: '搜索供货商',
                        prefixIcon: Icon(Icons.search),
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                      onChanged: (v) => setSheetState(() => keyword = v),
                    ),
                    const SizedBox(height: 8),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 320),
                      child: ListView(
                        shrinkWrap: true,
                        children: filtered.isEmpty
                            ? const [
                                Padding(
                                  padding: EdgeInsets.all(16),
                                  child: Text('无匹配供货商', style: TextStyle(color: AppConstants.textSecondary)),
                                ),
                              ]
                            : filtered
                                .map((o) => ListTile(
                                      dense: true,
                                      leading: Icon(
                                        o == selected ? Icons.radio_button_checked : Icons.radio_button_off,
                                        color: o == selected ? const Color(0xFF28a745) : AppConstants.textSecondary,
                                      ),
                                      title: Text(o, maxLines: 1, overflow: TextOverflow.ellipsis),
                                      selected: o == selected,
                                      onTap: () => setSheetState(() => selected = o),
                                    ))
                                .toList(),
                      ),
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppConstants.primaryColor,
                          foregroundColor: Colors.white,
                        ),
                        onPressed: selected.isEmpty
                            ? null
                            : () {
                                Navigator.pop(ctx);
                                _syncSupplierChange(data, current, selected);
                              },
                        child: const Text('确定并同步'),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  /// 把查询页手动更换的供货商同步到银豹（所有已登录门店），并更新本地显示
  Future<void> _syncSupplierChange(
      ProductData data, String current, String newSupplier) async {
    final barcode =
        data.barcode.isNotEmpty ? data.barcode : _lastResult?.barcode ?? '';
    if (current == newSupplier) {
      _showBanner('供货商未变化');
      return;
    }
    final opName = await _ensureOperatorName();
    if (opName == null) {
      _showBanner('请填写操作员姓名后再更新供货商', isError: true);
      return;
    }
    _showBanner('正在同步供货商…');
    final errors = <String>[];
    var syncedCount = 0;
    for (final store in widget.configs) {
      try {
        final err = await widget.queryService.updateProductSupplier(
          store,
          barcode,
          newSupplier,
          productUid: data.uid?.toString(),
        );
        if (err == null) {
          syncedCount++;
        } else if (err != '未登录') {
          errors.add('${store.name}：$err');
        }
      } catch (e) {
        errors.add('${store.name}：$e');
      }
    }
    if (!mounted) return;
    setState(() => _supplierOverrides[barcode] = newSupplier);
    if (errors.isEmpty) {
      if (syncedCount == 0) {
        _showBanner('没有已登录的门店，无法同步', isError: true);
        return;
      }
      final descErrors = <String>[];
      for (final store in widget.configs) {
        final err = await widget.queryService.updateProductOperationNote(
          store,
          barcode,
          opName,
          '更新供货商',
          productUid: data.uid?.toString(),
        );
        if (err != null && err != '未登录') {
          descErrors.add('${store.name}：$err');
        }
      }
      _showBanner(descErrors.isEmpty
          ? '供货商已更新为「$newSupplier」✓'
          : '供货商已更新为「$newSupplier」，描述未写入：${descErrors.join('；')}',
          isError: descErrors.isNotEmpty);
    } else {
      _showBanner('部分同步失败：${errors.join('；')}', isError: true);
    }
  }

  /// 双击商品名称：弹出编辑框，确定后同步到所有门店
  void _showProductNameEditor(ProductData data) {
    final current =
        _productNameOverrides[_productKey(data)] ?? data.name;
    final controller = TextEditingController(text: current);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('编辑商品名称', style: TextStyle(fontSize: 16)),
        content: TextField(
          controller: controller,
          autofocus: true,
          minLines: 1,
          maxLines: 3,
          textInputAction: TextInputAction.done,
          onSubmitted: (v) {
            final value = v.trim();
            if (value.isEmpty) return;
            Navigator.pop(ctx);
            _syncProductNameChange(data, value);
          },
          decoration: const InputDecoration(
            hintText: '输入新的商品名称',
            isDense: true,
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppConstants.primaryColor,
              foregroundColor: Colors.white,
            ),
            onPressed: () {
              final value = controller.text.trim();
              if (value.isEmpty) return;
              Navigator.pop(ctx);
              _syncProductNameChange(data, value);
            },
            child: const Text('确定并同步'),
          ),
        ],
      ),
    );
  }

  /// 把新商品名称同步到银豹（所有已登录门店），并更新本地所有门店卡片显示
  Future<void> _syncProductNameChange(
      ProductData data, String newName) async {
    final key = _productKey(data);
    final current = _productNameOverrides[key] ?? data.name;
    if (current == newName) {
      _showBanner('名称未变化');
      return;
    }
    final opName = await _ensureOperatorName();
    if (opName == null) {
      _showBanner('请填写操作员姓名后再更新名称', isError: true);
      return;
    }
    final hideLoading = _showBlockingLoading('正在同步商品名称…');
    final barcode =
        data.barcode.isNotEmpty ? data.barcode : _lastResult?.barcode ?? '';
    final errors = <String>[];
    var syncedCount = 0;
    for (final store in widget.configs) {
      try {
        final err = await widget.queryService.updateProductName(
          store,
          barcode,
          newName,
          productUid: data.uid?.toString(),
        );
        if (err == null) {
          syncedCount++;
        } else if (err != '未登录') {
          errors.add('${store.name}：$err');
        }
      } catch (e) {
        errors.add('${store.name}：$e');
      }
    }
    hideLoading();
    if (!mounted) return;
    // 本地立即生效：覆盖表 + 所选商品 + 所有门店卡片统一显示新名称
    setState(() {
      _productNameOverrides[key] = newName;
      if (_chosenProduct != null) {
        _chosenProduct = _chosenProduct!.copyWith(name: newName);
      }
      if (_lastResult != null) {
        final stores = Map<String, StoreStockResult>.from(_lastResult!.stores);
        for (final entry in stores.entries) {
          final old = entry.value;
          if (old.data == null) continue;
          stores[entry.key] = StoreStockResult(
            storeName: old.storeName,
            data: old.data!.copyWith(name: newName),
            error: old.error,
            ok: old.ok,
          );
        }
        _lastResult = MultiStoreResult(
          barcode: _lastResult!.barcode,
          stores: stores,
          elapsedSeconds: _lastResult!.elapsedSeconds,
          diagnostics: _lastResult!.diagnostics,
        );
      }
    });
    if (errors.isEmpty) {
      if (syncedCount == 0) {
        _showBanner('没有已登录的门店，无法同步', isError: true);
        return;
      }
      final descErrors = <String>[];
      for (final store in widget.configs) {
        final err = await widget.queryService.updateProductOperationNote(
          store,
          barcode,
          opName,
          '更新商品名称',
          productUid: data.uid?.toString(),
        );
        if (err != null && err != '未登录') {
          descErrors.add('${store.name}：$err');
        }
      }
      _showBanner(descErrors.isEmpty
          ? '商品名称已更新为「$newName」✓'
          : '商品名称已更新为「$newName」，描述未写入：${descErrors.join('；')}',
          isError: descErrors.isNotEmpty);
    } else {
      _showBanner('部分同步失败：${errors.join('；')}', isError: true);
    }
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
      widget.queryService.updateProductStock(sourceConfig, barcode, sourceNew,
          productUid: sourceResult.data?.uid?.toString()),
      widget.queryService.updateProductStock(targetConfig, barcode, targetNew,
          productUid: targetResult.data?.uid?.toString()),
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
    final visibleConfigs = widget.configs.where((c) => c.enabled).toList();
    final loggedInCount = _loginStatuses.values.where((v) => v).length;
    final totalCount = visibleConfigs.length;

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
          if (visibleConfigs.isEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(14, 0, 14, 10),
              child: Text(
                '暂无门店配置，请切换到「配置」Tab 添加',
                style: TextStyle(fontSize: 12, color: AppConstants.textSecondary),
              ),
            )
          else
            ...visibleConfigs.map((config) {
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

/// 缓存优先的商品图片：内存→磁盘→网络，未命中时后台下载后显示
class _CachedImage extends StatefulWidget {
  final String url;
  final BoxFit fit;
  final double? width;
  final double? height;
  final double radius;
  final int? decodeWidth;
  final int? decodeHeight;
  final Widget placeholder;
  const _CachedImage({
    required this.url,
    this.fit = BoxFit.cover,
    this.width,
    this.height,
    this.radius = 8,
    this.decodeWidth,
    this.decodeHeight,
    this.placeholder = const Icon(Icons.image_outlined,
        size: 28, color: AppConstants.textSecondary),
  });

  @override
  State<_CachedImage> createState() => _CachedImageState();
}

class _CachedImageState extends State<_CachedImage> {
  Uint8List? _bytes;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant _CachedImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _bytes = null;
      _done = false;
      _load();
    }
  }

  Future<void> _load() async {
    final full = widget.url.startsWith('http')
        ? widget.url
        : 'https://img.pospal.cn${widget.url}';
    final bytes = await ProductImageCache.loadBytes(full);
    if (!mounted) return;
    setState(() {
      _bytes = bytes;
      _done = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final child = _bytes != null
        ? Image.memory(_bytes!,
            fit: widget.fit,
            gaplessPlayback: true,
            cacheWidth: widget.decodeWidth,
            cacheHeight: widget.decodeHeight)
        : (_done
            ? widget.placeholder
            : const Center(
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ));
    return ClipRRect(
      borderRadius: BorderRadius.circular(widget.radius),
      child: SizedBox(
        width: widget.width,
        height: widget.height,
        child: child,
      ),
    );
  }
}


/// 多个门店中的同一个候选商品（含各门店库存，避免互相覆盖）
class _CandidateChoice {
  ProductData product;
  final Map<String, double?> storeStocks;
  final Map<String, String> storeNamesOfMatch;

  _CandidateChoice({
    required this.product,
    required this.storeStocks,
    required this.storeNamesOfMatch,
  });
}

/// 多条匹配商品选择弹窗
class _CandidatePickerDialog extends StatelessWidget {
  final String title;
  final List<_CandidateChoice> entries;
  final Map<String, String> storeNames;

  const _CandidatePickerDialog({
    required this.title,
    required this.entries,
    required this.storeNames,
  });

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(title, style: const TextStyle(fontSize: 16)),
      contentPadding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 420),
        child: ListView.builder(
          shrinkWrap: true,
          itemCount: entries.length,
          itemBuilder: (ctx, i) {
            final entry = entries[i];
            final p = entry.product;
            final spec = p.specification.isNotEmpty ? p.specification : '—';
            // 每个门店自己的库存，单独标注，避免只显示某一个门店的数据
            final stockParts = entry.storeStocks.entries.map((e) {
              final storeLabel = storeNames[e.key] ??
                  entry.storeNamesOfMatch[e.key] ??
                  e.key;
              final v = e.value;
              final stockStr = v != null ? _fmtStockNum(v) : '—';
              return '$storeLabel: $stockStr';
            }).toList();
            final stockText =
                stockParts.isEmpty ? '' : '库存：${stockParts.join('  ')}';
            return ListTile(
              dense: true,
              leading: const Icon(Icons.inventory_2_outlined,
                  color: AppConstants.primaryColor),
              title: Text(
                p.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
              ),
              subtitle: Text(
                [
                  '条码：${p.barcode}',
                  if (spec != '—') '规格：$spec',
                  if (stockText.isNotEmpty) stockText,
                ].join('  '),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12),
              ),
              trailing: const Icon(Icons.chevron_right, size: 20),
              onTap: () => Navigator.pop(ctx, entry),
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
      ],
    );
  }

  static String _fmtStockNum(double v) {
    if (v == v.roundToDouble()) return v.toInt().toString();
    return v.toStringAsFixed(2);
  }
}
