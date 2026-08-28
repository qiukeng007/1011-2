import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'detail_webview_page.dart';
import '../models/store_config.dart';
import '../models/stock_history.dart';
import '../services/query_service.dart';
import '../utils/constants.dart';

/// 商品库存变动明细页（参考智能眼：按门店查询 /Inventory/LoadStockChangeHistory）
class StockHistoryPage extends StatefulWidget {
  final List<StoreConfig> configs;
  final QueryService queryService;
  final String barcode;
  final String productName;

  const StockHistoryPage({
    super.key,
    required this.configs,
    required this.queryService,
    required this.barcode,
    required this.productName,
  });

  @override
  State<StockHistoryPage> createState() => _StockHistoryPageState();
}

class _StockHistoryPageState extends State<StockHistoryPage> {
  // 备注链接点击手势（dispose 时统一释放）
  final List<TapGestureRecognizer> _recognizers = [];
  bool _loading = false;
  String? _error;
  List<StockHistoryResult> _results = [];
  int _selectedDays = 30;
  DateTime? _customStart;
  DateTime? _customEnd;

  // 快捷日期选项（选择自定义后 _selectedDays = -1）
  static const _dayOptions = [7, 30, 90];

  // 上次选择的时间范围持久化（下次进入自动沿用）
  static const _prefsDaysKey = 'stock_history_days';
  static const _prefsCustomStartKey = 'stock_history_custom_start';
  static const _prefsCustomEndKey = 'stock_history_custom_end';

  String _rangeLabel(int days) => days == 0 ? '全部' : '$days天';

  @override
  void initState() {
    super.initState();
    _loadSavedRange();
  }

  @override
  void dispose() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
    super.dispose();
  }

  /// 读取上次选择的时间范围，读完后自动查询
  Future<void> _loadSavedRange() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedDays = prefs.getInt(_prefsDaysKey);
      if (savedDays != null &&
          (savedDays == -1 || savedDays == 0 || _dayOptions.contains(savedDays))) {
        _selectedDays = savedDays;
      }
      if (_selectedDays == -1) {
        final s = prefs.getString(_prefsCustomStartKey);
        final e = prefs.getString(_prefsCustomEndKey);
        if (s != null) _customStart = DateTime.tryParse(s);
        if (e != null) _customEnd = DateTime.tryParse(e);
      }
    } catch (_) {}
    if (!mounted) return;
    _search();
  }

  /// 保存当前选择的时间范围
  Future<void> _saveRange() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_prefsDaysKey, _selectedDays);
      if (_selectedDays == -1) {
        await prefs.setString(
            _prefsCustomStartKey, _customStart?.toIso8601String() ?? '');
        await prefs.setString(
            _prefsCustomEndKey, _customEnd?.toIso8601String() ?? '');
      }
    } catch (_) {}
  }

  String _fmt(DateTime dt, String time) =>
      '${dt.year}.${dt.month.toString().padLeft(2, '0')}.${dt.day.toString().padLeft(2, '0')} $time';

  Future<void> _search() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
      _results = [];
    });
    try {
      final now = DateTime.now();
      final start = _selectedDays == -1
          ? _customStart
          : (_selectedDays == 0
              ? null
              : now.subtract(Duration(days: _selectedDays)));
      final end = _selectedDays == -1 ? (_customEnd ?? now) : now;
      // 结果按配置门店顺序固定（首页搜索页从左到右，这里从上到下）
      final resultMap = <String, StockHistoryResult>{};
      await Future.wait(widget.configs.map((store) async {
        final r = await widget.queryService.fetchStockHistory(
          store,
          widget.barcode,
          startTime: start == null ? null : _fmt(start, '00:00:00'),
          endTime: _fmt(end, '23:59:59'),
        );
        resultMap[store.name] = r;
      }));
      final results = <StockHistoryResult>[];
      for (final store in widget.configs) {
        final r = resultMap[store.name];
        if (r != null) results.add(r);
      }
      if (!mounted) return;
      setState(() {
        _results = results;
        _loading = false;
        if (results.every((r) => r.error != null)) {
          _error = results.firstWhere((r) => r.error != null).error;
        }
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '$e';
          _loading = false;
        });
      }
    }
  }

  /// 弹出日期范围选择器，选完自动查询
  Future<void> _pickCustomRange() async {
    final now = DateTime.now();
    final range = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: now,
      initialDateRange: DateTimeRange(
        start: _customStart ?? now.subtract(const Duration(days: 30)),
        end: _customEnd ?? now,
      ),
      helpText: '选择变动明细时间范围',
      saveText: '确定',
    );
    if (range == null || !mounted) return;
    setState(() {
      _customStart =
          DateTime(range.start.year, range.start.month, range.start.day);
      _customEnd = DateTime(range.end.year, range.end.month, range.end.day);
      _selectedDays = -1;
    });
    _saveRange();
    _search();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.productName.isEmpty ? '库存变动明细' : widget.productName,
          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
        ),
      ),
      body: Column(
        children: [
          // 日期快捷选择
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: Row(
              children: [
                const Icon(Icons.date_range,
                    size: 16, color: AppConstants.textSecondary),
                const SizedBox(width: 6),
                ..._dayOptions.map((d) => Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: ChoiceChip(
                        label: Text(_rangeLabel(d),
                            style: const TextStyle(fontSize: 12)),
                        selected: _selectedDays == d,
                        onSelected: _loading
                            ? null
                            : (_) {
                                setState(() => _selectedDays = d);
                                _saveRange();
                                _search();
                              },
                        visualDensity: VisualDensity.compact,
                      ),
                    )),
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: ChoiceChip(
                    label: const Text('自定义',
                        style: TextStyle(fontSize: 12)),
                    selected: _selectedDays == -1,
                    onSelected: _loading ? null : (_) => _pickCustomRange(),
                    visualDensity: VisualDensity.compact,
                  ),
                ),
              ],
            ),
          ),
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline,
                  size: 48, color: AppConstants.errorColor),
              const SizedBox(height: 8),
              Text(_error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      fontSize: 13, color: AppConstants.errorColor)),
              const SizedBox(height: 12),
              OutlinedButton(onPressed: _search, child: const Text('重试')),
            ],
          ),
        ),
      );
    }
    if (_results.isEmpty) {
      return const Center(
        child: Text('暂无变动记录',
            style: TextStyle(color: AppConstants.textSecondary)),
      );
    }
    if (_results.every((r) => r.records.isEmpty && r.error == null)) {
      return const Center(
        child: Text('该条码暂无变动记录',
            style: TextStyle(color: AppConstants.textSecondary)),
      );
    }
    return ListView(
      padding: const EdgeInsets.all(12),
      children: _results.map(_buildStoreCard).toList(),
    );
  }

  Widget _buildStoreCard(StockHistoryResult r) {
    if (r.error != null) {
      return Card(
        margin: const EdgeInsets.only(bottom: 12),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(children: [
            const Icon(Icons.store, size: 16, color: AppConstants.textSecondary),
            const SizedBox(width: 6),
            Text(r.storeName,
                style:
                    const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
            const Spacer(),
            Text(r.error!,
                style:
                    const TextStyle(fontSize: 12, color: AppConstants.errorColor)),
          ]),
        ),
      );
    }
    if (r.records.isEmpty) {
      return Card(
        margin: const EdgeInsets.only(bottom: 12),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(children: [
            const Icon(Icons.store, size: 16, color: AppConstants.textSecondary),
            const SizedBox(width: 6),
            Text(r.storeName,
                style:
                    const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
            const Spacer(),
            const Text('无变动记录',
                style:
                    TextStyle(fontSize: 12, color: AppConstants.textSecondary)),
          ]),
        ),
      );
    }
    final store = _findStore(r.storeName);
    final baseUrl = (store?.baseUrl ?? '').replaceAll(RegExp(r'/$'), '');
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: AppConstants.primaryColor.withValues(alpha: 0.08),
            borderRadius: const BorderRadius.vertical(
                top: Radius.circular(AppConstants.radiusSm)),
          ),
          child: Row(children: [
            const Icon(Icons.store, size: 16, color: AppConstants.primaryColor),
            const SizedBox(width: 6),
            Text(r.storeName,
                style:
                    const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
            const Spacer(),
            Text('${r.records.length} 条',
                style: TextStyle(
                    fontSize: 12,
                    color: AppConstants.primaryColor.withValues(alpha: 0.7))),
          ]),
        ),
        // 内容区可横向滚动，右侧「详细」按钮列固定不动
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(children: [
                      _tableCell(_wIndex, '#', isHeader: true),
                      _tableCell(_wTime, '时间', isHeader: true),
                      _tableCell(_wType, '类型', isHeader: true),
                      _tableCell(_wChange, '变动', isHeader: true),
                      _tableCell(_wStock, '库存', isHeader: true),
                      _tableCell(_wOperator, '操作人', isHeader: true),
                      _tableCell(_wRemark, '备注', isHeader: true),
                    ]),
                    for (final rec in r.records) _buildHistoryRow(rec, store),
                  ],
                ),
              ),
            ),
            // 固定「详细」列（不随内容横向滚动）
            Container(
              width: _wAction,
              decoration: const BoxDecoration(
                border: Border(
                  left: BorderSide(color: Color(0xFFBDBDBD)),
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _tableCell(_wAction, '操作',
                      isHeader: true, showLeftBorder: false),
                  for (final rec in r.records)
                    _tableCell(
                      _wAction,
                      null,
                      showLeftBorder: false,
                      child: _detailButton(rec, baseUrl, store),
                    ),
                ],
              ),
            ),
          ],
        ),
      ]),
    );
  }

  // 表格布局参数
  static const double _rowH = 40;
  static const double _wIndex = 38;
  static const double _wTime = 122;
  static const double _wType = 76;
  static const double _wChange = 54;
  static const double _wStock = 58;
  static const double _wOperator = 80;
  static const double _wRemark = 150;
  static const double _wAction = 62;
  static const Color _gridLine = Color(0xFFE0E0E0);

  /// 表格单元格（固定行高，带网格线）
  Widget _tableCell(
    double width,
    String? text, {
    bool isHeader = false,
    bool showLeftBorder = true,
    TextStyle? style,
    Widget? child,
  }) {
    return Container(
      width: width,
      height: _rowH,
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      decoration: BoxDecoration(
        color: isHeader ? AppConstants.bgColor : null,
        border: Border(
          left: showLeftBorder
              ? const BorderSide(color: _gridLine)
              : BorderSide.none,
          right: const BorderSide(color: _gridLine),
          bottom: const BorderSide(color: _gridLine),
        ),
      ),
      child: child ??
          (text == null
              ? null
              : Text(text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: style ??
                      TextStyle(
                        fontSize: 11,
                        fontWeight: isHeader
                            ? FontWeight.w600
                            : FontWeight.normal,
                        color: AppConstants.textPrimary,
                      ))),
    );
  }

  /// 单条变动记录行
  Widget _buildHistoryRow(StockChangeRecord rec, StoreConfig? store) {
    final chg = rec.stockChange;
    final chgText = chg == null
        ? '-'
        : (chg >= 0 ? '+${_fmtNum(chg)}' : _fmtNum(chg));
    final chgColor = chg == null
        ? AppConstants.textSecondary
        : (chg >= 0
            ? const Color(0xFF28a745)
            : AppConstants.errorColor);
    return Row(children: [
      _tableCell(_wIndex, '${rec.index}'),
      _tableCell(_wTime, rec.time),
      _tableCell(_wType, rec.changeType),
      _tableCell(_wChange, chgText,
          style: TextStyle(
              fontSize: 11,
              color: chgColor,
              fontWeight: FontWeight.w600)),
      _tableCell(
          _wStock,
          rec.correctedStock == null ? '-' : _fmtNum(rec.correctedStock!)),
      _tableCell(_wOperator, rec.operator),
      _tableCell(
        _wRemark,
        null,
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text.rich(
            TextSpan(children: _remarkSpans(
                rec.remark, const TextStyle(fontSize: 11), store)),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ),
    ]);
  }

  /// 「详细」按钮：打开备注中的详情链接（货流单/销售单等）
  Widget _detailButton(StockChangeRecord rec, String baseUrl, StoreConfig? store) {
    final url = _extractDetailUrl(rec, baseUrl, store?.storeId ?? '');
    if (url == null) {
      return const Text('无详情',
          style: TextStyle(
              fontSize: 11, color: AppConstants.textSecondary));
    }
    return GestureDetector(
      onTap: () => _openDetail(store, url),
      behavior: HitTestBehavior.opaque,
      child: const Center(
        child: Text('详细',
            style: TextStyle(
                fontSize: 12,
                color: Color(0xFF1565C0),
                fontWeight: FontWeight.w600,
                decoration: TextDecoration.underline)),
      ),
    );
  }

  /// 从备注/记录提取详情链接：
  /// 1. 优先解析 URL（Markdown / 裸 URL / HTML，含相对路径）；
  /// 2. 没有 URL 时用接口返回的单号构造：销售 → 销售单据，其他 → 货流详情；
  /// 3. 最后尝试从备注里提取各类单号（货单号/销售单号/流水号等）
  String? _extractDetailUrl(StockChangeRecord rec, String baseUrl, String storeId) {
    final remark = rec.remark;
    if (remark.trim().isNotEmpty) {
      final text = _preprocessRemark(remark);
      // Markdown 链接（绝对或相对）
      final mdRe = RegExp(r'\[[^\]]+\]\(([^)]+)\)');
      for (final m in mdRe.allMatches(text)) {
        final abs = _absUrl(m.group(1)!.trim(), baseUrl);
        if (abs != null) return abs;
      }
      // 裸 URL（绝对或相对路径）
      final urlRe = RegExp(
          r'(https?://[^\s<>"()\[\]]+|/[A-Za-z][^\s<>"()\[\]]*)');
      for (final m in urlRe.allMatches(text)) {
        final abs = _absUrl(m.group(1)!.trim(), baseUrl);
        if (abs != null) return abs;
      }
    }
    // 接口返回的单号/流水号
    final sn = rec.sn;
    if (sn != null && sn.isNotEmpty && baseUrl.isNotEmpty) {
      return _detailUrlFor(rec.changeType, baseUrl, storeId, sn);
    }
    // 从备注提取各类单号
    final numRe = RegExp(
        r'(?:货单号|销售单号|流水号|单号|订单号|票号|sn)[：:=\s]*(\d{6,})',
        caseSensitive: false);
    final nm = numRe.firstMatch(remark);
    if (nm != null && baseUrl.isNotEmpty) {
      return _detailUrlFor(rec.changeType, baseUrl, storeId, nm.group(1)!);
    }
    return null;
  }

  /// 按变动类型构造详情地址：
  /// 货流类 → 货流详情；销售/退货等其他单据 → 销售单据（storeSn=门店ID.流水号）
  String _detailUrlFor(String changeType, String baseUrl, String storeId, String sn) {
    if (changeType.contains('货流')) {
      return '$baseUrl/StockFlow/StockFlowList?sn=$sn';
    }
    if (storeId.isNotEmpty) {
      return '$baseUrl/Report/Tickets?storeSn=$storeId.$sn';
    }
    return '$baseUrl/Report/Tickets?sn=$sn';
  }

  /// 相对路径拼上后台地址；绝对地址原样返回
  String? _absUrl(String url, String baseUrl) {
    if (url.startsWith('http://') || url.startsWith('https://')) {
      return url;
    }
    if (url.startsWith('/') && baseUrl.isNotEmpty) {
      return '$baseUrl$url';
    }
    return null;
  }

  /// 按门店名称查找配置
  StoreConfig? _findStore(String storeName) {
    for (final c in widget.configs) {
      if (c.name == storeName) return c;
    }
    return null;
  }

  /// 把备注文本转成可点击链接的富文本
  /// 支持 [详细>>](url)（Markdown）、裸 URL、<a href="url">label</a>（HTML）三种格式
  List<TextSpan> _remarkSpans(String remark, TextStyle baseStyle, StoreConfig? store) {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
    if (remark.trim().isEmpty) {
      return [TextSpan(text: '-', style: baseStyle)];
    }
    final text = _preprocessRemark(remark);
    final spans = <TextSpan>[];
    // Markdown 链接 或 裸 URL
    final re = RegExp(
        r'\[([^\]]+)\]\((https?://[^)\s]+\))|(https?://[^\s<>"()\[\]]+)');
    var last = 0;
    for (final m in re.allMatches(text)) {
      if (m.start > last) {
        spans.add(TextSpan(text: text.substring(last, m.start), style: baseStyle));
      }
      final label = (m.group(1) ?? m.group(3))!;
      final url = (m.group(2) ?? m.group(3))!;
      final recognizer =
          TapGestureRecognizer()..onTap = () => _openDetail(store, url);
      _recognizers.add(recognizer);
      spans.add(TextSpan(
        text: label,
        recognizer: recognizer,
        style: baseStyle.copyWith(
          color: const Color(0xFF1565C0),
          decoration: TextDecoration.underline,
          decorationColor: const Color(0xFF1565C0),
          fontWeight: FontWeight.w600,
        ),
      ));
      last = m.end;
    }
    if (last < text.length) {
      spans.add(TextSpan(text: text.substring(last), style: baseStyle));
    }
    return spans;
  }

  /// 把 HTML 链接转换成 Markdown 链接，便于统一解析
  String _preprocessRemark(String remark) {
    return remark.replaceAllMapped(
      RegExp(r'<a\s+[^>]*href="([^"]+)"[^>]*>(.*?)</a>',
          caseSensitive: false),
      (m) {
        final label = m.group(2)!
            .replaceAll(RegExp(r'<[^>]+>'), '')
            .replaceAll('&gt;', '>')
            .replaceAll('&lt;', '<')
            .replaceAll('&amp;', '&');
        return '[$label](${m.group(1)})';
      },
    );
  }

  /// 在 APP 内打开详情页（WebView 注入门店 Cookie，保持登录状态）
  Future<void> _openDetail(StoreConfig? store, String url) async {
    String? cookie;
    if (store != null) {
      try {
        cookie = await widget.queryService.getCookie(store.storeKey);
      } catch (_) {}
    }
    if (!mounted) return;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => DetailWebViewPage(
        url: url,
        cookie: cookie,
        title: '详情',
      ),
    ));
  }

  String _fmtNum(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toString();
}
