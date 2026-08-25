import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/auth_service.dart';
import '../models/store_config.dart';
import '../models/login_session.dart';
import '../models/query_log.dart';
import '../services/config_service.dart';
import '../services/login_service.dart';
import '../services/session_manager.dart';
import '../services/query_logger.dart';
import '../services/keepalive_logger.dart';
import '../widgets/config_form.dart';
import '../widgets/login_button.dart';
import 'wechat_login_page.dart';
import '../services/store_sync_service.dart';
import '../models/printer_config.dart';
import '../services/print_service.dart';
import '../widgets/printer_widgets.dart';
import '../utils/constants.dart';

/// 配置管理页面
class SettingsPage extends StatefulWidget {
  final ConfigService configService;
  final LoginService loginService;
  final SessionManager sessionManager;
  final VoidCallback? onConfigChanged;
  final int refreshTick;

  const SettingsPage({
    super.key,
    required this.configService,
    required this.loginService,
    required this.sessionManager,
    this.onConfigChanged,
    this.refreshTick = 0,
  });

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  List<StoreConfig> _configs = [];
  RestockConfig _restockConfig = const RestockConfig();
  List<PrinterConfig> _printerConfigs = [];
  List<String> _printerProfiles = [];
  String _activeProfile = '默认';
  bool _loading = true;
  bool _saving = false;
  bool _updatingSuppliers = false;
  String _appVersion = '';
  String _serverStatus = '';
  Timer? _autoSaveTimer;
  Timer? _serverCheckTimer;
  late final _baseUrlCtrl = TextEditingController();
  late final _serverCtrl = TextEditingController();
  late final _suppliersCtrl = TextEditingController();
  // 总账号登录（ID数据管理）
  late final _masterAccountCtrl = TextEditingController();
  late final _masterBaseUrlCtrl = TextEditingController();
  late final _masterEmployeeCtrl = TextEditingController();
  late final _masterPasswordCtrl = TextEditingController();
  bool _syncingStores = false;
  String _masterLoginTime = '';
  bool _masterLoggedIn = false;
  final Map<String, TextEditingController> _storeNameCtrls = {};
  // 登录状态跟踪
  final Map<String, LoginStatus> _loginStatuses = {};
  final Map<String, LoginProgress> _loginProgresses = {};

  @override
  void initState() {
    super.initState();
    _loadConfigs();
  }

  @override
  void didUpdateWidget(SettingsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 静默获取供货商成功后由 HomePage 通知刷新列表显示
    if (oldWidget.refreshTick != widget.refreshTick) {
      _loadConfigs(silent: true);
    }
  }

  @override
  void dispose() {
    _autoSaveTimer?.cancel();
    _serverCheckTimer?.cancel();
    _baseUrlCtrl.dispose();
    _serverCtrl.dispose();
    _suppliersCtrl.dispose();
    _masterAccountCtrl.dispose();
    _masterBaseUrlCtrl.dispose();
    _masterEmployeeCtrl.dispose();
    _masterPasswordCtrl.dispose();
    for (final c in _storeNameCtrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  /// 自动保存补货配置（延迟 1 秒，连续输入时只触发一次）
  void _autoSaveRestock(VoidCallback update) {
    update();
    setState(() {});
    _autoSaveTimer?.cancel();
    _autoSaveTimer = Timer(const Duration(milliseconds: 1000), () {
      widget.configService.saveRestockConfig(_restockConfig);
      widget.onConfigChanged?.call();
    });
  }

  Future<void> _loadConfigs({bool silent = false}) async {
    if (!silent) setState(() => _loading = true);
    try {
      final loaded = await widget.configService.loadConfigs();
      // 清理历史遗留的重复门店配置
      final configs = _dedupeConfigs(loaded);
      if (configs.length != loaded.length) {
        await widget.configService.saveConfigs(configs);
      }
      final restockConfig = await widget.configService.loadRestockConfig();
      final printers = await widget.configService.loadPrinterConfigs();
      final profiles = await widget.configService.getProfileNames();
      final active = await widget.configService.getActiveProfileName();
      final info = await PackageInfo.fromPlatform();
      setState(() {
        _configs = configs;
        _restockConfig = restockConfig;
        _printerConfigs = printers;
        _printerProfiles = profiles;
        _activeProfile = active;
        _appVersion = info.version;
        _loading = false;
      });
      // 同步控制器
      final baseUrl = await widget.configService.getBaseUrl();
      _baseUrlCtrl.text = baseUrl;
      _masterBaseUrlCtrl.text = baseUrl;
      final mprefs = await SharedPreferences.getInstance();
      final savedAccount = mprefs.getString('login_account');
      _masterAccountCtrl.text = savedAccount ??
          (configs.isNotEmpty ? configs.first.account : '');
      _masterLoginTime = mprefs.getString('master_login_time') ?? '';
      _masterEmployeeCtrl.text = mprefs.getString('login_employee') ?? '';
      _masterPasswordCtrl.text = mprefs.getString('login_password') ?? '';
      final masterKey =
          '${_normMasterUrl(baseUrl)}|${_masterAccountCtrl.text.trim()}|master';
      final masterCookie = await widget.sessionManager.getCookie(masterKey);
      _masterLoggedIn = masterCookie != null && masterCookie.isNotEmpty;
      _serverCtrl.text = restockConfig.serverUrl;
      _suppliersCtrl.text = restockConfig.suppliers;
      // 检查各门店登录状态 + 补货服务器状态
      _checkLoginStatuses();
      _checkServerStatus();
      _loadDiagLogs();
    } catch (_) {
      setState(() => _loading = false);
    }
  }

  /// 清理重复门店配置：按门店ID去重（有ID优先），再按 账号+后台+名称 去重
  List<StoreConfig> _dedupeConfigs(List<StoreConfig> configs) {
    final result = <StoreConfig>[];
    final seenIds = <String>{};
    final seenNames = <String>{};
    for (final c in configs) {
      if (c.storeId.isNotEmpty) {
        if (seenIds.contains(c.storeId)) continue;
        seenIds.add(c.storeId);
      } else {
        final nameKey = '${c.baseUrl}|${c.account}|${c.name}';
        if (seenNames.contains(nameKey)) continue;
        seenNames.add(nameKey);
      }
      result.add(c);
    }
    return result;
  }
  Future<void> _checkLoginStatuses() async {
    for (final config in _configs) {
      final isValid = await widget.sessionManager.isCookieValid(
        config.storeKey,
        config.baseUrl,
      );
      setState(() {
        _loginStatuses[config.storeKey] =
            isValid ? LoginStatus.loggedIn : LoginStatus.notLoggedIn;
      });
    }
  }

  Future<void> _saveConfigs() async {
    setState(() => _saving = true);
    try {
      await widget.configService.saveConfigs(_configs);
      await widget.configService.saveRestockConfig(_restockConfig);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('配置已保存'),
            duration: Duration(seconds: 2),
          ),
        );
      }
      widget.onConfigChanged?.call();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('保存失败'),
            backgroundColor: AppConstants.errorColor,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _addStore() {
    if (_configs.length >= AppConstants.maxStores) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('最多支持 10 个门店')),
      );
      return;
    }
    setState(() {
      _configs.add(StoreConfig(name: '门店${_configs.length + 1}'));
    });
    // 自动保存
    _autoSaveTimer?.cancel();
    _autoSaveTimer = Timer(const Duration(milliseconds: 500), () {
      widget.configService.saveConfigs(_configs);
      widget.onConfigChanged?.call();
    });
  }

  void _removeStore(int index) {
    if (_configs.length <= 1) return;
    final removed = _configs.removeAt(index);
    widget.sessionManager.deleteCookie(removed.storeKey);
    widget.configService.deletePassword(removed.storeKey);
    setState(() {});
    // 自动保存
    _autoSaveTimer?.cancel();
    _autoSaveTimer = Timer(const Duration(milliseconds: 500), () {
      widget.configService.saveConfigs(_configs);
      widget.onConfigChanged?.call();
    });
  }

  void _updateConfig(int index, StoreConfig config) {
    setState(() => _configs[index] = config);
    // 自动静默保存
    _autoSaveTimer?.cancel();
    _autoSaveTimer = Timer(const Duration(milliseconds: 1500), () {
      widget.configService.saveConfigs(_configs);
      widget.onConfigChanged?.call();
    });
  }

  Future<void> _login(int index) async {
    final config = _configs[index];
    if (!config.isValid) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('请先填写完整的门店信息（名称、账号、工号、密码）'),
          backgroundColor: AppConstants.warningColor,
        ),
      );
      return;
    }

    setState(() {
      _loginStatuses[config.storeKey] = LoginStatus.loggingIn;
      _loginProgresses[config.storeKey] = const LoginProgress(message: '准备登录…');
    });

    try {
      await widget.loginService.login(
        config,
        onProgress: (progress) {
          if (mounted) {
            setState(() {
              _loginProgresses[config.storeKey] = progress;
            });
          }
        },
      );

      if (mounted) {
        setState(() {
          _loginStatuses[config.storeKey] = LoginStatus.loggedIn;
          _loginProgresses.remove(config.storeKey);
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${config.name} 登录成功'),
            backgroundColor: AppConstants.successColor,
          ),
        );

      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loginStatuses[config.storeKey] = LoginStatus.failed;
          _loginProgresses.remove(config.storeKey);
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('登录失败：$e'),
            backgroundColor: AppConstants.errorColor,
            duration: const Duration(seconds: 4),
          ),
        );
      }
    }
  }

  /// 手动更新供货商：从银豹获取最新列表（需至少一个门店已登录）

  /// 微信扫码登录（移植 smart_eye_stock 的登录方式，长期在线）
  Future<void> _wechatLogin(int index) async {
    final config = _configs[index];
    final baseUrl = config.baseUrl.trim().isEmpty
        ? AppConstants.defaultBaseUrl
        : config.baseUrl.trim();
    final storeKey = '$baseUrl|${config.account}|${config.cashierJobNumber}';

    final ok = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => WechatLoginPage(
          baseUrl: baseUrl,
          storeKey: storeKey,
          sessionManager: widget.sessionManager,
          onLoggedIn: (cookie) {
            // 同时保存账号级 master 会话：总账号模式下同账号其他门店共享登录
            widget.sessionManager.saveCookie(
              '$baseUrl|${config.account}|master',
              cookie,
              via: 'wechat',
            );
            if (mounted) {
              setState(() {
                _loginStatuses[storeKey] = LoginStatus.loggedIn;
                _loginProgresses.remove(storeKey);
              });
            }
          },
        ),
      ),
    );
    if (ok == true && mounted) {
      final cfg = _configs[index];
      // 登录成功后自动刷新供货商列表（与工号登录一致）
      await _refreshSuppliersAfterLogin(cfg.copyWith(baseUrl: baseUrl));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${cfg.name} 微信登录成功，会话长期有效'),
            backgroundColor: AppConstants.successColor,
          ),
        );
      }
    }
  }
  /// 总账号微信扫码登录：登录成功后 Cookie 存为账号级 master 会话（所有门店共享），
  /// 并自动同步门店列表（ID数据管理）
  Future<void> _masterWechatLogin() async {
    final baseUrl = _normMasterUrl(_masterBaseUrlCtrl.text);
    final account = _masterAccountCtrl.text.trim();
    if (account.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先填写总账号'), backgroundColor: AppConstants.warningColor),
      );
      return;
    }
    final masterKey = '$baseUrl|$account|master';
    // 登录成功后优先使用页面内提取的门店；未取到再走 HTTP 同步
    var storesApplied = false;
    final ok = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => WechatLoginPage(
          baseUrl: baseUrl,
          storeKey: masterKey,
          sessionManager: widget.sessionManager,
          account: _masterAccountCtrl.text.trim(),
          employee: _masterEmployeeCtrl.text.trim(),
          password: _masterPasswordCtrl.text,
          onLoggedIn: (cookie) {},
          onStoresLoaded: (stores) {
            if (stores.isNotEmpty) {
              storesApplied = true;
              _applyStores(stores);
            }
          },
        ),
      ),
    );
    if (ok == true && mounted) {
      final prefs = await SharedPreferences.getInstance();
      final now = _formatNowText();
      await prefs.setString('master_login_time', now);
      setState(() {
        _masterLoginTime = now;
        _masterLoggedIn = true;
      });
      if (!storesApplied) {
        await _syncStoresFromMaster();
      }
    }
  }

  String _formatNowText() {
    final n = DateTime.now();
    return '${n.year}-${n.month.toString().padLeft(2, '0')}-${n.day.toString().padLeft(2, '0')} ${n.hour.toString().padLeft(2, '0')}:${n.minute.toString().padLeft(2, '0')}';
  }

  String _normMasterUrl(String url) {
    var u = url.trim();
    if (u.isEmpty) return AppConstants.defaultBaseUrl;
    if (u.startsWith('http://') || u.startsWith('https://')) {
      return u.replaceAll(RegExp(r'/+$'), '');
    }
    return 'https://$u';
  }

  /// 用总账号会话从银豹同步门店列表到门店配置（ID数据管理）
  Future<void> _syncStoresFromMaster() async {
    if (_syncingStores) return;
    final baseUrl = _normMasterUrl(_masterBaseUrlCtrl.text);
    final account = _masterAccountCtrl.text.trim();
    final masterKey = '$baseUrl|$account|master';
    final cookie = await widget.sessionManager.getCookie(masterKey);
    if (cookie == null || cookie.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('尚未登录总账号，请先微信扫码登录'), backgroundColor: AppConstants.warningColor),
        );
      }
      return;
    }
    setState(() => _syncingStores = true);
    try {
      final stores = await StoreSyncService.fetchStores(baseUrl: baseUrl, cookie: cookie);
      if (!mounted) return;
      if (stores.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('未能从银豹获取门店列表，可能登录已过期'), backgroundColor: AppConstants.errorColor),
        );
        return;
      }
      await _applyStores(stores);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('门店同步失败：$e'), backgroundColor: AppConstants.errorColor),
        );
      }
    } finally {
      if (mounted) setState(() => _syncingStores = false);
    }
  }

  /// 把提取到的门店列表合并到门店配置：只按门店ID去重合并（不因账号/后台写法差异产生重复），
  /// 保留用户改过的门店名称与勾选状态
  Future<void> _applyStores(List<PospalSubStore> stores) async {
    if (stores.isEmpty) return;
    final baseUrl = _normMasterUrl(_masterBaseUrlCtrl.text);
    final account = _masterAccountCtrl.text.trim();
    // 1) 按门店ID去重
    final seenIds = <String>{};
    final uniqueStores = <PospalSubStore>[];
    for (final s in stores) {
      if (seenIds.contains(s.id)) continue;
      seenIds.add(s.id);
      uniqueStores.add(s);
    }
    // 2) 保留旧配置中用户改过的名称与勾选状态（只按 storeId 匹配）
    final oldByStoreId = <String, StoreConfig>{};
    for (final c in _configs) {
      if (c.storeId.isNotEmpty) {
        oldByStoreId[c.storeId] = c;
      }
    }
    // 3) 移除与本次同步门店ID冲突的旧配置，再按唯一列表重建
    final keepIds = uniqueStores.map((s) => s.id).toSet();
    final newConfigs = <StoreConfig>[
      for (final c in _configs)
        if (c.storeId.isEmpty || !keepIds.contains(c.storeId)) c,
    ];
    var added = 0;
    var updated = 0;
    for (final s in uniqueStores) {
      final old = oldByStoreId[s.id];
      if (old != null) {
        newConfigs.add(old.copyWith(name: old.name.isNotEmpty ? old.name : s.name));
        updated++;
      } else {
        newConfigs.add(StoreConfig(
          name: s.name,
          account: account,
          baseUrl: baseUrl,
          storeId: s.id,
          enabled: true,
        ));
        added++;
      }
      await widget.sessionManager.saveUserId(
        '$baseUrl|$account|${s.id}',
        s.id,
      );
    }
    // 4) 双保险：再次按门店ID去重
    _configs = _dedupeConfigs(newConfigs);
    _storeNameCtrls.clear();
    await widget.configService.saveConfigs(_configs);
    widget.onConfigChanged?.call();
    if (mounted) {
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('门店同步完成：共 ${uniqueStores.length} 家门店（新增 $added，更新 $updated），可在下方勾选搜索门店'),
          backgroundColor: AppConstants.successColor,
        ),
      );
    }
  }
  /// 勾选/取消门店参与首页搜索
  void _toggleStoreEnabled(int index, bool value) {
    setState(() => _configs[index] = _configs[index].copyWith(enabled: value));
    _autoSaveTimer?.cancel();
    _autoSaveTimer = Timer(const Duration(milliseconds: 500), () {
      widget.configService.saveConfigs(_configs);
      widget.onConfigChanged?.call();
    });
  }

  Future<void> _updateSuppliersManually() async {
    setState(() => _updatingSuppliers = true);
    try {
      StoreConfig? loggedIn;
      for (final config in _configs) {
        if (!config.enabled) continue; // 优先使用勾选了搜索的门店
        final isValid = await widget.sessionManager.isCookieValid(
          config.storeKey,
          config.baseUrl,
        );
        if (isValid) {
          loggedIn = config;
          break;
        }
      }
      if (loggedIn == null) {
        _showErrorDialog('请先登录至少一个门店，再更新供货商');
        return;
      }
      await _refreshSuppliersAfterLogin(loggedIn);
    } finally {
      if (mounted) setState(() => _updatingSuppliers = false);
    }
  }

  /// 登录成功后自动获取银豹供货商列表，成功则置为只读；失败弹提示原因
  Future<void> _refreshSuppliersAfterLogin(StoreConfig config) async {
    try {
      final result = await widget.loginService.fetchSuppliers(config);
      if (!mounted) return;
      if (result.suppliers.isNotEmpty) {
        final updated = _restockConfig.copyWith(
          suppliers: result.suppliers.join(','),
          suppliersReadonly: true,
        );
        await widget.configService.saveRestockConfig(updated);
        if (mounted) {
          setState(() {
            _restockConfig = updated;
            _suppliersCtrl.text = updated.suppliers;
          });
          widget.onConfigChanged?.call();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('已自动获取 ${result.suppliers.length} 个供货商（只读）')),
          );
        }
        return;
      }
      // 抓取失败：弹可复制对话框
      final String msg;
      if (result.error != null && result.error!.isNotEmpty) {
        msg = '获取供货商失败：${result.error}';
      } else if (result.statusCode != null) {
        msg = '获取供货商失败（HTTP ${result.statusCode}），请稍后重试';
      } else {
        msg = '未能从银豹解析到供货商列表';
      }
      _showErrorDialog(msg);
    } catch (e) {
      if (mounted) {
        _showErrorDialog('获取供货商异常：$e');
      }
    }
  }

  /// 显示可复制的错误信息对话框
  void _showErrorDialog(String msg) {
    if (!mounted) return;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('获取供货商失败'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 320),
          child: SingleChildScrollView(
            child: SelectableText(msg, style: const TextStyle(fontSize: 13)),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: msg));
              ScaffoldMessenger.of(ctx).showSnackBar(
                const SnackBar(
                  content: Text('已复制到剪贴板'),
                  duration: Duration(seconds: 2),
                ),
              );
            },
            child: const Text('复制'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  Future<void> _logout(int index) async {
    final config = _configs[index];
    await widget.sessionManager.deleteCookie(config.storeKey);
    setState(() {
      _loginStatuses[config.storeKey] = LoginStatus.notLoggedIn;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        // 1. 全局后台地址
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Card(
            elevation: 0, color: AppConstants.bgColor,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppConstants.radiusSm)),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: TextField(
                controller: _baseUrlCtrl,
                decoration: const InputDecoration(
                  labelText: '银豹后台地址',
                  isDense: true,
                  contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                  border: OutlineInputBorder(),
                ),
                style: const TextStyle(fontSize: 14),
                onChanged: (v) => widget.configService.saveBaseUrl(v),
              ),
            ),
          ),
        ),
        // 1.5 总账号（总店账号卡片）
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: _buildMasterAccountCard(),
        ),
        const SizedBox(height: 8),
        // 1.6 ID数据管理（门店列表卡片）
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: _buildIdDataCard(),
        ),
        // 2. 补货配置
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: _buildRestockConfigCard(),
        ),
        // 4. 打印机配置（固定3台，不可增减）
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: _buildPrinterSection(),
        ),
        // 5. 查询诊断日志
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: _buildDiagnosticsCard(),
        ),
        // 5b. keepalive log
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: _buildKeepAliveCard(),
        ),
                // 6. 版本号
        Padding(
          padding: const EdgeInsets.only(bottom: 24),
          child: _buildVersionInfo(),
        ),
      ],
    );
  }

  Widget _buildRestockConfigCard() {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      elevation: 0,
      color: AppConstants.bgColor,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppConstants.radiusSm),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.add_business, size: 16, color: AppConstants.primaryColor),
                SizedBox(width: 6),
                Text(
                  '补货配置',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: AppConstants.primaryColor,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            _buildRestockField(
              label: '补货服务器地址',
              ctrl: _serverCtrl,
              hint: '例如：http://192.168.1.100',
              onChanged: (v) => _autoSaveRestock(() {
                _restockConfig = _restockConfig.copyWith(serverUrl: v);
              }),
            ),
            const SizedBox(height: 4),
            _buildServerStatus(),
            const SizedBox(height: 8),
            _buildRestockField(
              label: _restockConfig.suppliersReadonly
                  ? '供货商列表（银豹自动获取，只读）'
                  : '供货商列表（逗号分隔）',
              ctrl: _suppliersCtrl,
              hint: '例如：L228,F05,N68',
              maxLines: 3,
              readOnly: _restockConfig.suppliersReadonly,
              onChanged: (v) => _autoSaveRestock(() {
                _restockConfig = _restockConfig.copyWith(suppliers: v);
              }),
            ),
            const SizedBox(height: 10),
            // 手动更新供货商（从银豹获取最新列表，仅当已登录时可用）
            SizedBox(
              width: double.infinity,
              child: _supplierBtn('更新供货商（从银豹获取）', Icons.sync, _updatingSuppliers ? null : () => _updateSuppliersManually(), loading: _updatingSuppliers),
            ),

          ],
        ),
      ),
    );
  }

  Widget _supplierBtn(String label, IconData icon, VoidCallback? onTap,
      {bool loading = false}) {
    return _PressScaleButton(
      onTap: loading ? null : onTap,
      child: OutlinedButton.icon(
        onPressed: loading ? null : onTap,
        icon: loading
            ? const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Icon(icon, size: 14),
        label: Text(loading ? '获取中…' : label,
            style: const TextStyle(fontSize: 11)),
        style: OutlinedButton.styleFrom(
          foregroundColor: AppConstants.primaryColor,
          side: const BorderSide(color: AppConstants.primaryColor),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
    );
  }

  Widget _buildRestockField({
    required String label,
    required String hint,
    required TextEditingController ctrl,
    required ValueChanged<String> onChanged,
    int maxLines = 1,
    bool readOnly = false,
  }) {
    return TextField(
      maxLines: maxLines,
      readOnly: readOnly,
      controller: ctrl,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 10,
          vertical: 10,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppConstants.radiusSm),
        ),
      ),
      style: const TextStyle(fontSize: 14),
      onChanged: onChanged,
    );
  }

  Widget _buildBaseUrlField() {
    return Card(
      elevation: 0,
      color: AppConstants.bgColor,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppConstants.radiusSm),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            const Icon(Icons.dns, size: 16, color: AppConstants.textSecondary),
            const SizedBox(width: 6),
            const Text(
              '后台地址：',
              style: TextStyle(fontSize: 13, color: AppConstants.textSecondary),
            ),
            Expanded(
              child: Text(
                _configs.isNotEmpty ? _configs.first.baseUrl : AppConstants.defaultBaseUrl,
                style: const TextStyle(fontSize: 13),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStoreItem(int index) {
    final config = _configs[index];
    final status = _loginStatuses[config.storeKey] ?? LoginStatus.notLoggedIn;
    final progress = _loginProgresses[config.storeKey];

    return Column(
      children: [
        ConfigForm(
          index: index,
          config: config,
          canRemove: _configs.length > 1,
          onChanged: (c) => _updateConfig(index, c),
          onRemove: () => _removeStore(index),
        ),
        // 无需逐店登录：登录统一走上方「ID数据管理」总账号微信扫码
        Padding(
          padding: const EdgeInsets.only(bottom: 4, left: 4),
          child: Text(
            '登录统一使用上方「ID数据管理」的总账号微信扫码，无需逐店登录',
            style: const TextStyle(fontSize: 11, color: AppConstants.textSecondary),
          ),
        ),
      ],
    );
  }

  /// 清除总账号会话（退出登录）
  Future<void> _masterLogout() async {
    final baseUrl = _normMasterUrl(_masterBaseUrlCtrl.text);
    final account = _masterAccountCtrl.text.trim();
    final masterKey = '$baseUrl|$account|master';
    await widget.sessionManager.deleteCookie(masterKey);
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('master_login_time');
    if (mounted) {
      setState(() {
        _masterLoginTime = '';
        _masterLoggedIn = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已退出总账号登录'), duration: Duration(seconds: 2)),
      );
    }
  }

  /// ID数据管理（总账号门店）：登录总账号后同步门店列表，勾选要搜索的门店
  /// 总账号卡片（模仿 smart_eye_stock 的「总店账号」卡片）
  Widget _buildMasterAccountCard() {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      elevation: 0,
      color: AppConstants.bgColor,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppConstants.radiusSm),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(children: [
          Row(children: [
            Container(
              width: 12,
              height: 12,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _masterLoggedIn
                    ? AppConstants.successColor
                    : AppConstants.textSecondary,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              _masterLoggedIn ? '已登录' : '未登录',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: _masterLoggedIn
                    ? AppConstants.successColor
                    : AppConstants.textSecondary,
              ),
            ),
            const Spacer(),
            Text(
              _masterLoginTime.isNotEmpty ? '上次：$_masterLoginTime' : '尚未登录',
              style: const TextStyle(fontSize: 11, color: AppConstants.textSecondary),
            ),
          ]),
          const Divider(height: 24),
          _masterFieldRow('总店账号', _masterAccountCtrl, onChanged: (_) => _saveMasterCredentials()),
          const SizedBox(height: 10),
          _masterFieldRow('员工工号', _masterEmployeeCtrl, onChanged: (_) => _saveMasterCredentials()),
          const SizedBox(height: 10),
          _masterFieldRow('工号密码', _masterPasswordCtrl, obscure: true, onChanged: (_) => _saveMasterCredentials()),
          const SizedBox(height: 10),
          _masterFieldRow('后台地址', _masterBaseUrlCtrl, hint: 'beta28.pospal.cn', onChanged: (_) => _saveMasterCredentials()),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _syncingStores ? null : _masterWechatLogin,
              icon: Icon(_masterLoggedIn ? Icons.refresh : Icons.qr_code_scanner, size: 18),
              label: Text(_masterLoggedIn ? '重新登录' : 'WebView 登录（微信扫码）'),
              style: OutlinedButton.styleFrom(
                foregroundColor: _masterLoggedIn ? AppConstants.successColor : AppConstants.primaryColor,
                side: BorderSide(color: _masterLoggedIn ? AppConstants.successColor : AppConstants.primaryColor),
                padding: const EdgeInsets.symmetric(vertical: 10),
              ),
            ),
          ),
          if (_masterLoggedIn) ...[
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: _masterLogout,
                child: const Text('退出登录（清除总账号会话）', style: TextStyle(fontSize: 12)),
              ),
            ),
          ],
        ]),
      ),
    );
  }

  /// ID数据管理卡片（模仿 smart_eye_stock 的门店列表：标签+改名+门店ID）
  Widget _buildIdDataCard() {
    final syncedStores = _configs.where((c) => c.storeId.isNotEmpty).toList();
    _syncStoreNameCtrls();
    if (syncedStores.isEmpty) {
      return Card(
        margin: const EdgeInsets.only(bottom: 8),
        elevation: 0,
        color: AppConstants.bgColor,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppConstants.radiusSm),
        ),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Center(
            child: Column(children: [
              const Icon(Icons.store_outlined, size: 32, color: AppConstants.textSecondary),
              const SizedBox(height: 8),
              const Text('登录后将自动获取门店列表', style: TextStyle(fontSize: 13, color: AppConstants.textSecondary)),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _syncingStores ? null : _syncStoresFromMaster,
                  icon: _syncingStores
                      ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.sync, size: 16),
                  label: const Text('重新同步门店', style: TextStyle(fontSize: 12)),
                ),
              ),
            ]),
          ),
        ),
      );
    }
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      elevation: 0,
      color: AppConstants.bgColor,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppConstants.radiusSm),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(children: [
          Row(children: [
            const Expanded(
              child: Text('门店名称（可自定义修改）', style: TextStyle(fontSize: 12, color: AppConstants.textSecondary)),
            ),
            TextButton.icon(
              onPressed: _syncingStores ? null : _syncStoresFromMaster,
              icon: _syncingStores
                  ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.sync, size: 16),
              label: const Text('重新同步门店', style: TextStyle(fontSize: 12)),
              style: TextButton.styleFrom(
                foregroundColor: AppConstants.primaryColor,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                visualDensity: VisualDensity.compact,
              ),
            ),
          ]),
          const SizedBox(height: 4),
          ...syncedStores.map((c) {
            final idx = _configs.indexOf(c);
            final ctrl = _storeNameCtrls[c.storeId];
            if (ctrl == null) return const SizedBox.shrink();
            final label = _storeBadgeOf(c);
            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(children: [
                Checkbox(
                  value: c.enabled,
                  onChanged: (v) => _toggleStoreEnabled(idx, v ?? true),
                  visualDensity: VisualDensity.compact,
                ),
                Container(
                  width: 36,
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                  decoration: BoxDecoration(
                    color: AppConstants.primaryColor.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(label, textAlign: TextAlign.center, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppConstants.primaryColor)),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: ctrl,
                    style: const TextStyle(fontSize: 13),
                    decoration: InputDecoration(
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
                    ),
                    onChanged: (v) => _saveStoreNameField(idx, v),
                  ),
                ),
                const SizedBox(width: 6),
                Text(c.storeId, style: const TextStyle(fontSize: 9, color: AppConstants.textSecondary)),
              ]),
            );
          }),
          const Divider(height: 16),
          const Text(
            '勾选需要搜索的门店（如：新店、老店），首页搜索只查询勾选门店的库存',
            style: TextStyle(fontSize: 11, color: AppConstants.textSecondary),
          ),
        ]),
      ),
    );
  }

  /// 门店名称徽标（取名称前 2 个字，模仿 smart_eye_stock 的标签徽章）
  String _storeBadgeOf(StoreConfig c) {
    final name = c.name.trim();
    if (name.isEmpty) return '店';
    return name.length <= 2 ? name : name.substring(0, 2);
  }

  /// 为门店列表初始化输入框控制器
  void _syncStoreNameCtrls() {
    for (final c in _configs) {
      if (c.storeId.isEmpty) continue;
      if (!_storeNameCtrls.containsKey(c.storeId)) {
        _storeNameCtrls[c.storeId] = TextEditingController(text: c.name);
      } else if (_storeNameCtrls[c.storeId]!.text != c.name) {
        _storeNameCtrls[c.storeId]!.text = c.name;
      }
    }
  }

  /// 修改门店名称并保存到门店配置
  void _saveStoreNameField(int index, String value) {
    if (index < 0 || index >= _configs.length) return;
    if (value == _configs[index].name) return;
    setState(() {
      _configs[index] = _configs[index].copyWith(name: value);
    });
    _autoSaveTimer?.cancel();
    _autoSaveTimer = Timer(const Duration(milliseconds: 500), () {
      final cleaned = value.trim();
      _configs[index] = _configs[index].copyWith(name: cleaned);
      widget.configService.saveConfigs(_configs);
      widget.onConfigChanged?.call();
    });
  }

  /// 总账号栏位输入（模仿 smart_eye_stock 的 _field 样式）
  Widget _masterFieldRow(
    String label,
    TextEditingController ctrl, {
    bool obscure = false,
    String? hint,
    ValueChanged<String>? onChanged,
  }) {
    return Row(children: [
      SizedBox(width: 72, child: Text(label, style: const TextStyle(fontSize: 13, color: AppConstants.textSecondary))),
      const SizedBox(width: 8),
      Expanded(
        child: TextField(
          controller: ctrl,
          obscureText: obscure,
          style: const TextStyle(fontSize: 13),
          onChanged: onChanged,
          decoration: InputDecoration(
            isDense: true,
            filled: true,
            fillColor: Colors.white,
            contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            hintText: hint,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: const BorderSide(color: AppConstants.dividerColor),
            ),
          ),
        ),
      ),
    ]);
  }

  /// 保存总账号配置（账号/工号/密码/后台地址）
  Future<void> _saveMasterCredentials() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('login_account', _masterAccountCtrl.text.trim());
    await prefs.setString('login_employee', _masterEmployeeCtrl.text.trim());
    await prefs.setString('login_password', _masterPasswordCtrl.text);
    await prefs.setString('login_base_url', _masterBaseUrlCtrl.text.trim());
    final norm = AuthService.normalizeUrl(_masterBaseUrlCtrl.text.trim());
    await prefs.setString('server_url', norm);
    await widget.configService.saveBaseUrl(norm);
    _baseUrlCtrl.text = norm;
  }


    Widget _buildAddButton() {
    return Center(
      child: TextButton.icon(
        onPressed: _addStore,
        icon: const Icon(Icons.add_circle_outline, size: 18),
        label: const Text('+ 添加门店'),
        style: TextButton.styleFrom(
          foregroundColor: AppConstants.primaryColor,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        ),
      ),
    );
  }

  Future<void> _checkServerStatus() async {
    final url = _restockConfig.serverUrl.trim();
    if (url.isEmpty) {
      setState(() => _serverStatus = '未配置');
      return;
    }
    setState(() => _serverStatus = '检查中…');
    try {
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 3);
      final uri = Uri.parse(
          '${AuthService.normalizeUrl(url)}/PIC/password.txt');
      final request = await client.getUrl(uri);
      final response = await request.close().timeout(const Duration(seconds: 3));
      client.close();
      setState(() => _serverStatus =
          response.statusCode == 200 ? '已连接 ✓' : '无法连接 (${response.statusCode})');
    } catch (_) {
      setState(() => _serverStatus = '无法连接 ✗');
    }
  }

  Widget _buildPrinterSection() {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      elevation: 0,
      color: AppConstants.bgColor,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppConstants.radiusSm)),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(children: [
              Icon(Icons.print, size: 16, color: AppConstants.primaryColor),
              SizedBox(width: 6),
              Text('打印机配置', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppConstants.primaryColor)),
            ]),
            const SizedBox(height: 6),
            // 场地选择
            _buildProfileSelector(),
            const SizedBox(height: 6),
            ..._printerConfigs.map((p) => _buildPrinterRow(p)),
            const SizedBox(height: 4),
            Center(
              child: TextButton.icon(
                onPressed: () {
                  setState(() => _printerConfigs.add(PrinterConfig(
                    id: DateTime.now().millisecondsSinceEpoch.toString(),
                    name: '新打印机',
                    ip: '', port: 18888,
                    labelWidth: 40, labelHeight: 30,
                  )));
                  _savePrinters();
                },
                icon: const Icon(Icons.add, size: 16),
                label: const Text('添加打印机'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  final Map<String, TextEditingController> _printerNameCtrls = {};
  final Map<String, TextEditingController> _printerIpCtrls = {};
  final Map<String, TextEditingController> _printerPortCtrls = {};

  Widget _buildProfileSelector() {
    return Row(
      children: [
        const Text('场地:', style: TextStyle(fontSize: 13, color: AppConstants.textSecondary)),
        const SizedBox(width: 6),
        Expanded(
          child: DropdownButton<String>(
            value: _activeProfile,
            isExpanded: true,
            underline: const SizedBox(),
            style: const TextStyle(fontSize: 13, color: AppConstants.primaryColor, fontWeight: FontWeight.w600),
            items: _printerProfiles.map((p) => DropdownMenuItem(value: p, child: Text(p))).toList(),
            onChanged: (v) async {
              if (v == null || v == _activeProfile) return;
              // 先保存当前IP到当前profile
              await widget.configService.savePrinterConfigs(_printerConfigs);
              // 切换到新profile
              await widget.configService.setActiveProfile(v);
              final newConfigs = await widget.configService.loadPrinterConfigs();
              setState(() {
                _activeProfile = v;
                _printerConfigs = newConfigs;
              });
              // 通知 HomePage 重新加载打印机配置，否则查询页显示的还是旧数据
              widget.onConfigChanged?.call();
            },
          ),
        ),
        const SizedBox(width: 4),
        GestureDetector(
          onTap: () => _renameProfile(),
          child: const Icon(Icons.edit, size: 16, color: AppConstants.textSecondary),
        ),
        const SizedBox(width: 8),
        GestureDetector(
          onTap: () => _createProfile(),
          child: const Icon(Icons.add_circle_outline, size: 16, color: AppConstants.primaryColor),
        ),
      ],
    );
  }

  Future<void> _createProfile() async {
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('新建场地配置'),
      content: TextField(controller: ctrl, decoration: const InputDecoration(hintText: '例如: 家里、店铺2', border: OutlineInputBorder()), autofocus: true),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
        TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('创建')),
      ],
    ));
    if (ok == true && ctrl.text.trim().isNotEmpty) {
      final name = ctrl.text.trim();
      await widget.configService.savePrinterConfigs(_printerConfigs);
      await widget.configService.createProfile(name);
      setState(() {
        _printerProfiles = [..._printerProfiles, name];
        _activeProfile = name;
      });
    }
  }

  Future<void> _renameProfile() async {
    final ctrl = TextEditingController(text: _activeProfile);
    final ok = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('重命名 / 删除场地'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: ctrl, decoration: const InputDecoration(hintText: '新名称', border: OutlineInputBorder()), autofocus: true),
        if (_printerProfiles.length > 1) ...[
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: () async {
              Navigator.pop(ctx, false);
              final confirm = await showDialog<bool>(context: context, builder: (c) => AlertDialog(
                title: Text('删除「$_activeProfile」？'),
                content: const Text('打印机配置不会丢失，可随时切回'),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('取消')),
                  TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('删除', style: TextStyle(color: Colors.red))),
                ],
              ));
              if (confirm == true) {
                await widget.configService.deleteProfile(_activeProfile);
                final names = await widget.configService.getProfileNames();
                final active = await widget.configService.getActiveProfileName();
                final configs = await widget.configService.loadPrinterConfigs();
                setState(() { _printerProfiles = names; _activeProfile = active; _printerConfigs = configs; });
              }
            },
            icon: const Icon(Icons.delete_outline, size: 14, color: Colors.red),
            label: const Text('删除此场地', style: TextStyle(color: Colors.red, fontSize: 12)),
            style: OutlinedButton.styleFrom(side: const BorderSide(color: Colors.red)),
          ),
        ],
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
        TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('保存')),
      ],
    ));
    if (ok == true && ctrl.text.trim().isNotEmpty && ctrl.text.trim() != _activeProfile) {
      await widget.configService.renameProfile(_activeProfile, ctrl.text.trim());
      final names = await widget.configService.getProfileNames();
      setState(() { _printerProfiles = names; _activeProfile = ctrl.text.trim(); });
    }
  }

  Widget _buildPrinterRow(PrinterConfig p) {
    _printerNameCtrls.putIfAbsent(p.id, () => TextEditingController(text: p.name));
    _printerIpCtrls.putIfAbsent(p.id, () => TextEditingController(text: p.ip));
    _printerPortCtrls.putIfAbsent(p.id, () => TextEditingController(text: p.port.toString()));
    // 同步外部变更
    if (_printerNameCtrls[p.id]!.text != p.name) _printerNameCtrls[p.id]!.text = p.name;
    if (_printerIpCtrls[p.id]!.text != p.ip) _printerIpCtrls[p.id]!.text = p.ip;
    if (_printerPortCtrls[p.id]!.text != p.port.toString()) _printerPortCtrls[p.id]!.text = p.port.toString();

    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8), border: Border.all(color: Colors.grey.shade200)),
      child: Row(children: [
        Expanded(flex: 2, child: TextField(
          decoration: const InputDecoration(isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 6, vertical: 6), border: OutlineInputBorder()),
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
          controller: _printerNameCtrls[p.id]!,
          onChanged: (v) => _updatePrinter(p.copyWith(name: v)),
        )),
        const SizedBox(width: 4),
        Expanded(flex: 3, child: TextField(
          decoration: const InputDecoration(isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 6, vertical: 6), border: OutlineInputBorder()),
          style: const TextStyle(fontSize: 13),
          controller: _printerIpCtrls[p.id]!,
          onChanged: (v) => _updatePrinter(p.copyWith(ip: v)),
        )),
        const SizedBox(width: 4),
        SizedBox(width: 60, child: TextField(
          decoration: const InputDecoration(isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 6, vertical: 6), border: OutlineInputBorder()),
          style: const TextStyle(fontSize: 13),
          controller: _printerPortCtrls[p.id]!,
          keyboardType: TextInputType.number,
          onChanged: (v) => _updatePrinter(p.copyWith(port: int.tryParse(v) ?? 18888)),
        )),
        const SizedBox(width: 4),
        GestureDetector(
          onTap: () {
            setState(() {
              _printerConfigs.removeWhere((c) => c.id == p.id);
              _printerNameCtrls.remove(p.id)?.dispose();
              _printerIpCtrls.remove(p.id)?.dispose();
              _printerPortCtrls.remove(p.id)?.dispose();
            });
            _savePrinters();
          },
          child: const Icon(Icons.delete_outline, size: 18, color: AppConstants.errorColor),
        ),
      ]),
    );
  }

  void _updatePrinter(PrinterConfig updated) {
    final i = _printerConfigs.indexWhere((p) => p.id == updated.id);
    if (i >= 0) {
      setState(() => _printerConfigs[i] = updated);
      _savePrinters();
    }
  }

  Future<void> _savePrinters() async {
    await widget.configService.savePrinterConfigs(_printerConfigs);
    await widget.configService.saveProfileConfigs(_activeProfile, _printerConfigs);
  }

  void _editPrinter(PrinterConfig p) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => PrinterEditSheet(printer: p, onSave: (updated) {
        _updatePrinter(updated);
      }),
    );
  }

  Widget _buildServerStatus() {
    final connected = _serverStatus.contains('✓');
    return Row(
      children: [
        Container(
          width: 8, height: 8,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: connected
                ? AppConstants.successColor
                : _serverStatus.contains('…')
                  ? AppConstants.warningColor
                  : AppConstants.errorColor,
          ),
        ),
        const SizedBox(width: 6),
        Text(
          _serverStatus.isEmpty ? '点击检查' : _serverStatus,
          style: TextStyle(fontSize: 12, color: connected ? AppConstants.successColor : AppConstants.textSecondary),
        ),
        const Spacer(),
        GestureDetector(
          onTap: _checkServerStatus,
          child: const Icon(Icons.refresh, size: 16, color: AppConstants.textSecondary),
        ),
      ],
    );
  }

  // ==================== 查询诊断 ====================

  List<QueryLogEntry> _diagLogs = [];
  bool _diagExpanded = false;
  int _diagFileSize = 0;
  String _diagStats = '';

  Future<void> _loadDiagLogs() async {
    final logger = QueryLogger();
    await logger.ensureLoaded();
    final size = await logger.getFileSize();
    if (mounted) {
      setState(() {
        _diagLogs = logger.entries;
        _diagStats = logger.statsSummary;
        _diagFileSize = size;
      });
    }
  }

  Widget _buildDiagnosticsCard() {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      elevation: 0,
      color: AppConstants.bgColor,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppConstants.radiusSm),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 标题行
            Row(
              children: [
                const Icon(Icons.bug_report, size: 16, color: Colors.orange),
                const SizedBox(width: 6),
                const Text(
                  '查询诊断日志',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: Colors.orange,
                  ),
                ),
                const Spacer(),
                // 刷新按钮
                GestureDetector(
                  onTap: _loadDiagLogs,
                  child: const Icon(Icons.refresh, size: 16, color: AppConstants.textSecondary),
                ),
                const SizedBox(width: 12),
                // 导出按钮
                GestureDetector(
                  onTap: () async {
                    await QueryLogger().exportAndShare();
                  },
                  child: const Icon(Icons.share, size: 16, color: AppConstants.primaryColor),
                ),
                if (_diagLogs.isNotEmpty) ...[
                  const SizedBox(width: 12),
                  // 清空按钮
                  GestureDetector(
                    onTap: () async {
                      final ok = await showDialog<bool>(
                        context: context,
                        builder: (ctx) => AlertDialog(
                          title: const Text('清空诊断日志'),
                          content: const Text('确定要清空所有查询诊断记录吗？'),
                          actions: [
                            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
                            TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('清空')),
                          ],
                        ),
                      );
                      if (ok == true) {
                        await QueryLogger().clear();
                        _loadDiagLogs();
                      }
                    },
                    child: const Icon(Icons.delete_outline, size: 16, color: AppConstants.errorColor),
                  ),
                ],
              ],
            ),

            // 统计摘要
            if (_diagStats.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                _diagStats,
                style: const TextStyle(fontSize: 11, color: AppConstants.textSecondary),
              ),
              if (_diagFileSize > 0)
                Text(
                  '日志文件: ${(_diagFileSize / 1024).toStringAsFixed(1)} KB',
                  style: const TextStyle(fontSize: 10, color: AppConstants.textSecondary),
                ),
            ] else ...[
              const SizedBox(height: 6),
              const Text(
                '暂无查询记录，进行查询后自动记录每步耗时',
                style: TextStyle(fontSize: 11, color: AppConstants.textSecondary),
              ),
            ],

            // 日志列表
            if (_diagLogs.isNotEmpty) ...[
              const SizedBox(height: 8),
              // 展开/收起
              GestureDetector(
                onTap: () => setState(() => _diagExpanded = !_diagExpanded),
                child: Row(
                  children: [
                    Icon(
                      _diagExpanded ? Icons.expand_less : Icons.expand_more,
                      size: 16,
                      color: AppConstants.primaryColor,
                    ),
                    Text(
                      _diagExpanded ? '收起详情' : '展开最近 ${_diagLogs.length > 20 ? 20 : _diagLogs.length} 条记录',
                      style: const TextStyle(fontSize: 12, color: AppConstants.primaryColor),
                    ),
                  ],
                ),
              ),
              if (_diagExpanded) ...[
                const SizedBox(height: 4),
                SizedBox(
                  height: 260,
                  child: ListView.separated(
                    itemCount: _diagLogs.length > 50 ? 50 : _diagLogs.length,
                    separatorBuilder: (_, __) => const Divider(height: 4),
                    itemBuilder: (context, i) => _buildDiagEntry(_diagLogs[i]),
                  ),
                ),
                if (_diagLogs.length > 50)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      '... 还有 ${_diagLogs.length - 50} 条旧记录（导出可查看全部）',
                      style: const TextStyle(fontSize: 10, color: AppConstants.textSecondary),
                    ),
                  ),
              ],
            ],
          ],
        ),
      ),
    );
  }

  int _expandedDiagIndex = -1;

  Widget _buildDiagEntry(QueryLogEntry entry) {
    final i = _diagLogs.indexOf(entry);
    final isExpanded = _expandedDiagIndex == i;
    final icon = entry.isTimeout ? '🚫' : (entry.isSlow ? '⚠️' : '✅');
    final Color iconColor = entry.isTimeout
        ? AppConstants.errorColor
        : (entry.isSlow ? AppConstants.warningColor : AppConstants.successColor);

    return GestureDetector(
      onTap: () => setState(() {
        _expandedDiagIndex = isExpanded ? -1 : i;
      }),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
        decoration: BoxDecoration(
          color: isExpanded ? Colors.grey.shade100 : null,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 单行摘要
            Row(
              children: [
                Text(icon, style: const TextStyle(fontSize: 12)),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    entry.oneLine,
                    style: TextStyle(
                      fontSize: 11,
                      fontFamily: 'monospace',
                      color: iconColor,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            // 展开详情
            if (isExpanded) ...[
              const SizedBox(height: 4),
              ...entry.stores.map((s) => Padding(
                    padding: const EdgeInsets.only(left: 20, bottom: 2),
                    child: Text(
                      s.summary,
                      style: const TextStyle(
                        fontSize: 10,
                        fontFamily: 'monospace',
                        color: AppConstants.textSecondary,
                      ),
                    ),
                  )),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildKeepAliveCard() {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text('保活日志', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                const Spacer(),
                GestureDetector(
                  onTap: () => KeepAliveLogger().exportAndShare(),
                  child: const Icon(Icons.share, size: 16, color: Colors.blue),
                ),
              ],
            ),
            const SizedBox(height: 4),
            const Text(
              '记录前台服务启动/停止/失败，帮助诊断后台保活问题',
              style: TextStyle(fontSize: 11, color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }

    Widget _buildVersionInfo() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.only(top: 8, bottom: 24),
        child: Text(
          '当前版本: $_appVersion',
          style: const TextStyle(fontSize: 12, color: AppConstants.textSecondary),
        ),
      ),
    );
  }

  Widget _buildSaveButton() {
    return Center(
      child: _saving
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : ElevatedButton.icon(
              onPressed: _saveConfigs,
              icon: const Icon(Icons.save, size: 18),
              label: const Text('保存配置'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppConstants.primaryColor,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              ),
            ),
    );
  }
}

/// 带按压缩放动画的按钮包装（点击时缩小，松手恢复）
class _PressScaleButton extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  const _PressScaleButton({super.key, required this.child, this.onTap});

  @override
  State<_PressScaleButton> createState() => _PressScaleButtonState();
}

class _PressScaleButtonState extends State<_PressScaleButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: widget.onTap == null
          ? null
          : (_) => setState(() => _pressed = true),
      onTapUp: widget.onTap == null
          ? null
          : (_) => setState(() => _pressed = false),
      onTapCancel: widget.onTap == null
          ? null
          : () => setState(() => _pressed = false),
      child: AnimatedScale(
        scale: _pressed ? 0.95 : 1.0,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
        child: widget.child,
      ),
    );
  }
}
