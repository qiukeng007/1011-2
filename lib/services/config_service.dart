import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../models/printer_config.dart';
import '../models/store_config.dart';

/// 配置持久化服务
/// - 门店配置（不含密码）使用 shared_preferences 存储
/// - 密码使用 flutter_secure_storage 加密存储
class ConfigService {
  static const _configKey = 'store_configs';
  static const _passwordPrefix = 'pwd_';
  static const _baseUrlKey = 'base_url';
  static const _restockConfigKey = 'restock_config';

  final FlutterSecureStorage _secureStorage;

  ConfigService()
      : _secureStorage = const FlutterSecureStorage(
          aOptions: AndroidOptions(encryptedSharedPreferences: true),
        );

  /// 保存所有门店配置（不含密码）
  Future<void> saveConfigs(List<StoreConfig> configs) async {
    final prefs = await SharedPreferences.getInstance();
    final jsonList = configs.map((c) => c.toJson()).toList();
    await prefs.setString(_configKey, jsonEncode(jsonList));

    // 单独保存密码
    for (final config in configs) {
      if (config.password.isNotEmpty) {
        await _secureStorage.write(
          key: '$_passwordPrefix${config.storeKey}',
          value: config.password,
        );
      }
    }
  }

  /// 加载所有门店配置（含密码）
  Future<List<StoreConfig>> loadConfigs() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonStr = prefs.getString(_configKey);
    if (jsonStr == null || jsonStr.isEmpty) {
      // 默认返回 1 个空门店配置
      return [const StoreConfig(name: '门店1')];
    }

    try {
      final List<dynamic> jsonList = jsonDecode(jsonStr);
      final configs = <StoreConfig>[];
      for (final json in jsonList) {
        final config = StoreConfig.fromJson(json as Map<String, dynamic>);
        // 从加密存储读取密码
        final password = await _secureStorage.read(
          key: '$_passwordPrefix${config.storeKey}',
        );
        configs.add(config.copyWith(password: password ?? ''));
      }
      return configs;
    } catch (_) {
      return [const StoreConfig(name: '门店1')];
    }
  }

  /// 保存单个门店密码
  Future<void> savePassword(String storeKey, String password) async {
    if (password.isNotEmpty) {
      await _secureStorage.write(
        key: '$_passwordPrefix$storeKey',
        value: password,
      );
    }
  }

  /// 获取单个门店密码
  Future<String> getPassword(String storeKey) async {
    return await _secureStorage.read(key: '$_passwordPrefix$storeKey') ?? '';
  }

  /// 删除门店密码
  Future<void> deletePassword(String storeKey) async {
    await _secureStorage.delete(key: '$_passwordPrefix$storeKey');
  }

  /// 保存全局后台地址
  Future<void> saveBaseUrl(String url) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_baseUrlKey, url);
  }

  /// 获取全局后台地址
  Future<String> getBaseUrl() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_baseUrlKey) ?? 'https://beta28.pospal.cn';
  }

  /// 保存补货配置
  Future<void> saveRestockConfig(RestockConfig config) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_restockConfigKey, jsonEncode(config.toJson()));
  }

  /// 加载补货配置（suppliers 为空时自动填入默认列表）
  Future<RestockConfig> loadRestockConfig() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonStr = prefs.getString(_restockConfigKey);
    if (jsonStr == null || jsonStr.isEmpty) {
      return const RestockConfig();
    }
    try {
      final json = jsonDecode(jsonStr) as Map<String, dynamic>;
      var config = RestockConfig.fromJson(json);
      // 如果已保存的供货商为空，补上默认列表并持久化
      if (config.suppliers.isEmpty) {
        config = config.copyWith(suppliers: RestockConfig.defaultSuppliers);
        await saveRestockConfig(config);
      }
      return config;
    } catch (_) {
      return const RestockConfig();
    }
  }

  static const _printerConfigKey = 'printer_configs';

  /// 保存打印机配置
  Future<void> savePrinterConfigs(List<PrinterConfig> configs) async {
    final prefs = await SharedPreferences.getInstance();
    final list = configs.map((c) => c.toJson()).toList();
    await prefs.setString(_printerConfigKey, jsonEncode(list));
  }

  /// 加载打印机配置
  Future<List<PrinterConfig>> loadPrinterConfigs() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonStr = prefs.getString(_printerConfigKey);
    if (jsonStr == null || jsonStr.isEmpty) return defaultPrinters();
    try {
      final list = jsonDecode(jsonStr) as List<dynamic>;
      final configs = list
          .map((e) => PrinterConfig.fromJson(e as Map<String, dynamic>))
          .toList();
      return configs.isEmpty ? defaultPrinters() : configs;
    } catch (_) {
      return defaultPrinters();
    }
  }

  // ===== 打印机多场地配置 =====
  static const _profileActiveKey = 'printer_profile_active';
  static const _profileListKey = 'printer_profile_list';
  static const _profilePrefix = 'printer_profile_';

  /// 获取当前激活的配置名称
  Future<String> getActiveProfileName() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_profileActiveKey) ?? '默认';
  }

  /// 获取所有配置名称列表
  Future<List<String>> getProfileNames() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonStr = prefs.getString(_profileListKey);
    if (jsonStr == null || jsonStr.isEmpty) return ['默认'];
    try {
      return (jsonDecode(jsonStr) as List<dynamic>).cast<String>();
    } catch (_) {
      return ['默认'];
    }
  }

  /// 切换激活的配置
  Future<void> setActiveProfile(String name) async {
    // 保存当前配置到当前 profile
    final currentConfigs = await loadPrinterConfigs();
    final currentName = await getActiveProfileName();
    await _saveProfile(currentName, currentConfigs);

    // 切换
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_profileActiveKey, name);

    // 加载新 profile 的配置
    final newConfigs = await _loadProfile(name);
    await savePrinterConfigs(newConfigs);
  }

  /// 新建配置（复制当前）
  Future<void> createProfile(String name) async {
    final currentConfigs = await loadPrinterConfigs();
    await _saveProfile(name, currentConfigs);

    final names = await getProfileNames();
    names.add(name);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_profileListKey, jsonEncode(names));
  }

  /// 重命名配置
  Future<void> renameProfile(String oldName, String newName) async {
    final prefs = await SharedPreferences.getInstance();
    final oldJson = prefs.getString('$_profilePrefix$oldName');
    if (oldJson != null) {
      await prefs.setString('$_profilePrefix$newName', oldJson);
      await prefs.remove('$_profilePrefix$oldName');
    }

    final names = await getProfileNames();
    final idx = names.indexOf(oldName);
    if (idx >= 0) {
      names[idx] = newName;
      await prefs.setString(_profileListKey, jsonEncode(names));
    }

    final active = await getActiveProfileName();
    if (active == oldName) {
      await prefs.setString(_profileActiveKey, newName);
    }
  }

  /// 删除配置
  Future<void> deleteProfile(String name) async {
    final names = await getProfileNames();
    names.remove(name);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_profileListKey, jsonEncode(names));
    await prefs.remove('$_profilePrefix$name');

    // 如果删的是激活的，切到第一个
    final active = await getActiveProfileName();
    if (active == name && names.isNotEmpty) {
      await setActiveProfile(names.first);
    }
  }

  /// 保存当前配置到指定 profile
  Future<void> saveProfileConfigs(String name, List<PrinterConfig> configs) async {
    await _saveProfile(name, configs);
  }

  Future<void> _saveProfile(String name, List<PrinterConfig> configs) async {
    final prefs = await SharedPreferences.getInstance();
    final list = configs.map((c) => c.toJson()).toList();
    await prefs.setString('$_profilePrefix$name', jsonEncode(list));
  }

  /// 加载指定 profile 的配置
  Future<List<PrinterConfig>> _loadProfile(String name) async {
    final prefs = await SharedPreferences.getInstance();
    final jsonStr = prefs.getString('$_profilePrefix$name');
    if (jsonStr == null || jsonStr.isEmpty) return defaultPrinters();
    try {
      final list = jsonDecode(jsonStr) as List<dynamic>;
      return list.map((e) => PrinterConfig.fromJson(e as Map<String, dynamic>)).toList();
    } catch (_) {
      return defaultPrinters();
    }
  }

  /// 清除所有数据
  Future<void> clearAll() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_configKey);
    await prefs.remove(_baseUrlKey);
    await prefs.remove(_restockConfigKey);
    await _secureStorage.deleteAll();
  }
}
