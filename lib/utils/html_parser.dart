import '../models/store_config.dart';

/// HTML 解析工具
/// 移植自 server/signin-parse.js
class HtmlParser {
  /// 提取 regularSignIn_box 整块 HTML
  static String extractRegularSignInBox(String html) {
    final m = RegExp(
      r'<div[^>]*class="[^"]*regularSignIn_box[^"]*"[^>]*>([\s\S]*?)</div>\s*</div>\s*</div>\s*</div>',
      caseSensitive: false,
    ).firstMatch(html);
    if (m != null) return m.group(0)!;

    final m2 = RegExp(r'regularSignIn_box[\s\S]{0,25000}', caseSensitive: false)
        .firstMatch(html);
    return m2 != null ? m2.group(0)! : html;
  }

  /// 提取工号登录面板 HTML
  static String extractCashierPanelHtml(String html) {
    final patterns = [
      // 匹配 cashierSignIn_box div 块，直到遇到 regular/account/user SignIn 或结尾
      RegExp(
        r'<div[^>]*class="[^"]*cashierSignIn_box[^"]*"[^>]*>([\s\S]*?)</div>(?:\s*<div[^>]*class="[^"]*(?:regular|account|user)SignIn[^"]*"|\s*<div[^>]*loginType|$)',
        caseSensitive: false,
      ),
      RegExp(
        r'<div[^>]*class="[^"]*cashierSignIn[^"]*"[^>]*>([\s\S]*?)</div>\s*</div>',
        caseSensitive: false,
      ),
      RegExp(r'工号登录[\s\S]{0,8000}?</form>'),
    ];

    for (final p in patterns) {
      final m = p.firstMatch(html);
      if (m != null) return m.group(0) ?? m.group(1) ?? '';
    }

    final box = extractRegularSignInBox(html);
    // 在 box 中找 cashierSignIn 内容，直到遇到 user/account/regular SignIn 或结尾
    final inner = RegExp(
      r'class="[^"]*cashierSignIn[\s\S]*?(?=<div[^>]*class="[^"]*(?:user|account|regular)SignIn[^"]*"|$)',
      caseSensitive: false,
    ).firstMatch(box);
    return inner != null ? inner.group(0)! : box;
  }

  /// 从 loginType 第二个 span 读取工号模式标识
  static String parseCashierLoginTypeValue(String html) {
    final block = RegExp(
      r'class="[^"]*loginType[^"]*"[^>]*>([\s\S]*?)</div>',
      caseSensitive: false,
    ).firstMatch(html);
    if (block == null) return '2';

    final spans = RegExp(r'<span\b([^>]*)>([\s\S]*?)</span>', caseSensitive: false)
        .allMatches(block.group(1)!);
    if (spans.length < 2) return '2';

    final attrs = spans.elementAt(1).group(1)!;
    final text = spans.elementAt(1).group(2)!.replaceAll(RegExp(r'<[^>]+>'), '').trim();

    final data = RegExp(r'\bdata-(?:login-?type|type|mode)="([^"]*)"', caseSensitive: false)
            .firstMatch(attrs) ??
        RegExp(r'\bdata-value="([^"]*)"', caseSensitive: false).firstMatch(attrs);
    if (data != null) return data.group(1)!;

    if (RegExp(r'工号|cashier|job', caseSensitive: false).hasMatch(text)) return '2';
    return '2';
  }

  /// 提取表单中的 input 字段
  static List<Map<String, String>> extractInputsFromHtml(String fragment) {
    final inputs = <Map<String, String>>[];
    final inputRe = RegExp(r'<input\b([^>]*)/?>', caseSensitive: false);
    for (final m in inputRe.allMatches(fragment)) {
      final tag = m.group(1)!;
      final name = _extractAttr(tag, 'name');
      final id = _extractAttr(tag, 'id');
      final type = _extractAttr(tag, 'type').toLowerCase();
      final value = _extractAttr(tag, 'value');

      if ((name.isEmpty && id.isEmpty) ||
          type == 'submit' ||
          type == 'button' ||
          type == 'image') {
        continue;
      }

      inputs.add({
        'name': name.isNotEmpty ? name : id,
        'type': type,
        'value': value,
        'id': id,
      });
    }
    return inputs;
  }

  /// 提取表单 action
  static String extractFormAction(String fragment, String baseUrl) {
    final m = RegExp(r'<form\b([^>]*)>', caseSensitive: false).firstMatch(fragment);
    if (m == null) return '$baseUrl/Account/SignIn';

    final action = _extractAttr(m.group(1)!, 'action');
    if (action.isEmpty) return '$baseUrl/Account/SignIn';
    if (action.startsWith('http')) return action;
    return '$baseUrl${action.startsWith('/') ? '' : '/'}$action';
  }

  /// 从页面脚本提取工号登录 AJAX URL
  static List<String> parseCashierSignInUrls(String html) {
    final urls = <String>{};

    final patterns = [
      RegExp(r'"([^"]*(?:CashierSignIn|SignIn)[^"]*)"', caseSensitive: false),
      RegExp(r'url\s*:\s*"([^"]+)"[\s\S]{0,400}?loginType', caseSensitive: false),
      RegExp(r'loginType\s*[=!:]{1,3}\s*2[\s\S]{0,600}?url\s*:\s*"([^"]+)"', caseSensitive: false),
    ];

    for (final p in patterns) {
      for (final m in p.allMatches(html)) {
        final url = m.group(1);
        if (url != null && RegExp(r'signin|signIn|login', caseSensitive: false).hasMatch(url)) {
          urls.add(url);
        }
      }
    }

    return urls.toList();
  }

  /// 提取 AntiForgeryToken
  static String extractAntiForgeryToken(String html) {
    final m = RegExp(
      r'name="__RequestVerificationToken"[^>]*value="([^"]+)"',
      caseSensitive: false,
    ).firstMatch(html);
    if (m != null) return m.group(1)!;

    final m2 = RegExp(
      r'value="([^"]+)"[^>]*name="__RequestVerificationToken"',
      caseSensitive: false,
    ).firstMatch(html);
    return m2 != null ? m2.group(1)! : '';
  }

  /// 构建工号登录提交方案
  /// 模拟手动浏览器登录，只发送必要的字段，减少自动化痕迹
  static List<LoginPlan> buildCashierLoginPlans(
    String html,
    String baseUrl,
    StoreConfig store,
  ) {
    final loginType = parseCashierLoginTypeValue(html);
    final token = extractAntiForgeryToken(html);
    final cashierPanel = extractCashierPanelHtml(html);
    final panelInputs = extractInputsFromHtml(cashierPanel);

    final plans = <LoginPlan>[];

    // 方案1：从工号面板提取的表单（最接近手动浏览器行为）
    if (panelInputs.isNotEmpty) {
      final action = extractFormAction(cashierPanel, baseUrl);
      final fields = _mapFields(panelInputs, store, loginType, token);
      plans.add(LoginPlan(
        url: action,
        fields: fields,
        label: '面板表单',
        isJson: false,
      ));
    }

    // 方案2：标准表单提交（只发送必要字段，模拟手动登录）
    const returnUrl = '/Product/Manage';
    final standardFields = _buildStandardFields(store, loginType, token, returnUrl);

    // 只使用 Account/SignIn 一个 URL，不尝试多个 URL
    plans.add(LoginPlan(
      url: '$baseUrl/Account/SignIn',
      fields: Map.from(standardFields),
      label: '标准表单',
      isJson: false,
    ));

    // 方案3：JSON 提交（loginType 使用字符串类型，与 JS 版一致）
    // JS 版已改为 String(loginType || "2") → JSON.stringify → "loginType":"2"
    plans.add(LoginPlan(
      url: '$baseUrl/Account/SignIn',
      fields: {
        'txt_userName': store.account,
        'txt_cashierJobName': store.cashierJobNumber,
        'txt_password': store.password,
        'account': store.account,
        'cashierJobNumber': store.cashierJobNumber,
        'password': store.password,
        'loginType': loginType, // 字符串类型，银豹可能不接受数字
        'LoginType': loginType, // 大写 L，银豹可能要求
        'isCashierLogin': true,
        'ReturnUrl': returnUrl,
      },
      label: 'JSON工号',
      isJson: true,
    ));

    return plans.where((p) => p.url.isNotEmpty).toList();
  }

  /// 映射表单字段到门店凭据（与服务端 JS 版一致）
  /// 银豹可能要求某些额外字段存在
  static Map<String, dynamic> _mapFields(
    List<Map<String, String>> inputs,
    StoreConfig store,
    String loginType,
    String token,
  ) {
    final fields = <String, dynamic>{};

    // 先填 hidden 字段（保持原始值）
    for (final inp in inputs) {
      if (inp['type'] == 'hidden' && inp['value']!.isNotEmpty) {
        fields[inp['name']!] = inp['value']!;
      }
    }

    // 填充用户输入字段
    for (final inp in inputs) {
      final nl = inp['name']!.toLowerCase();
      final idl = (inp['id'] ?? '').toLowerCase();

      if (idl == 'txt_username' ||
          RegExp(r'^account$', caseSensitive: false).hasMatch(inp['name']!) ||
          (nl.contains('account') && !nl.contains('cashier'))) {
        fields[inp['name']!] = store.account;
      } else if (idl == 'txt_cashierjobname' ||
          RegExp(r'cashierjobname|cashierjobnumber|jobnumber|jobno|guhao', caseSensitive: false)
              .hasMatch(nl) ||
          RegExp(r'cashierjobname|cashierjobnumber', caseSensitive: false).hasMatch(idl)) {
        fields[inp['name']!] = store.cashierJobNumber;
      } else if (idl == 'txt_password' ||
          RegExp(r'^password$|^pwd$', caseSensitive: false).hasMatch(nl)) {
        fields[inp['name']!] = store.password;
      } else if (idl == 'txt_username' ||
          RegExp(r'^username$', caseSensitive: false).hasMatch(nl)) {
        fields[inp['name']!] = store.account;
      }
    }

    // 补充额外字段（与服务端 JS 版一致）
    fields['loginType'] = loginType;
    fields['LoginType'] = loginType;
    fields['txt_userName'] = store.account;
    fields['txt_cashierJobName'] = store.cashierJobNumber;
    fields['txt_password'] = store.password;
    if (token.isNotEmpty) fields['__RequestVerificationToken'] = token;
    // 确保工号字段存在
    if (!fields.keys.any((k) => RegExp(r'job|cashier|guhao', caseSensitive: false).hasMatch(k))) {
      fields['cashierJobNumber'] = store.cashierJobNumber;
    }
    // 确保账号字段存在
    if (!fields.containsKey('account') && !fields.containsKey('Account')) {
      fields['account'] = store.account;
    }
    // 确保密码字段存在
    if (!fields.containsKey('password') && !fields.containsKey('Password')) {
      fields['password'] = store.password;
    }
    fields['ReturnUrl'] = fields['ReturnUrl'] ?? '/Product/Manage';

    return fields;
  }

  /// 构建标准表单字段（与服务端 JS 版一致）
  /// 银豹可能要求某些重复字段存在
  static Map<String, dynamic> _buildStandardFields(
    StoreConfig store,
    String loginType,
    String token,
    String returnUrl,
  ) {
    final fields = <String, dynamic>{
      'account': store.account,
      'Account': store.account,
      'txt_userName': store.account,
      'txtAccount': store.account,
      'cashierJobNumber': store.cashierJobNumber,
      'CashierJobNumber': store.cashierJobNumber,
      'txt_cashierJobName': store.cashierJobNumber,
      'txtCashierJobName': store.cashierJobNumber,
      'txtCashierJobNumber': store.cashierJobNumber,
      'jobNumber': store.cashierJobNumber,
      'password': store.password,
      'Password': store.password,
      'txt_password': store.password,
      'txtPassword': store.password,
      'loginType': loginType,
      'LoginType': loginType,
      'isCashierLogin': 'true',
      'IsCashierLogin': 'true',
      'cashierLogin': 'true',
      'ReturnUrl': returnUrl,
      'returnUrl': returnUrl,
    };
    if (token.isNotEmpty) fields['__RequestVerificationToken'] = token;
    return fields;
  }

  static String _extractAttr(String tag, String attrName) {
    final m = RegExp(
      r'\b' + attrName + r'="([^"]*)"',
      caseSensitive: false,
    ).firstMatch(tag);
    return m != null ? m.group(1)! : '';
  }
}

/// 登录方案
class LoginPlan {
  final String url;
  final Map<String, dynamic> fields;
  final String label;
  final bool isJson;

  const LoginPlan({
    required this.url,
    required this.fields,
    required this.label,
    required this.isJson,
  });

  String get contentType => isJson
      ? 'application/json; charset=UTF-8'
      : 'application/x-www-form-urlencoded; charset=UTF-8';

  String get body {
    if (isJson) {
      return _mapToJson(fields);
    }
    return _mapToForm(fields);
  }

  /// JSON 序列化，保留数字和布尔类型（与服务端 JS 版一致）
  static String _mapToJson(Map<String, dynamic> map) {
    final buffer = StringBuffer('{');
    var first = true;
    for (final entry in map.entries) {
      if (!first) buffer.write(',');
      first = false;
      buffer.write('"${_escapeJson(entry.key)}":');
      final value = entry.value;
      if (value is num) {
        // 数字类型不加引号，如 "loginType":2
        buffer.write(value.toString());
      } else if (value is bool) {
        // 布尔类型不加引号，如 "isCashierLogin":true
        buffer.write(value ? 'true' : 'false');
      } else {
        buffer.write('"${_escapeJson(value.toString())}"');
      }
    }
    buffer.write('}');
    return buffer.toString();
  }

  static String _escapeJson(String s) {
    return s
        .replaceAll('\\', '\\\\')
        .replaceAll('"', '\\"')
        .replaceAll('\n', '\\n')
        .replaceAll('\r', '\\r')
        .replaceAll('\t', '\\t');
  }

  static String _mapToForm(Map<String, dynamic> map) {
    return map.entries
        .map((e) =>
            '${Uri.encodeComponent(e.key)}=${Uri.encodeComponent(e.value.toString())}')
        .join('&');
  }
}
