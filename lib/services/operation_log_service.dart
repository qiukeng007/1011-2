import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

/// A single operation record
class OperationLog {
  final String time;       // "06-21 14:30"
  final String store;      // "新店"
  final String action;     // "多店查询", "补货"
  final String barcode;
  final String? detail;    // extra info like query duration

  const OperationLog({
    required this.time,
    required this.store,
    required this.action,
    required this.barcode,
    this.detail,
  });

  Map<String, dynamic> toJson() => {
    'time': time, 'store': store, 'action': action,
    'barcode': barcode, if (detail != null) 'detail': detail,
  };

  factory OperationLog.fromJson(Map<String, dynamic> json) => OperationLog(
    time: json['time'] as String? ?? '',
    store: json['store'] as String? ?? '',
    action: json['action'] as String? ?? '',
    barcode: json['barcode'] as String? ?? '',
    detail: json['detail'] as String?,
  );
}

/// Stores and retrieves operation logs via SharedPreferences.
/// Logs are kept as a JSON array, newest first, capped at 200 entries.
class OperationLogService {
  static const _key = 'operation_logs';
  static const _maxEntries = 200;

  /// Append a log entry
  static Future<void> add({
    required String store,
    required String action,
    required String barcode,
    String? detail,
  }) async {
    final now = DateTime.now();
    final time = '${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')} '
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';

    final entry = OperationLog(time: time, store: store, action: action, barcode: barcode, detail: detail);
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key) ?? '[]';
    final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
    list.insert(0, entry.toJson());
    if (list.length > _maxEntries) list.removeRange(_maxEntries, list.length);
    await prefs.setString(_key, jsonEncode(list));
  }

  /// Get all logs, newest first
  static Future<List<OperationLog>> getAll() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key) ?? '[]';
    final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
    return list.map((e) => OperationLog.fromJson(e)).toList();
  }

  /// Clear all logs
  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, '[]');
  }
}
