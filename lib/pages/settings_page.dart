import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
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
import '../widgets/config_form.dart';
import '../widgets/login_button.dart';
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

  const SettingsPage({
    super.key,
    required this.configService,
    required this.loginService,
    required this.sessionManager,
    this.onConfigChanged,
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
  String _appVersion = '';
  String _serverStatus = '';
  Timer? _autoSaveTimer;
  Timer? _serverCheckTimer;
  late final _baseUrlCtrl = TextEditingController();
  late final _serverCtrl = TextEditingController();
  late final _suppliersCtrl = TextEditingController();
  // 登录状态跟踪
  final Map<String, LoginStatus> _loginStatuses = {};
  final Map<String, LoginProgress> _loginProgresses = {};

  @override
  void initState() {
    super.initState();
    _loadConfigs();
  }

  @override
  void dispose() {
    _autoSaveTimer?.cancel();
    _serverCheckTimer?.cancel();
    _baseUrlCtrl.dispose();
    _serverCtrl.dispose();
    _suppliersCtrl.dispose();
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

  Future<void> _loadConfigs() async {
    setState(() => _loading = true);
    try {
      final configs = await widget.configService.loadConfigs();
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
        // 2. 补货配置
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: _buildRestockConfigCard(),
        ),
        // 3. 门店列表
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(children: [
            ...List.generate(_configs.length, (i) => _buildStoreItem(i)),
            _buildAddButton(),
          ]),
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
              label: '供货商列表（逗号分隔）',
              ctrl: _suppliersCtrl,
              hint: '例如：L228,F05,N68',
              maxLines: 3,
              onChanged: (v) => _autoSaveRestock(() {
                _restockConfig = _restockConfig.copyWith(suppliers: v);
              }),
            ),
            const SizedBox(height: 10),
            // 供货商备份按钮
            Row(children: [
              Expanded(child: _supplierBtn('乡下上传', Icons.upload, () => _uploadSuppliers('乡下'))),
              const SizedBox(width: 6),
              Expanded(child: _supplierBtn('乡下下载', Icons.download, () => _downloadSuppliers('乡下'))),
            ]),
            const SizedBox(height: 6),
            Row(children: [
              Expanded(child: _supplierBtn('b5上传', Icons.upload, () => _uploadSuppliers('b5'))),
              const SizedBox(width: 6),
              Expanded(child: _supplierBtn('b5下载', Icons.download, () => _downloadSuppliers('b5'))),
            ]),
          ],
        ),
      ),
    );
  }

  Widget _supplierBtn(String label, IconData icon, VoidCallback onTap) {
    return OutlinedButton.icon(
      onPressed: onTap,
      icon: Icon(icon, size: 14),
      label: Text(label, style: const TextStyle(fontSize: 11)),
      style: OutlinedButton.styleFrom(
        foregroundColor: AppConstants.primaryColor,
        side: const BorderSide(color: AppConstants.primaryColor),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    );
  }

  Widget _buildRestockField({
    required String label,
    required String hint,
    required TextEditingController ctrl,
    required ValueChanged<String> onChanged,
    int maxLines = 1,
  }) {
    return TextField(
      maxLines: maxLines,
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
        // 登录按钮行
        Padding(
          padding: const EdgeInsets.only(bottom: 4, left: 4),
          child: Row(
            children: [
              LoginButton(
                storeName: config.name.isNotEmpty ? config.name : '门店${index + 1}',
                status: status,
                progress: progress,
                onLogin: () => _login(index),
                onLogout: () => _logout(index),
              ),
            ],
          ),
        ),
      ],
    );
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

  static const _importPwd = '99252057';

  void _showMsg(String msg) { ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), duration: Duration(seconds: 2))); }

  Future<void> _uploadSuppliers(String tag) async {
    final pwdCtrl = TextEditingController();
    final ok = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: Text('${tag}上传验证'), content: TextField(controller: pwdCtrl, obscureText: true, decoration: const InputDecoration(labelText: '输入密码', border: OutlineInputBorder())),
      actions: [TextButton(onPressed: ()=>Navigator.pop(ctx,false), child: const Text('取消')), TextButton(onPressed: ()=>Navigator.pop(ctx,true), child: const Text('确认'))],
    ));
    if (ok != true || pwdCtrl.text != _importPwd) { _showMsg('密码错误'); return; }
    try {
      final json = _restockConfig.suppliers;
      final dir = Directory('/storage/emulated/0/Download');
      final file = File('${dir.path}/suppliers_$tag.txt');
      await file.writeAsString(json);
      _showMsg('已保存到 Downloads/suppliers_$tag.txt');
    } catch (e) { _showMsg('保存失败: $e'); }
  }

  Future<void> _downloadSuppliers(String tag) async {
    final svr = AuthService.normalizeUrl(_restockConfig.serverUrl);
    if (svr.isEmpty) { _showMsg('请先配置服务器地址'); return; }
    final pwdCtrl = TextEditingController();
    final ok = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: Text('${tag}下载验证'), content: TextField(controller: pwdCtrl, obscureText: true, decoration: const InputDecoration(labelText: '输入密码', border: OutlineInputBorder())),
      actions: [TextButton(onPressed: ()=>Navigator.pop(ctx,false), child: const Text('取消')), TextButton(onPressed: ()=>Navigator.pop(ctx,true), child: const Text('确认'))],
    ));
    if (ok != true || pwdCtrl.text != _importPwd) { _showMsg('密码错误'); return; }
    try {
      final uri = Uri.parse('$svr/PIC/suppliers_$tag.txt');
      final client = HttpClient();
      final req = await client.getUrl(uri);
      final resp = await req.close().timeout(Duration(seconds: 5));
      if (resp.statusCode == 200) {
        final body = await resp.transform(utf8.decoder).join();
        if (body.trim().isNotEmpty) {
          setState(() => _restockConfig = _restockConfig.copyWith(suppliers: body.trim()));
          _suppliersCtrl.text = body.trim();
          await widget.configService.saveRestockConfig(_restockConfig);
          _showMsg('${tag}供货商下载成功 ✓');
        }
      } else { _showMsg('下载失败(${resp.statusCode})'); }
      client.close();
    } catch (e) { _showMsg('下载失败: $e'); }
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
