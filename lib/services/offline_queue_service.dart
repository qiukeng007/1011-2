import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';

/// 离线补货队列项：提交失败时本地备份，服务器恢复后自动补提交
class OfflineQueueItem {
  final String id;
  final String type; // replenish / booking
  final String shopName;
  final String barcode;
  final String quantity;
  final String desc;
  final String phone;
  final String imageBase64;
  final String imageName;
  final String createdAt;

  OfflineQueueItem({
    required this.id,
    required this.type,
    required this.shopName,
    required this.barcode,
    required this.quantity,
    required this.desc,
    this.phone = '',
    this.imageBase64 = '',
    this.imageName = '',
    required this.createdAt,
  });

  factory OfflineQueueItem.fromJson(Map<String, dynamic> json) {
    return OfflineQueueItem(
      id: json['id'] as String? ?? '',
      type: json['type'] as String? ?? 'replenish',
      shopName: json['shopName'] as String? ?? '',
      barcode: json['barcode'] as String? ?? '',
      quantity: json['quantity']?.toString() ?? '',
      desc: json['desc'] as String? ?? '',
      phone: json['phone'] as String? ?? '',
      imageBase64: json['imageBase64'] as String? ?? '',
      imageName: json['imageName'] as String? ?? '',
      createdAt: json['createdAt'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type,
        'shopName': shopName,
        'barcode': barcode,
        'quantity': quantity,
        'desc': desc,
        'phone': phone,
        'imageBase64': imageBase64,
        'imageName': imageName,
        'createdAt': createdAt,
      };
}

/// 离线队列存储：每个待提交项单独一个 JSON 文件（防止单文件损坏丢失全部）
class OfflineQueueService {
  static final OfflineQueueService instance = OfflineQueueService._();

  OfflineQueueService._();

  Future<Directory> _dir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir =
        Directory('${docs.path}${Platform.pathSeparator}offline_queue');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// 读取全部待提交项（按创建时间升序）
  Future<List<OfflineQueueItem>> getItems() async {
    try {
      final dir = await _dir();
      final files = dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.json'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
      final items = <OfflineQueueItem>[];
      for (final f in files) {
        try {
          final json =
              jsonDecode(await f.readAsString()) as Map<String, dynamic>;
          items.add(OfflineQueueItem.fromJson(json));
        } catch (_) {
          // 损坏文件跳过，不影响其他记录
        }
      }
      return items;
    } catch (_) {
      return [];
    }
  }

  /// 待提交数量
  Future<int> getPendingCount() async {
    return (await getItems()).length;
  }

  /// 新增一条待提交记录
  Future<bool> addItem(OfflineQueueItem item) async {
    try {
      final dir = await _dir();
      final file =
          File('${dir.path}${Platform.pathSeparator}${item.id}.json');
      await file.writeAsString(jsonEncode(item.toJson()), flush: true);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 移除一条已提交的记录
  Future<bool> removeItem(String id) async {
    try {
      final dir = await _dir();
      final file = File('${dir.path}${Platform.pathSeparator}$id.json');
      if (await file.exists()) {
        await file.delete();
      }
      return true;
    } catch (_) {
      return false;
    }
  }
}
