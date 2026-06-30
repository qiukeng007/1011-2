/// 全局补货配置
class RestockConfig {
  static const defaultSuppliers = 'L228,F05,N68,C108,D317,B64,G56-G57,'
      'MOMO(momo)-N1,B62,G27,L128,G45,A142,B34,HELLO TODAY,N101,D313,V71,G21,'
      'KD康德kd,D104(林立),M213,LFHJ龙发货架lfhj,B54(anni),F10B,MUCH BETTER,B16,'
      'C216(印度香),YDSF印度沙发ydsf,C06,C04,F09,F01-F02,E12,C21,H76,G12,E115,'
      'A45(A4-5玩具店),C88,L02,A02-A04-N9,JJL佳佳乐jjl,WFL万福来wfl,F08,A18,B27,'
      'B46,A034,C104,C22,M23,TESCO-E3-Tina(e3),A292,B65,SASA(sasa),'
      'A3-A32-A33(行李箱),F22,F33,H78,JESON监控(D442),A408,C01,L144,D327,B01,'
      'C43,C12,G5,G52,JZ镜子工厂,U19,C308,CD床垫,G39-G40(监控),F10A,'
      'DDSJ当地书籍（EDUCATION FOR THE NATION）(ddsj),B33(手机壳、手机膜),HILOOK A275,'
      'YDDT印度地毯yddt,YDCL印度窗帘配件（papini trading）(ydcl),A01,B19,M140,M101,'
      'T1,G1,L5,DDYL(当地饮料),D326,BJH(百佳惠超市),ZZJ珍珠姐国旗,B11(手机壳),'
      'ZGR中国人地毯(SAFARI CARPETS),C37,G51,A10,B58枪店,C17眼镜,M30,B08毛毯城,'
      'A407毛线,JJD(约堡家具店),C4,G42,C24C25,A107,E18,N113,B13,A410(A4-10),B10,'
      'C08,JIAOHUI教会家具店,C34,B59,F10C(f10c),WH208,WH219,WH227,F21,LSX隆升行';

  /// 补货服务器地址（如 http://192.168.1.100）
  final String serverUrl;

  /// 供货商列表（逗号分隔）
  final String suppliers;

  /// 操作员姓名
  final String operatorName;

  const RestockConfig({
    this.serverUrl = '',
    this.suppliers = defaultSuppliers,
    this.operatorName = '',
  });

  RestockConfig copyWith({
    String? serverUrl,
    String? suppliers,
    String? operatorName,
  }) {
    return RestockConfig(
      serverUrl: serverUrl ?? this.serverUrl,
      suppliers: suppliers ?? this.suppliers,
      operatorName: operatorName ?? this.operatorName,
    );
  }

  Map<String, dynamic> toJson() => {
        'serverUrl': serverUrl,
        'suppliers': suppliers,
        'operatorName': operatorName,
      };

  factory RestockConfig.fromJson(Map<String, dynamic> json) => RestockConfig(
        serverUrl: json['serverUrl'] as String? ?? 'http://localhost',
        suppliers: json['suppliers'] as String? ?? '',
        operatorName: json['operatorName'] as String? ?? '',
      );

  /// 获取排序后的供货商列表
  List<String> get supplierList {
    if (suppliers.isEmpty) return [];
    return suppliers
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList()
      ..sort((a, b) => a.compareTo(b));
  }

  bool get isValid =>
      serverUrl.isNotEmpty && operatorName.isNotEmpty;
}

/// 门店配置模型
class StoreConfig {
  final String name;
  final String account;
  final String cashierJobNumber;
  final String password;
  final String baseUrl;

  const StoreConfig({
    this.name = '',
    this.account = '',
    this.cashierJobNumber = '',
    this.password = '',
    this.baseUrl = 'https://beta28.pospal.cn',
  });

  StoreConfig copyWith({
    String? name,
    String? account,
    String? cashierJobNumber,
    String? password,
    String? baseUrl,
  }) {
    return StoreConfig(
      name: name ?? this.name,
      account: account ?? this.account,
      cashierJobNumber: cashierJobNumber ?? this.cashierJobNumber,
      password: password ?? this.password,
      baseUrl: baseUrl ?? this.baseUrl,
    );
  }

  Map<String, dynamic> toJson() => {
        'name': name,
        'account': account,
        'cashierJobNumber': cashierJobNumber,
        'baseUrl': baseUrl,
      };

  /// 从 JSON 恢复（不含密码，密码单独加密存储）
  factory StoreConfig.fromJson(Map<String, dynamic> json) => StoreConfig(
        name: json['name'] as String? ?? '',
        account: json['account'] as String? ?? '',
        cashierJobNumber: json['cashierJobNumber'] as String? ?? '',
        baseUrl: json['baseUrl'] as String? ?? 'https://beta28.pospal.cn',
      );

  /// 门店唯一标识（用于 Cookie 存储 key）
  String get storeKey => '$baseUrl|$account|$cashierJobNumber';

  bool get isValid =>
      name.isNotEmpty &&
      account.isNotEmpty &&
      cashierJobNumber.isNotEmpty &&
      password.isNotEmpty;
}
