import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../utils/constants.dart';
import '../services/operation_log_service.dart';
import '../services/query_logger.dart';

class RecordsPage extends StatefulWidget {
  const RecordsPage({super.key});

  @override
  State<RecordsPage> createState() => _RecordsPageState();
}

class _RecordsPageState extends State<RecordsPage> {
  List<OperationLog> _logs = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final logs = await OperationLogService.getAll();
    if (mounted) setState(() { _logs = logs; _loading = false; });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('操作记录', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
        actions: [
          if (_logs.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_outline, size: 20),
              tooltip: '清空记录',
              onPressed: () async {
                final ok = await showDialog<bool>(context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('清空操作记录'),
                    content: const Text('确定要清空所有操作记录吗？'),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
                      TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('清空', style: TextStyle(color: AppConstants.errorColor))),
                    ],
                  ),
                );
                if (ok == true) {
                  await OperationLogService.clear();
                  _load();
                }
              },
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _logs.isEmpty
              ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.history, size: 48, color: AppConstants.textSecondary),
                  const SizedBox(height: 12),
                  const Text('暂无操作记录', style: TextStyle(color: AppConstants.textSecondary)),
                  const SizedBox(height: 4),
                  const Text('搜索商品、补货等操作会自动记录', style: TextStyle(fontSize: 12, color: AppConstants.textSecondary)),
                ]))
              : ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: _logs.length,
                  itemBuilder: (_, i) {
                    final log = _logs[i];
                    return Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      child: InkWell(
                        onTap: () {
                          Clipboard.setData(ClipboardData(text: log.barcode));
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('已复制: ${log.barcode}', style: const TextStyle(fontSize: 13)),
                              duration: const Duration(seconds: 1), behavior: SnackBarBehavior.floating, width: 300),
                          );
                        },
                        borderRadius: BorderRadius.circular(AppConstants.radiusSm),
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // Row 1: action + store + time
                              Row(children: [
                                _actionIcon(log.action),
                                const SizedBox(width: 8),
                                Text(log.action, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                                const SizedBox(width: 8),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                                  decoration: BoxDecoration(
                                    color: AppConstants.primaryColor.withValues(alpha: 0.1),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Text(log.store, style: const TextStyle(fontSize: 10, color: AppConstants.primaryColor)),
                                ),
                                const Spacer(),
                                Text(log.time, style: const TextStyle(fontSize: 11, color: AppConstants.textSecondary)),
                              ]),
                              const SizedBox(height: 6),
                              // Row 2: barcode (clickable to copy)
                              Row(children: [
                                const Icon(Icons.qr_code, size: 14, color: AppConstants.textSecondary),
                                const SizedBox(width: 4),
                                Expanded(child: Text('${log.barcode}  📋点击复制',
                                  style: const TextStyle(fontSize: 12, color: AppConstants.textSecondary))),
                              ]),
                              // Row 3: detail (if present)
                              if (log.detail != null && log.detail!.isNotEmpty) ...[
                                const SizedBox(height: 4),
                                Text(log.detail!, style: const TextStyle(fontSize: 11, color: AppConstants.textSecondary)),
                              ],
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
      // 导出诊断日志按钮
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => QueryLogger().exportAndShare(),
        icon: const Icon(Icons.bug_report, size: 18),
        label: const Text('导出诊断', style: TextStyle(fontSize: 12)),
        backgroundColor: Colors.orange,
        foregroundColor: Colors.white,
        elevation: 2,
      ),
    );
  }

  Widget _actionIcon(String action) {
    IconData icon;
    Color color;
    if (action.contains('查询')) { icon = Icons.search; color = AppConstants.primaryColor; }
    else if (action.contains('补货')) { icon = Icons.add_shopping_cart; color = AppConstants.warningColor; }
    else if (action.contains('调货')) { icon = Icons.swap_horiz; color = AppConstants.successColor; }
    else if (action.contains('打印')) { icon = Icons.print; color = AppConstants.primaryColor; }
    else { icon = Icons.circle; color = AppConstants.textSecondary; }
    return Icon(icon, size: 20, color: color);
  }
}
