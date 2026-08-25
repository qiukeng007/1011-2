import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/store_config.dart';

/// 补货/预定/订单查询 服务
/// 与本地 WebServer (WebServer.exe) 通信
class RestockService {
  final RestockConfig _config;

  RestockService(this._config);

  /// 获取供货商列表
  /// 供货商列表是否来自银豹自动获取（只读，不可手动修改）
  bool get suppliersReadonly => _config.suppliersReadonly;

  /// 供货商列表是否为手动模式（手动写入且未排序，需要静默获取 UID）
  bool get suppliersManualMode => _config.suppliersManualMode;

  List<String> get suppliers => _config.supplierList;

  /// 获取操作员姓名
  String get operatorName => _config.operatorName;

  /// 更新操作员姓名并持久化
  Future<void> updateOperatorName(String name) async {
    final updated = _config.copyWith(operatorName: name);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('restock_config', jsonEncode(updated.toJson()));
  }

  /// 补货服务器地址（自动补全 http://，自动降级 https→http）
  String get serverUrl {
    var url = _config.serverUrl.trim();
    if (url.isEmpty) return url;
    // 去掉末尾斜杠
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    // https → http（本地服务器不支持 SSL）
    if (url.startsWith('https://')) {
      url = 'http://${url.substring(8)}';
    }
    // 自动补全协议前缀
    if (!url.startsWith('http://')) {
      url = 'http://$url';
    }
    return url;
  }

  /// 提交补货单
  Future<bool> submitReplenish({
    required String shopName,
    String barcode = '',
    required int quantity,
    String desc = '',
    List<int>? imageBytes,
    String? imageName,
  }) async {
    return _submitForm(
      endpoint: 'replenish',
      shopName: shopName,
      barcode: barcode,
      quantity: quantity,
      desc: desc,
      imageBytes: imageBytes,
      imageName: imageName,
    );
  }

  /// 提交顾客预定
  Future<bool> submitBooking({
    String? shopName,
    required String phone,
    String barcode = '',
    required int quantity,
    required String desc,
    List<int>? imageBytes,
    String? imageName,
  }) async {
    return _submitForm(
      endpoint: 'booking',
      shopName: shopName ?? '',
      barcode: barcode,
      quantity: quantity,
      desc: desc,
      phone: phone,
      imageBytes: imageBytes,
      imageName: imageName,
    );
  }

  /// 通用表单提交（手动构建 multipart 请求，确保编码兼容）
  Future<bool> _submitForm({
    required String endpoint,
    required String shopName,
    required String barcode,
    required int quantity,
    required String desc,
    String? phone,
    List<int>? imageBytes,
    String? imageName,
  }) async {
    try {
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 15);
      final uri = Uri.parse('${serverUrl}/index.esp?$endpoint');
      final request = await client.postUrl(uri);

      final boundary =
          '----FormBoundary${DateTime.now().millisecondsSinceEpoch}';
      request.headers.contentType = ContentType(
        'multipart',
        'form-data',
        parameters: {'boundary': boundary},
      );

      final body = <int>[];

      void addField(String name, String value) {
        body.addAll(utf8.encode('--$boundary\r\n'));
        body.addAll(utf8.encode(
            'Content-Disposition: form-data; name="$name"\r\n\r\n'));
        body.addAll(utf8.encode(value));
        body.addAll(utf8.encode('\r\n'));
      }

      addField('shopname', shopName.replaceAll('&', ''));
      addField('barcode', barcode.replaceAll('&', ''));
      addField('quantity', quantity.toString());
      addField('desc', desc.replaceAll('&', ''));
      final opName = _config.operatorName.isNotEmpty ? _config.operatorName : '未知操作员';
      addField('Operators', opName);
      if (phone != null && phone.isNotEmpty) {
        addField('phone', phone);
      }

      if (imageBytes != null && imageBytes.isNotEmpty) {
        body.addAll(utf8.encode('--$boundary\r\n'));
        body.addAll(utf8.encode(
            'Content-Disposition: form-data; name="image"; filename="${imageName ?? 'IMG_${DateTime.now().millisecondsSinceEpoch}.jpg'}"\r\n'));
        body.addAll(utf8.encode('Content-Type: image/jpeg\r\n\r\n'));
        body.addAll(imageBytes);
        body.addAll(utf8.encode('\r\n'));
      }

      body.addAll(utf8.encode('--$boundary--\r\n'));

      request.contentLength = body.length;
      request.add(body);

      final response = await request.close();
      return response.statusCode == 200;
    } catch (e) {
      return false;
    }
  }

  /// 查询订单记录
  Future<List<OrderRecord>> queryOrders({String searchKey = ''}) async {
    try {
      final uri = Uri.parse('${serverUrl}/index.esp?query_booking');
      final response = await http.post(
        uri,
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: 'key=${Uri.encodeComponent(searchKey)}',
      );

      if (response.statusCode != 200) return [];

      // 显式 UTF-8 解码，防止中文乱码
      final decoded = utf8.decode(response.bodyBytes);
      final data = json.decode(decoded) as List<dynamic>;
      return data.map((item) => OrderRecord.fromJson(item)).toList();
    } catch (e) {
      return [];
    }
  }

  /// 完结订单
  Future<bool> finishOrder(String id) async {
    try {
      final uri = Uri.parse('${serverUrl}/index.esp?finish_order');
      final response = await http.post(
        uri,
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body:
            'Id=${Uri.encodeComponent(id)}&operator=${Uri.encodeComponent(_config.operatorName.isNotEmpty ? _config.operatorName : '未知操作员')}',
      );
      return response.statusCode == 200;
    } catch (e) {
      return false;
    }
  }
}

/// 订单记录模型
class OrderRecord {
  final String? id;
  final String? shopname;
  final String? customerPhone;
  final String? productBarcode;
  final String? productDesc;
  final String? orderQty;
  final String? orderTime;
  final String? imagePath;

  OrderRecord({
    this.id,
    this.shopname,
    this.customerPhone,
    this.productBarcode,
    this.productDesc,
    this.orderQty,
    this.orderTime,
    this.imagePath,
  });

  factory OrderRecord.fromJson(Map<String, dynamic> json) {
    return OrderRecord(
      id: json['id']?.toString() ?? json['ID']?.toString(),
      shopname: json['shopname']?.toString(),
      customerPhone: json['顾客电话']?.toString(),
      productBarcode: json['商品条码']?.toString(),
      productDesc: json['商品说明']?.toString(),
      orderQty: json['预定数量']?.toString(),
      orderTime: json['预定时间']?.toString(),
      imagePath: json['图片地址']?.toString(),
    );
  }

  /// 获取可显示的图片 URL
  String get displayImageUrl {
    if (imagePath == null || imagePath!.isEmpty) return '';
    var src = imagePath!;
    if (src.contains('\\')) {
      src = '/PIC/${src.substring(src.lastIndexOf('\\') + 1)}';
    } else if (!src.startsWith('http')) {
      src = '/PIC/$src';
    }
    return src;
  }
}
