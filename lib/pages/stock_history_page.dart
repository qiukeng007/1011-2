import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
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
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DataTable(
            headingRowColor: WidgetStateProperty.all(AppConstants.bgColor),
            columnSpacing: 8,
            dataRowMinHeight: 32,
            dataRowMaxHeight: 44,
            columns: const [
              DataColumn(label: Text('#', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600))),
              DataColumn(label: Text('时间', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600))),
              DataColumn(label: Text('类型', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600))),
              DataColumn(label: Text('变动', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600))),
              DataColumn(label: Text('库存', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600))),
              DataColumn(label: Text('操作人', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600))),
              DataColumn(label: Text('备注', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600))),
            ],
            rows: r.records.map((rec) {
              final chg = rec.stockChange;
              final chgText = chg == null
                  ? '-'
                  : (chg >= 0 ? '+${_fmtNum(chg)}' : _fmtNum(chg));
              final chgColor = chg == null
                  ? AppConstants.textSecondary
                  : (chg >= 0
                      ? const Color(0xFF28a745)
                      : AppConstants.errorColor);
              return DataRow(cells: [
                DataCell(Text('${rec.index}', style: const TextStyle(fontSize: 11))),
                DataCell(Text(rec.time, style: const TextStyle(fontSize: 11))),
                DataCell(Text(rec.changeType, style: const TextStyle(fontSize: 11))),
                DataCell(Text(chgText, style: TextStyle(fontSize: 11, color: chgColor, fontWeight: FontWeight.w600))),
                DataCell(Text(rec.correctedStock == null ? '-' : _fmtNum(rec.correctedStock!), style: const TextStyle(fontSize: 11))),
                DataCell(Text(rec.operator, style: const TextStyle(fontSize: 11))),
                DataCell(ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 120),
                  child: Text(rec.remark.isEmpty ? '-' : rec.remark,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11)),
                )),
              ]);
            }).toList(),
          ),
        ),
      ]),
    );
  }

  String _fmtNum(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toString();
}
