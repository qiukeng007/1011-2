import 'package:flutter/material.dart';
import '../models/login_session.dart';
import '../utils/constants.dart';

/// 登录按钮组件
class LoginButton extends StatelessWidget {
  final String storeName;
  final LoginStatus status;
  final LoginProgress? progress;
  final VoidCallback onLogin;
  final VoidCallback? onLogout;

  const LoginButton({
    super.key,
    required this.storeName,
    required this.status,
    this.progress,
    required this.onLogin,
    this.onLogout,
  });

  @override
  Widget build(BuildContext context) {
    switch (status) {
      case LoginStatus.notLoggedIn:
        return _buildButton(
          label: '登录 $storeName',
          color: AppConstants.primaryColor,
          icon: Icons.login,
          onTap: onLogin,
        );
      case LoginStatus.loggingIn:
        return _buildProgressButton();
      case LoginStatus.loggedIn:
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildButton(
              label: '已登录',
              color: AppConstants.successColor,
              icon: Icons.check_circle,
              onTap: null,
            ),
            const SizedBox(width: 4),
            if (onLogout != null)
              _buildButton(
                label: '退出',
                color: AppConstants.errorColor,
                icon: Icons.logout,
                onTap: onLogout!,
                compact: true,
              ),
          ],
        );
      case LoginStatus.failed:
        return _buildButton(
          label: '登录失败，重试',
          color: AppConstants.errorColor,
          icon: Icons.error_outline,
          onTap: onLogin,
        );
    }
  }

  Widget _buildButton({
    required String label,
    required Color color,
    required IconData icon,
    required VoidCallback? onTap,
    bool compact = false,
  }) {
    return SizedBox(
      height: compact ? 32 : 36,
      child: TextButton.icon(
        onPressed: onTap,
        icon: Icon(icon, size: compact ? 14 : 16),
        label: Text(
          label,
          style: TextStyle(fontSize: compact ? 11 : 13),
        ),
        style: TextButton.styleFrom(
          foregroundColor: color,
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 8 : 12,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppConstants.radiusSm),
            side: BorderSide(color: color.withValues(alpha: 0.3)),
          ),
        ),
      ),
    );
  }

  Widget _buildProgressButton() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppConstants.radiusSm),
        border: Border.all(color: AppConstants.primaryColor.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 6),
          Text(
            progress?.message ?? '登录中…',
            style: const TextStyle(
              fontSize: 12,
              color: AppConstants.primaryColor,
            ),
          ),
        ],
      ),
    );
  }
}
