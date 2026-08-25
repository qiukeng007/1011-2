import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// 登录诊断日志服务（微信扫码登录 + 门店提取）
///
/// 记录登录流程每一步的关键信息（页面URL、Cookie来源、验证结果、
/// JS提取原始返回值、HTTP兜底结果等），写入应用文档目录 login_diag.log，
/// 供排查「iOS登录成功但门店获取不到」等问题。
class LoginDiagLogger {
  static final LoginDiagLogger _instance = LoginDiagLogger._();
  factory LoginDiagLogger() => _instance;
  LoginDiagLogger._();

  static const int _maxLines = 500;
  final List<String> _lines = [];

  /// 追加一条诊断日志（同时写文件，最多保留最近 500 行）
  Future<void> log(String msg) async {
    final ts = DateTime.now().toIso8601String();
    final line = '[$ts] $msg';
    _lines.add(line);
    debugPrint('[LoginDiag] $msg');
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/login_diag.log');
      final all = List<String>.from(_lines);
      if (all.length > _maxLines) {
        all.removeRange(0, all.length - _maxLines);
      }
      await file.writeAsString(all.join('\n'));
    } catch (_) {}
  }

  /// 读取日志全文（供复制到剪贴板）
  Future<String> readAll() async {
    if (_lines.isEmpty) {
      try {
        final dir = await getApplicationDocumentsDirectory();
        final file = File('${dir.path}/login_diag.log');
        if (await file.exists()) {
          return await file.readAsString();
        }
      } catch (_) {}
    }
    return _lines.join('\n');
  }

  /// 清空日志
  Future<void> clear() async {
    _lines.clear();
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/login_diag.log');
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {}
  }

  /// 导出为可分享的文本
  Future<String> exportText() async {
    final buf = StringBuffer();
    buf.writeln('现金carry 登录诊断日志');
    buf.writeln('导出时间: ${DateTime.now().toIso8601String()}');
    buf.writeln('');
    buf.writeln('═══ 日志内容 ═══');
    buf.writeln('');
    buf.writeln(await readAll());
    return buf.toString();
  }
}
