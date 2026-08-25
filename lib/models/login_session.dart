/// 登录会话状态
class LoginSession {
  final String cookie;
  final String via;
  final DateTime createdAt;

  LoginSession({
    required this.cookie,
    this.via = '',
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  bool get isValid => cookie.isNotEmpty;

  bool get isExpired {
    // 与 smart_eye_stock 一致：本地不按时间强制过期。
    // 银豹 OAuth（微信扫码）会话长期有效，是否过期由服务器端判断：
    // 请求被重定向到登录页时才提示重新登录。
    return DateTime.now().difference(createdAt).inDays > 365;
  }
}

/// 登录状态枚举
enum LoginStatus {
  /// 未登录
  notLoggedIn,

  /// 正在登录
  loggingIn,

  /// 已登录
  loggedIn,

  /// 登录失败
  failed,
}

/// 登录进度
class LoginProgress {
  final String message;
  final double percent;
  final bool isDone;
  final bool isError;

  const LoginProgress({
    this.message = '',
    this.percent = 0,
    this.isDone = false,
    this.isError = false,
  });
}
