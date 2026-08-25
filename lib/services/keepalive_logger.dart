import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import '../models/keepalive_log.dart';
import 'foreground_service.dart';

class KeepAliveLogger {
  static const _maxEntries = 100;
  static const _fileName = 'keepalive.log';

  List<KeepAliveLogEntry> _entries = [];
  bool _loaded = false;

  static final KeepAliveLogger _instance = KeepAliveLogger._();
  factory KeepAliveLogger() => _instance;
  KeepAliveLogger._();

  List<KeepAliveLogEntry> get entries => List.unmodifiable(_entries);
  int get totalCount => _entries.length;
  int get failCount => _entries.where((e) => !e.success).length;

  String get statsSummary {
    if (_entries.isEmpty) return '';
    final recent = _entries.take(10).toList();
    final recentFails = recent.where((e) => !e.success).length;
    return '共 $totalCount 条 | 最近10条失败: $recentFails';
  }

  Future<void> ensureLoaded() async {
    if (_loaded) return;
    try {
      final file = await _getLogFile();
      if (await file.exists()) {
        final content = await file.readAsString();
        final lines = const LineSplitter().convert(content);
        _entries = lines.where((l) => l.trim().isNotEmpty).map((l) {
          try { return KeepAliveLogEntry.fromJson(jsonDecode(l) as Map<String, dynamic>); }
          catch (_) { return null; }
        }).whereType<KeepAliveLogEntry>().toList();
        _entries.sort((a, b) => b.timestamp.compareTo(a.timestamp));
      }
    } catch (_) {}
    _loaded = true;
  }

  Future<void> add(KeepAliveLogEntry entry) async {
    await ensureLoaded();
    _entries.insert(0, entry);
    while (_entries.length > _maxEntries) { _entries.removeLast(); }
    try {
      final file = await _getLogFile();
      await file.writeAsString(_entries.map((e) => jsonEncode(e.toJson())).join('\n'));
    } catch (_) {}
  }

  Future<void> clear() async {
    _entries.clear();
    try { final file = await _getLogFile(); if (await file.exists()) await file.delete(); } catch (_) {}
  }

  Future<void> exportAndShare() async {
    await ensureLoaded();
    final buf = StringBuffer();
    buf.writeln('银豹查询 - 保活日志');
    buf.writeln('导出时间: ${DateTime.now().toIso8601String()}');
    buf.writeln('');
    try {
      final running = await ForegroundService.isRunning();
      final notifEnabled = await ForegroundService.isNotificationEnabled();
      buf.writeln('▶ 当前状态:');
      buf.writeln('  前台服务: ${running ? '✓ 运行中' : '✗ 已停止'}');
      buf.writeln('  通知权限: ${notifEnabled ? '✓ 已授权' : '✗ 未授权 (请去设置>应用>银豹查询>通知 打开)'}');
      buf.writeln('');
    } catch (_) {
      buf.writeln('▶ 当前状态: 无法检测');
      buf.writeln('');
    }
    buf.writeln('统计: $statsSummary');
    buf.writeln('');
    buf.writeln('=== 记录（最新在前） ===');
    buf.writeln('');
    for (final entry in _entries) { buf.writeln(entry.fullReport); }
    try {
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/保活日志_${DateTime.now().millisecondsSinceEpoch}.txt');
      await file.writeAsString(buf.toString());
      await Share.shareXFiles([XFile(file.path)], subject: '银豹查询保活日志');
    } catch (e) { debugPrint('导出保活日志失败: $e'); }
  }

  Future<int> getFileSize() async {
    try { final file = await _getLogFile(); if (await file.exists()) return await file.length(); } catch (_) {}
    return 0;
  }

  Future<File> _getLogFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/$_fileName');
  }
}
