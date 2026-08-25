import 'package:flutter/material.dart';
import '../models/store_config.dart';
import '../services/config_service.dart';
import '../services/login_service.dart';
import '../services/query_service.dart';
import '../services/restock_service.dart';
import '../services/session_manager.dart';
import '../models/printer_config.dart';
import '../models/restock_prefill_data.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/auth_service.dart';
import '../services/update_service.dart';
import '../services/foreground_service.dart';
import '../services/keepalive_logger.dart';
import '../models/keepalive_log.dart';
import '../utils/constants.dart';
import 'settings_page.dart';
import 'query_page.dart';
import 'restock_page.dart';
import 'records_page.dart';

/// 主页（底部导航栏 Tab 切换）
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

enum _VerifyState { pending, checking, valid, expired, loggingIn, failed }

class _StoreVerifyStatus {
  final String name;
  _VerifyState state;
  String message;
  _StoreVerifyStatus({required this.name, this.state = _VerifyState.pending, this.message = ''});
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  int _currentTab = 0;
  final PageController _pageController = PageController();

  // 服务实例
  late final ConfigService _configService;
  late final SessionManager _sessionManager;
  late final LoginService _loginService;
  late final QueryService _queryService;
  RestockService? _restockService;

  // 服务
  late final AuthService _authService;

  // 状态
  List<StoreConfig> _configs = [];
  List<PrinterConfig> _printerConfigs = [];
  bool _loading = true;
  bool _verifying = false;
  bool _needAuth = false;
  bool _authDialogShowing = false;
  String _configJson = '';
  final List<_StoreVerifyStatus> _verifyList = [];
  String _autoLoginMessage = '';
  int _sessionRefreshKey = 0;
  final Set<String> _verifiedKeys = {};
  bool _serverOnline = false;
  Timer? _serverCheckTimer;
  Timer? _keepAliveTimer;
  RestockPrefillData? _prefillData;
  bool _silentSupplierFetched = false;
  int _settingsRefreshTick = 0;
  final ValueNotifier<({String barcode, String imageUrl})?> _restockImageNotifier =
      ValueNotifier(null);
  final ValueNotifier<({String barcode, String supplier})?> _restockSupplierNotifier =
      ValueNotifier(null);
  DateTime? _lastResumeRefreshTime;
  static const _resumeRefreshDebounce = Duration(seconds: 60);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initAuth();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _serverCheckTimer?.cancel();
    _keepAliveTimer?.cancel();
    _restockImageNotifier.dispose();
    _restockSupplierNotifier.dispose();
    _pageController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_loading) return;
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.inactive:
        // App 进入后台 → 启动前台服务保活
        final fgNow = DateTime.now();
        ForegroundService.start().then((ok) {
          KeepAliveLogger().add(KeepAliveLogEntry(
            timestamp: fgNow,
            event: ok ? 'started' : 'start_failed',
            detail: ok ? 'Foreground service started' : 'Foreground service start returned false',
            success: ok,
          ));
          if (!ok) {
            debugPrint('[KeepAlive] foreground service start failed');
          }
        });
        break;
      case AppLifecycleState.resumed:
        // App 回到前台 → 停止前台服务 + 刷新会话
        ForegroundService.stop();
        KeepAliveLogger().add(KeepAliveLogEntry(
          timestamp: DateTime.now(),
          event: 'stopped',
          detail: 'Foreground service stopped (app resumed)',
          success: true,
        ));
        final now = DateTime.now();
        if (_lastResumeRefreshTime == null ||
            now.difference(_lastResumeRefreshTime!) > _resumeRefreshDebounce) {
          _lastResumeRefreshTime = now;
          _refreshSessionsOnResume();
        }
        break;
      default:
        break;
    }
  }

  Future<void> _initAuth() async {
    // 预热网络，触发权限弹窗
    try { await HttpClient().getUrl(Uri.parse('https://www.google.com')); } catch (_) {}
    final prefs = await SharedPreferences.getInstance();
    _authService = AuthService(prefs);
    _configService = ConfigService();
    _sessionManager = SessionManager();
    _loginService = LoginService(_sessionManager);
    _queryService = QueryService(_sessionManager);
    _loadConfigs();
  }

  Future<void> _loadConfigs({bool skipVerify = false}) async {
    // 非首次加载时静默更新，不显示加载动画
    if (!_loading) {
      try {
        final configs = await _configService.loadConfigs();
        final restockConfig = await _configService.loadRestockConfig();
        final printers = await _configService.loadPrinterConfigs();
        if (mounted) setState(() {
          _configs = configs;
          _restockService = RestockService(restockConfig);
          _printerConfigs = printers;
        });
      } catch (_) {}
      return;
    }
    try {
      final configs = await _configService.loadConfigs();
      // 加载补货配置
      final restockConfig = await _configService.loadRestockConfig();
      // 加载打印机配置
      final printers = await _configService.loadPrinterConfigs();
      if (mounted) {
        setState(() {
          _configs = configs;
          _printerConfigs = printers;
          _restockService = RestockService(restockConfig);
          _loading = false;
        });
        // 首次使用：没有服务器地址则先弹窗填写
        var effectiveConfig = restockConfig;
        if (effectiveConfig.serverUrl.isEmpty) {
          final svrUrl = await _askServerUrl();
          if (svrUrl.isNotEmpty) {
            effectiveConfig = effectiveConfig.copyWith(serverUrl: svrUrl);
            await _configService.saveRestockConfig(effectiveConfig);
            _restockService = RestockService(effectiveConfig);
          }
        }
        final svrUrl = _restockService?.serverUrl ?? 'http://192.168.1.138';

        // 检查是否需要系统授权
        _configJson = jsonEncode({
          'configs': configs.map((c) => c.toJson()).toList(),
          'restock': effectiveConfig.toJson(),
        });
        if (await _authService.needReAuth(_configJson, svrUrl)) {
          setState(() => _needAuth = true);
        }

        // 首次加载时验证登录状态 + 检查 APP 更新（并行执行）
        if (!skipVerify && configs.isNotEmpty) {
          _verifyAndAutoLogin(configs);
          _checkAppUpdate(svrUrl);
        }
        // 启动定时检查
        _startServerCheck();
        _startKeepAlive();
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// 验证各门店登录状态（所有门店同时验证）
  Future<void> _verifyAndAutoLogin(List<StoreConfig> configs) async {
    _verifyList.clear();
    final validConfigs = <StoreConfig>[];
    for (final config in configs) {
      if (!config.enabled) continue; // 只验证勾选了搜索的门店
      if (config.storeId.isEmpty && !config.isValid) continue; // 总账号同步门店无需工号密码
      _verifyList.add(_StoreVerifyStatus(name: config.name));
      validConfigs.add(config);
    }

    if (_verifyList.isEmpty) return;

    setState(() => _verifying = true);

    // 所有门店一起设为"验证中"
    for (int i = 0; i < _verifyList.length; i++) {
      _verifyList[i].state = _VerifyState.checking;
      _verifyList[i].message = '正在验证登录状态…';
    }

    // 同时验证所有门店
    final tasks = <Future<void>>[];
    for (int i = 0; i < validConfigs.length; i++) {
      final idx = i;
      final config = validConfigs[i];
      tasks.add(_verifyOneStore(idx, config));
    }

    await Future.wait(tasks);

    // 延迟一下让用户看到最终状态
    await Future.delayed(const Duration(milliseconds: 800));
    if (mounted) {
      setState(() {
        _verifying = false;
        _sessionRefreshKey++;
      });
    }
  }


  Future<void> _verifyOneStore(int i, StoreConfig config) async {
    final isValid = await _sessionManager.isCookieValid(
      config.storeKey,
      config.baseUrl,
    );

    if (isValid) {
      _verifiedKeys.add(config.storeKey);
      _updateVerify(i, _VerifyState.valid, '登录有效 ✓');
      return;
    }

    // Cookie 过期，自动重新登录（工号）；未配置工号密码则提示微信扫码登录
    _updateVerify(i, _VerifyState.expired, '登录已过期');
    await Future.delayed(const Duration(milliseconds: 300));
    if (!config.isValid) {
      _updateVerify(i, _VerifyState.failed, '请到设置页用微信扫码登录');
      return;
    }
    _updateVerify(i, _VerifyState.loggingIn, '正在重新登录…');

    try {
      await _loginService.login(
        config,
        onProgress: (progress) {
          _updateVerify(i, _VerifyState.loggingIn, progress.message);
        },
      );
      _verifiedKeys.add(config.storeKey);
      _updateVerify(i, _VerifyState.valid, '重新登录成功 ✓');
    } catch (_) {
      _updateVerify(i, _VerifyState.failed, '自动登录失败，请用微信扫码登录');
    }
  }

  void _updateVerify(int index, _VerifyState state, String message) {
    if (!mounted) return;
    setState(() {
      _verifyList[index].state = state;
      _verifyList[index].message = message;
    });
  }

  Future<String> _askServerUrl() async {
    final ctrl = TextEditingController();
    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('配置补货服务器'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('请输入补货服务器地址：', style: TextStyle(fontSize: 14)),
          const SizedBox(height: 12),
          TextField(controller: ctrl, decoration: const InputDecoration(hintText: '例如: http://192.168.1.138', border: OutlineInputBorder())),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('确认')),
        ],
      ),
    );
    return ctrl.text.trim();
  }

  Future<void> _showAuthDialog() async {
    final pwdCtrl = TextEditingController();
    final serverUrl = _restockService?.serverUrl ?? 'http://192.168.1.138';
    final remotePwd = await _authService.fetchRemotePassword(serverUrl);
    final useFallback = remotePwd.isEmpty;
    final effectivePwd = useFallback ? '21771737' : remotePwd;

    if (!mounted) return;

    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('系统安全验证'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(useFallback ? Icons.close : Icons.check_circle,
                    size: 16, color: useFallback ? Colors.red : Colors.green),
                const SizedBox(width: 6),
                Text(useFallback ? '无法连接服务器，使用默认密码' : '服务器连接成功 ✓',
                    style: TextStyle(fontSize: 13, color: useFallback ? Colors.red : Colors.green)),
              ],
            ),
            const SizedBox(height: 8),
            const Text('请输入授权码：', style: TextStyle(fontSize: 14)),
            const SizedBox(height: 12),
            TextField(
              controller: pwdCtrl,
              obscureText: true,
              keyboardType: TextInputType.number,
              autofocus: true,
              decoration: const InputDecoration(
                hintText: '请输入授权码',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              if (pwdCtrl.text.trim() == effectivePwd) {
                Navigator.pop(ctx, true);
              } else {
                ScaffoldMessenger.of(ctx).showSnackBar(
                  const SnackBar(content: Text('授权码错误'), backgroundColor: Colors.red),
                );
              }
            },
            child: const Text('验证'),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      // 检查操作员姓名
      if (_authService.operatorName.isEmpty) {
        await _showOperatorDialog();
      }
      final serverUrl = _restockService?.serverUrl ?? 'http://192.168.1.138';
      await _authService.authorize(_configJson, serverUrl,
          operator: _authService.operatorName);

      // 同步操作员姓名到补货配置
      if (_authService.operatorName.isNotEmpty) {
        final config = await _configService.loadRestockConfig();
        final updated = config.copyWith(operatorName: _authService.operatorName);
        await _configService.saveRestockConfig(updated);
        if (mounted) {
          setState(() => _restockService = RestockService(updated));
        }
      }
      setState(() {
        _needAuth = false;
        _authDialogShowing = false;
      });
    } else {
      _authDialogShowing = false;
    }
  }

  Future<void> _showOperatorDialog() async {
    final nameCtrl = TextEditingController();
    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('操作员姓名'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('请输入您的操作员姓名：', style: TextStyle(fontSize: 14)),
            const SizedBox(height: 12),
            TextField(
              controller: nameCtrl,
              decoration: const InputDecoration(
                hintText: '例如：张三',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              final name = nameCtrl.text.trim();
              if (name.isNotEmpty) {
                _authService.saveOperator(name);
                Navigator.pop(ctx);
              }
            },
            child: const Text('确认'),
          ),
        ],
      ),
    );
  }

  void _startServerCheck() {
    _serverCheckTimer?.cancel();
    _checkServerOnline();
    _serverCheckTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      _checkServerOnline();
    });
  }

  Future<void> _checkServerOnline() async {
    String? url = _restockService?.serverUrl;
    if (url == null || url.isEmpty) {
      // 尝试从配置中获取
      url = _configService.loadRestockConfig() is RestockConfig ? null : null;
      if (mounted) setState(() => _serverOnline = false);
      return;
    }
    // 多路径尝试（大小写都试）
    for (final path in ['/PIC/password.txt', '/pic/password.txt', '/index.esp?query_booking', '/']) {
      try {
        final client = HttpClient();
        client.connectionTimeout = const Duration(seconds: 3);
        final uri = Uri.parse('$url$path');
        final request = await client.getUrl(uri);
        final response = await request.close().timeout(const Duration(seconds: 3));
        client.close();
        if (response.statusCode == 200 || response.statusCode == 302) {
          if (mounted) setState(() => _serverOnline = true);
          return;
        }
      } catch (_) {}
    }
    if (mounted) setState(() => _serverOnline = false);
  }

  void _startKeepAlive() {
    _keepAliveTimer?.cancel();
    // 微信扫码登录可长期在线，无需频繁验证；改为 1 小时检查一次
    _keepAliveTimer = Timer.periodic(const Duration(minutes: 60), (_) {
      _refreshSessions();
    });
    // 首次也执行一次
    _refreshSessions();
  }

  /// 刷新所有门店会话（保活 + 过期自动重登）
  Future<void> _refreshSessions() async {
    for (final config in _configs) {
      if (config.storeId.isEmpty && !config.isValid) continue;
      await _refreshStoreSession(config);
    }
  }

  /// 从后台恢复时刷新会话（带防抖 + 顶部横幅）
  Future<void> _refreshSessionsOnResume() async {
    final expired = <String>[];
    for (final config in _configs) {
      if (config.storeId.isEmpty && !config.isValid) continue;
      final ok = await _refreshStoreSession(config);
      if (!ok) expired.add(config.name);
    }
    if (mounted) {
      setState(() => _sessionRefreshKey++);
      if (_configs.isNotEmpty) {
        final total = _configs
            .where((c) => c.enabled && (c.storeId.isNotEmpty || c.isValid))
            .length;
        if (expired.isEmpty && total > 0) {
          _autoLoginMessage = '会话已刷新 ($total个门店)';
        } else if (expired.isNotEmpty) {
          _autoLoginMessage = '${expired.join('、')} 重连失败';
        }
        if (_autoLoginMessage.isNotEmpty) {
          Future.delayed(const Duration(seconds: 2), () {
            if (mounted) setState(() => _autoLoginMessage = '');
          });
        }
      }
    }
  }

  /// 刷新单个门店会话，返回 true=有效, false=过期且重登失败
  Future<bool> _refreshStoreSession(StoreConfig config) async {
    final valid = await _queryService.keepAlive(config);
    if (valid) return true;
    try {
      await _loginService.login(config);
      _verifiedKeys.add(config.storeKey);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _checkAppUpdate(String serverUrl) async {
    final update = UpdateService();
    final newVer = await update.checkUpdate(serverUrl);
    if (!mounted || newVer == 0) return;

    // 同版本已经提示过就不再弹
    final prefs = await SharedPreferences.getInstance();
    final shownVer = prefs.getInt('sys_update_shown_ver') ?? 0;
    if (newVer <= shownVer) return;

    // 先记录已提示，防止循环弹窗
    await prefs.setInt('sys_update_shown_ver', newVer);

    if (!mounted) return;

    final currentVer = await update.currentVersion;
    final versionName = await update.versionName;
    if (!mounted) return;

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('发现新版本'),
        content: Text(
            '当前版本 $versionName (build $currentVer)\n新版本 build $newVer，请下载更新',
            style: const TextStyle(fontSize: 14)),
        actions: [
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx);
              await update.openDownloadPage(serverUrl);
            },
            child: const Text('立即更新'),
          ),
        ],
      ),
    );
  }

  void _navigateToRestock(RestockPrefillData data) {
    setState(() {
      _prefillData = data;
      _currentTab = 1;
    });
    _pageController.animateToPage(1, duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
    _maybeSilentFetchSuppliers();
  }

  /// 静默获取供货商（每次启动仅一次）
  /// 供货商列表为手动模式时：缓存名称→UID 映射，并更新为银豹排序列表且只读
  void _maybeSilentFetchSuppliers() {
    if (_silentSupplierFetched) return;
    _silentSupplierFetched = true;
    _silentFetchSuppliers();
  }

  Future<void> _silentFetchSuppliers() async {
    var processed = 0;
    try {
      final manualMode = _restockService?.suppliersManualMode ?? false;
      if (!manualMode) return;
      var listUpdated = false;
      for (final store in _configs) {
        if (!store.enabled) continue;
        if (!await _sessionManager.isCookieValid(store.storeKey, store.baseUrl)) {
          continue;
        }
        processed++;
        // 静默缓存供货商名称→UID 映射（补货提交同步供货商时优先使用）
        await _queryService.silentRefreshSupplierUid(store);
        if (listUpdated) continue;
        // 静默获取供货商列表（全局配置，任一门店成功即可）
        final result = await _loginService.fetchSuppliers(store);
        if (result.suppliers.isEmpty) continue;
        final current = await _configService.loadRestockConfig();
        final updated = current.copyWith(
          suppliers: result.suppliers.join(','),
          suppliersReadonly: true,
        );
        await _configService.saveRestockConfig(updated);
        listUpdated = true;
        if (mounted) {
          setState(() {
            _restockService = RestockService(updated);
            _settingsRefreshTick++;
          });
        }
      }
      if (processed == 0) {
        // 没有可用的已登录门店时，允许下次再触发
        _silentSupplierFetched = false;
      }
    } catch (_) {
      // 静默失败不影响主流程
      if (processed == 0) _silentSupplierFetched = false;
    }
  }

  Widget _buildVerifyBanner() {
    return Material(
      color: const Color(0xFF1976D2),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              const SizedBox(
                width: 14, height: 14,
                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  _verifyList.where((v) => v.state == _VerifyState.valid).length == _verifyList.length
                      ? '全部验证完成'
                      : '验证登录状态… ${_verifyList.where((v) => v.state == _VerifyState.valid).length}/${_verifyList.length}',
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildVerifyRow(_StoreVerifyStatus info) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          _verifyIcon(info.state),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(info.name, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(info.message, style: const TextStyle(fontSize: 12, color: AppConstants.textSecondary)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _verifyIcon(_VerifyState state) {
    switch (state) {
      case _VerifyState.pending:
        return const Icon(Icons.circle_outlined, size: 24, color: AppConstants.textSecondary);
      case _VerifyState.checking:
      case _VerifyState.loggingIn:
        return const SizedBox(
          width: 22, height: 22,
          child: CircularProgressIndicator(strokeWidth: 2.5, color: AppConstants.primaryColor),
        );
      case _VerifyState.valid:
        return const Icon(Icons.check_circle, size: 26, color: AppConstants.successColor);
      case _VerifyState.expired:
        return const Icon(Icons.warning_amber, size: 26, color: AppConstants.warningColor);
      case _VerifyState.failed:
        return const Icon(Icons.cancel, size: 26, color: AppConstants.errorColor);
    }
  }

  void _onConfigChanged() {
    _loadConfigs(skipVerify: true);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Scaffold(
        backgroundColor: AppConstants.primaryColor,
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.qr_code_scanner, size: 56, color: Colors.white70),
              const SizedBox(height: 20),
              const Text(
                AppConstants.appName,
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Colors.white),
              ),
              const SizedBox(height: 24),
              const SizedBox(
                width: 28, height: 28,
                child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white),
              ),
              const SizedBox(height: 14),
              const Text('正在加载配置…', style: TextStyle(fontSize: 14, color: Colors.white70)),
            ],
          ),
        ),
      );
    }

    // 系统授权检查（配置变更或首次使用）
    if (_needAuth && !_authDialogShowing) {
      _authDialogShowing = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _showAuthDialog());
    }

    return Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(AppConstants.appName),
            const SizedBox(width: 8),
            GestureDetector(
              onTap: () async {
                await _checkServerOnline();
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                    content: Text(_serverOnline ? '补货服务器已连接 ✓' : '补货服务器无法连接 ✗'),
                    duration: const Duration(seconds: 2),
                    backgroundColor: _serverOnline ? AppConstants.successColor : Colors.red,
                  ));
                }
              },
              child: Container(
                width: 10, height: 10,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _serverOnline ? Colors.greenAccent : Colors.redAccent,
                  boxShadow: [
                    BoxShadow(color: (_serverOnline ? Colors.green : Colors.red).withValues(alpha: 0.6), blurRadius: 4),
                  ],
                ),
              ),
            ),
          ],
        ),
        backgroundColor: AppConstants.primaryColor,
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      body: Stack(
        children: [
          PageView(
            controller: _pageController,
            onPageChanged: (i) {
              setState(() => _currentTab = i);
              // 打开配置页也触发静默获取供货商（手动模式下仅一次）
              if (i == 3) _maybeSilentFetchSuppliers();
            },
            children: [
              // Tab 0: 查询（默认首页）
              QueryPage(
                printerConfigs: _printerConfigs,
                configs: _configs,
                queryService: _queryService,
                sessionManager: _sessionManager,
                loginService: _loginService,
                onNavigateToRestock: _navigateToRestock,
                verifiedKeys: _verifiedKeys,
                verifying: _verifying,
                imageUpdateNotifier: _restockImageNotifier,
                supplierUpdateNotifier: _restockSupplierNotifier,
                supplierOptions: _restockService?.suppliers ?? [],
              ),
              // Tab 1: 补货
              if (_restockService != null)
                RestockPage(
                  pageController: _pageController,
                  restockService: _restockService!,
                  prefillData: _prefillData,
                  onPrefillConsumed: () => setState(() => _prefillData = null),
                  queryService: _queryService,
                  configs: _configs,
                  onImageUploaded: (barcode, imageUrl) => _restockImageNotifier.value =
                      (barcode: barcode, imageUrl: imageUrl),
                  onSupplierSynced: (barcode, supplier) =>
                      _restockSupplierNotifier.value =
                          (barcode: barcode, supplier: supplier),
                  onSubmitted: () {
                    _pageController.animateToPage(0, duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
                    setState(() {
                      _currentTab = 0;
                      _prefillData = null;
                    });
                  },
                )
              else
                const Center(child: Text('加载补货配置失败')),
              // Tab 2: 记录
              const RecordsPage(),
              // Tab 3: 配置
              SettingsPage(
                configService: _configService,
                loginService: _loginService,
                sessionManager: _sessionManager,
                onConfigChanged: _onConfigChanged,
                refreshTick: _settingsRefreshTick,
              ),
            ],
          ),
          // 登录状态验证横幅
          if (_verifying)
            Positioned(
              top: 0, left: 0, right: 0,
              child: _buildVerifyBanner(),
            ),
          // 自动登录提示浮层
          if (_autoLoginMessage.isNotEmpty)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: Material(
                color: AppConstants.primaryColor.withValues(alpha: 0.95),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 10,
                  ),
                  child: Row(
                    children: [
                      const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          _autoLoginMessage,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentTab,
        onTap: (index) {
          _pageController.animateToPage(index, duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
        },
        selectedItemColor: AppConstants.primaryColor,
        unselectedItemColor: AppConstants.textSecondary,
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.qr_code_scanner),
            label: '查询',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.add_business),
            label: '补货',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.receipt_long),
            label: '记录',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.settings),
            label: '配置',
          ),
        ],
      ),
    );
  }
}
