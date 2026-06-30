/// 单个门店的每步耗时记录
class StoreStepTiming {
  final String step;
  final int elapsedMs;
  final String? detail;

  const StoreStepTiming({
    required this.step,
    required this.elapsedMs,
    this.detail,
  });

  Map<String, dynamic> toJson() => {
        'step': step,
        'elapsedMs': elapsedMs,
        if (detail != null) 'detail': detail,
      };

  factory StoreStepTiming.fromJson(Map<String, dynamic> json) => StoreStepTiming(
        step: json['step'] as String? ?? '',
        elapsedMs: json['elapsedMs'] as int? ?? 0,
        detail: json['detail'] as String?,
      );
}

/// 单个门店的完整诊断信息
class StoreQueryDiagnostics {
  final String storeName;
  final List<StoreStepTiming> steps;
  final bool success;
  final String? error;
  final int totalMs;

  const StoreQueryDiagnostics({
    required this.storeName,
    required this.steps,
    required this.success,
    this.error,
    required this.totalMs,
  });

  Map<String, dynamic> toJson() => {
        'storeName': storeName,
        'steps': steps.map((s) => s.toJson()).toList(),
        'success': success,
        if (error != null) 'error': error,
        'totalMs': totalMs,
      };

  factory StoreQueryDiagnostics.fromJson(Map<String, dynamic> json) {
    return StoreQueryDiagnostics(
      storeName: json['storeName'] as String? ?? '',
      steps: (json['steps'] as List<dynamic>?)
              ?.map((s) => StoreStepTiming.fromJson(s as Map<String, dynamic>))
              .toList() ??
          [],
      success: json['success'] as bool? ?? false,
      error: json['error'] as String?,
      totalMs: json['totalMs'] as int? ?? 0,
    );
  }

  /// 生成人类可读的摘要
  String get summary {
    final buf = StringBuffer();
    buf.writeln('[$storeName] ${success ? "✓" : "✗"} 总耗时: ${totalMs}ms');
    for (final s in steps) {
      final bar = _bar(s.elapsedMs, totalMs);
      buf.writeln('  $bar ${s.step}: ${s.elapsedMs}ms${s.detail != null ? " (${s.detail})" : ""}');
    }
    if (error != null) buf.writeln('  错误: $error');
    return buf.toString();
  }

  static String _bar(int ms, int total) {
    if (total == 0) return '▕';
    final ratio = ms / total;
    if (ratio > 0.5) return '███';
    if (ratio > 0.2) return '██▁';
    if (ratio > 0.05) return '█▁▁';
    return '▁▁▁';
  }
}

/// 一次完整的多店查询诊断记录
class QueryLogEntry {
  final DateTime timestamp;
  final String barcode;
  final int storeCount;
  final List<StoreQueryDiagnostics> stores;
  final int totalElapsedMs;
  final bool reLoginTriggered;
  final int? reLoginMs;
  final String? slowestStore;
  final int? slowestStoreMs;

  const QueryLogEntry({
    required this.timestamp,
    required this.barcode,
    required this.storeCount,
    required this.stores,
    required this.totalElapsedMs,
    this.reLoginTriggered = false,
    this.reLoginMs,
    this.slowestStore,
    this.slowestStoreMs,
  });

  /// 是否为慢查询（>5秒）
  bool get isSlow => totalElapsedMs > 5000;

  /// 是否超时（>10秒）
  bool get isTimeout => totalElapsedMs > 10000;

  Map<String, dynamic> toJson() => {
        'timestamp': timestamp.toIso8601String(),
        'barcode': barcode,
        'storeCount': storeCount,
        'stores': stores.map((s) => s.toJson()).toList(),
        'totalElapsedMs': totalElapsedMs,
        'reLoginTriggered': reLoginTriggered,
        if (reLoginMs != null) 'reLoginMs': reLoginMs,
        if (slowestStore != null) 'slowestStore': slowestStore,
        if (slowestStoreMs != null) 'slowestStoreMs': slowestStoreMs,
      };

  factory QueryLogEntry.fromJson(Map<String, dynamic> json) {
    final stores = (json['stores'] as List<dynamic>?)
            ?.map((s) =>
                StoreQueryDiagnostics.fromJson(s as Map<String, dynamic>))
            .toList() ??
        [];
    return QueryLogEntry(
      timestamp: DateTime.parse(json['timestamp'] as String),
      barcode: json['barcode'] as String? ?? '',
      storeCount: json['storeCount'] as int? ?? 0,
      stores: stores,
      totalElapsedMs: json['totalElapsedMs'] as int? ?? 0,
      reLoginTriggered: json['reLoginTriggered'] as bool? ?? false,
      reLoginMs: json['reLoginMs'] as int?,
      slowestStore: json['slowestStore'] as String?,
      slowestStoreMs: json['slowestStoreMs'] as int?,
    );
  }

  /// 人类可读的完整诊断报告
  String get fullReport {
    final buf = StringBuffer();
    buf.writeln('═══════════════════════════════════');
    buf.writeln('查询诊断报告');
    buf.writeln('时间: ${_fmtTime(timestamp)}');
    buf.writeln('条码: $barcode');
    buf.writeln('门店数: $storeCount');
    buf.writeln('总耗时: ${totalElapsedMs}ms (${(totalElapsedMs / 1000).toStringAsFixed(1)}秒)');
    if (isSlow) buf.writeln('⚠ 慢查询 (>5秒)');
    if (isTimeout) buf.writeln('🚫 严重超时 (>10秒)');
    if (reLoginTriggered) {
      buf.write('🔄 触发了重新登录');
      if (reLoginMs != null) buf.writeln(' (重登耗时: ${reLoginMs}ms)');
      else buf.writeln();
    }
    if (slowestStore != null) {
      buf.writeln('最慢门店: $slowestStore (${slowestStoreMs}ms)');
    }
    buf.writeln('───────────────────────────────');
    for (final s in stores) {
      buf.writeln(s.summary);
    }
    buf.writeln('═══════════════════════════════════');
    return buf.toString();
  }

  /// 单行摘要（用于列表展示）
  String get oneLine {
    final icon = isTimeout ? '🚫' : (isSlow ? '⚠' : '✓');
    final relogin = reLoginTriggered ? ' 🔄' : '';
    return '$icon ${_fmtTime(timestamp)} | $barcode | ${(totalElapsedMs / 1000).toStringAsFixed(1)}s$relogin';
  }

  static String _fmtTime(DateTime dt) {
    return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}:${dt.second.toString().padLeft(2, '0')}';
  }
}
