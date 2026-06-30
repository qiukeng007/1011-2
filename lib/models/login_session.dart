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
    // Cookie 有效期约 7 天
    return DateTime.now().difference(createdAt).inDays > 7;
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
