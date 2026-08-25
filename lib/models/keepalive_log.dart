import 'dart:convert';

class KeepAliveLogEntry {
  final DateTime timestamp;
  final String event;
  final String detail;
  final bool success;

  KeepAliveLogEntry({
    required this.timestamp,
    required this.event,
    required this.detail,
    required this.success,
  });

  Map<String, dynamic> toJson() => {
    'timestamp': timestamp.toIso8601String(),
    'event': event,
    'detail': detail,
    'success': success,
  };

  factory KeepAliveLogEntry.fromJson(Map<String, dynamic> json) => KeepAliveLogEntry(
    timestamp: DateTime.parse(json['timestamp'] as String),
    event: json['event'] as String,
    detail: json['detail'] as String? ?? '',
    success: json['success'] as bool? ?? false,
  );

  String get oneLine {
    final time = '${timestamp.hour.toString().padLeft(2, '0')}:${timestamp.minute.toString().padLeft(2, '0')}:${timestamp.second.toString().padLeft(2, '0')}';
    final icon = success ? 'OK' : 'FAIL';
    return '$time [$icon] $detail';
  }

  String get fullReport {
    final time = timestamp.toIso8601String();
    final status = success ? 'SUCCESS' : 'FAILED';
    return '[$time] $status | $event | $detail';
  }
}
