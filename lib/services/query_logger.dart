import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import '../models/query_log.dart';

/// 查询诊断日志服务
///
/// 记录每次多店查询的每一步耗时，帮助诊断慢查询原因。
/// 日志保存在应用文档目录的 query_diag.log（JSON Lines 格式），
/// 最多保留最近 200 条记录。
class QueryLogger {
  static const _maxEntries = 200;
  static const _fileName = 'query_diag.log';

  List<QueryLogEntry> _entries = [];
  bool _loaded = false;

  static final QueryLogger _instance = QueryLogger._();
  factory QueryLogger() => _instance;
  QueryLogger._();

  /// 获取所有日志（最新在前）
  List<QueryLogEntry> get entries => List.unmodifiable(_entries);

  /// 慢查询统计
  int get slowCount => _entries.where((e) => e.isSlow).length;
  int get timeoutCount => _entries.where((e) => e.isTimeout).length;
  int get totalCount => _entries.length;

  /// 获取最近的统计摘要
  String get statsSummary {
    if (_entries.isEmpty) return '暂无查询记录';
    final recent = _entries.take(20).toList();
    final avgMs = recent.fold<int>(0, (sum, e) => sum + e.totalElapsedMs) ~/ recent.length;
    return '共 $totalCount 次查询 | 近20次平均: ${(avgMs / 1000).toStringAsFixed(1)}s | '
        '慢查询: $slowCount | 超时: $timeoutCount';
  }

  /// 从文件加载已有日志（公开，供 UI 主动刷新用）
  Future<void> ensureLoaded() async {
    if (_loaded) return;
    try {
      final file = await _getLogFile();
      if (await file.exists()) {
        final content = await file.readAsString();
        final lines = const LineSplitter().convert(content);
        _entries = lines
            .where((l) => l.trim().isNotEmpty)
            .map((l) {
              try {
                return QueryLogEntry.fromJson(jsonDecode(l) as Map<String, dynamic>);
              } catch (_) {
                return null;
              }
            })
            .whereType<QueryLogEntry>()
            .toList();
        // 最新在前
        _entries.sort((a, b) => b.timestamp.compareTo(a.timestamp));
      }
    } catch (_) {
      // 文件损坏或权限问题，从空开始
    }
    _loaded = true;
  }

  /// 添加一条诊断日志
  Future<void> add(QueryLogEntry entry) async {
    await ensureLoaded();
    _entries.insert(0, entry);

    // 裁剪到最大条数
    while (_entries.length > _maxEntries) {
      _entries.removeLast();
    }

    // 异步写入文件
    try {
      final file = await _getLogFile();
      final lines = _entries.map((e) => jsonEncode(e.toJson())).join('\n');
      await file.writeAsString(lines);
    } catch (_) {
      // 写入失败不影响查询
    }
  }

  /// 清空日志
  Future<void> clear() async {
    _entries.clear();
    try {
      final file = await _getLogFile();
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {}
  }

  /// 导出日志为文本文件并分享
  Future<void> exportAndShare() async {
    await ensureLoaded();
    final buf = StringBuffer();
    buf.writeln('现金 carry 查询诊断日志');
    buf.writeln('导出时间: ${DateTime.now().toIso8601String()}');
    buf.writeln('统计: $statsSummary');
    buf.writeln('');
    buf.writeln('═══ 最近查询记录（最新在前）═══');
    buf.writeln('');

    for (final entry in _entries) {
      buf.writeln(entry.fullReport);
      buf.writeln('');
    }

    try {
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/查询诊断_${DateTime.now().millisecondsSinceEpoch}.txt');
      await file.writeAsString(buf.toString());

      await Share.shareXFiles(
        [XFile(file.path)],
        subject: '现金carry查询诊断日志',
      );
    } catch (e) {
      debugPrint('导出日志失败: $e');
    }
  }

  /// 获取日志文件路径
  Future<File> _getLogFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/$_fileName');
  }

  /// 获取日志文件大小（用于UI显示）
  Future<int> getFileSize() async {
    try {
      final file = await _getLogFile();
      if (await file.exists()) {
        return await file.length();
      }
    } catch (_) {}
    return 0;
  }
}

/// 查询步骤计时器
///
/// 用于在 queryByBarcode 中记录每个步骤的耗时。
/// 使用方式：
/// ```dart
/// final timer = QueryStepTimer('门店名');
/// // ... do step 1 ...
/// timer.record('加载Cookie', 12);
/// // ... do step 2 ...
/// timer.record('获取userId', 45);
/// final diag = timer.done(success: true, error: null);
/// ```
class QueryStepTimer {
  final String storeName;
  final DateTime _startTime;
  int _lastStepStart;
  final List<StoreStepTiming> _steps = [];

  QueryStepTimer(this.storeName)
      : _startTime = DateTime.now(),
        _lastStepStart = DateTime.now().microsecondsSinceEpoch;

  /// 记录一个步骤的耗时
  void record(String step, {String? detail}) {
    final now = DateTime.now().microsecondsSinceEpoch;
    final elapsed = (now - _lastStepStart) ~/ 1000; // microseconds → ms
    _steps.add(StoreStepTiming(step: step, elapsedMs: elapsed, detail: detail));
    _lastStepStart = now;
  }

  /// 完成计时，返回诊断数据
  StoreQueryDiagnostics done({required bool success, String? error}) {
    final totalMs = DateTime.now().difference(_startTime).inMilliseconds;

    return StoreQueryDiagnostics(
      storeName: storeName,
      steps: List.unmodifiable(_steps),
      success: success,
      error: error,
      totalMs: totalMs,
    );
  }
}
