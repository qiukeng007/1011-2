import 'dart:io' show Platform;
import 'package:flutter/services.dart';

/// Android 前台服务控制（后台保活）
/// 通过 MethodChannel 与原生 KeepAliveService 通信
class ForegroundService {
  static const _channel = MethodChannel('com.example.pospal_stock_app/foreground');

  /// 启动前台服务（App 进入后台时调用）
  static Future<bool> start() async {
    if (!Platform.isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('startService') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 停止前台服务（App 回到前台时调用）
  static Future<bool> stop() async {
    if (!Platform.isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('stopService') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 查询服务是否在运行
  static Future<bool> isRunning() async {
    if (!Platform.isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('isRunning') ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> isNotificationEnabled() async {
    if (!Platform.isAndroid) return true;
    try {
      return await _channel.invokeMethod<bool>('isNotificationEnabled') ?? false;
    } catch (_) { return false; }
  }
}
