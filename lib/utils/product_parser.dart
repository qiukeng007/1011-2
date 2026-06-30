import '../models/product_result.dart';

/// 商品数据解析工具
/// 移植自 server/product-utils.js + server/pospal.js 的智能库存匹配逻辑
class ProductParser {
  /// 从 API 响应中提取商品列表
  static List<Map<String, dynamic>> pickProductList(Map<String, dynamic> payload) {
    if (payload.isEmpty) return [];

    // 如果本身就是数组
    if (payload case List<Map<String, dynamic>> list) return list;

    for (final k in ['data', 'Data', 'result', 'Result', 'products', 'Products', 'rows', 'Rows', 'list', 'List']) {
      final v = payload[k];
      if (v is List) {
        return v.cast<Map<String, dynamic>>();
      }
    }
    return [];
  }

  /// 在列表中按条码查找
  static Map<String, dynamic>? findByBarcodeInList(
    List<Map<String, dynamic>> list,
    String code,
  ) {
    for (final p in list) {
      for (final k in ['barcode', 'Barcode', 'productBarcode', 'ProductBarcode']) {
        final v = p[k];
        if (v != null && v.toString().trim() == code) {
          return p;
        }
      }
    }
    return null;
  }

  /// 查找列表中所有匹配该条码的商品（用于检测多条结果）
  static List<Map<String, dynamic>> findAllByBarcode(
    List<Map<String, dynamic>> list,
    String code,
  ) {
    return list.where((p) {
      for (final k in ['barcode', 'Barcode', 'productBarcode', 'ProductBarcode']) {
        final v = p[k];
        if (v != null && v.toString().trim() == code) return true;
      }
      return false;
    }).toList();
  }

  /// 标准化商品数据
  static ProductData normalize(Map<String, dynamic> raw, String barcode) {
    return ProductData.fromRaw(raw, barcode);
  }

  /// 完整解析：尝试标准化，如果失败则使用智能匹配 fallback
  static ProductData parseWithFallback(Map<String, dynamic> raw, String barcode) {
    final product = ProductData.fromRaw(raw, barcode);

    // 如果常规字段没匹配到库存，使用智能匹配
    if (product.stock == null) {
      final smartStock = ProductData.smartFindStock(raw);
      if (smartStock != null) {
        // 需要重建 ProductData 因为是不可变的
        return ProductData(
          barcode: product.barcode,
          name: product.name,
          specification: product.specification,
          category: product.category,
          stock: smartStock,
          unit: product.unit,
          supplier: product.supplier,
          sellPrice: product.sellPrice,
          buyPrice: product.buyPrice,
          uid: product.uid,
          rawKeys: product.rawKeys,
          numericFields: _extractNumericFields(raw),
        );
      }
    }

    // 补充 supplier / unit（可能大小写不匹配）
    final supplier = product.supplier.isNotEmpty
        ? product.supplier
        : _findAny(raw, ['supplierName', 'SupplierName', 'supplier', 'Supplier', 'vendor', 'Vendor']);
    final unit = (product.unit.isNotEmpty && product.unit != '—')
        ? product.unit
        : _findAny(raw, [
            'baseUnitName', 'BaseUnitName', 'unitName', 'UnitName',
            'productUnitName', 'ProductUnitName', 'unit', 'Unit',
          ]) ??
            '—';

    return ProductData(
      barcode: product.barcode,
      name: product.name,
      specification: product.specification,
      category: product.category,
      stock: product.stock,
      unit: unit,
      supplier: supplier ?? '',
      sellPrice: product.sellPrice,
      buyPrice: product.buyPrice,
      uid: product.uid,
      rawKeys: product.rawKeys,
      numericFields: _extractNumericFields(raw),
    );
  }

  /// 创建解析失败的 fallback 数据
  static ProductData createFallback(Map<String, dynamic> raw, String barcode) {
    final stock = ProductData.smartFindStock(raw);
    final supplier = _findAny(raw, [
      'supplierName', 'SupplierName', 'supplier', 'Supplier', 'vendor', 'Vendor',
    ]) ?? '';
    final unit = _findAny(raw, [
      'baseUnitName', 'BaseUnitName', 'unitName', 'UnitName',
      'productUnitName', 'ProductUnitName', 'unit', 'Unit',
    ]) ?? '—';

    return ProductData(
      barcode: _findAny(raw, ['barcode', 'Barcode', 'productBarcode', 'ProductBarcode']) ?? barcode,
      name: _findAny(raw, ['name', 'Name', 'productName', 'ProductName']) ?? '',
      specification: _findAny(raw, ['specification', 'Specification', 'spec', 'Spec']) ?? '',
      stock: stock,
      unit: unit,
      supplier: supplier,
      rawKeys: raw.keys.join(','),
      numericFields: _extractNumericFields(raw),
      parseFailed: true,
    );
  }

  /// 提取所有数字字段（用于调试）
  static String _extractNumericFields(Map<String, dynamic> raw) {
    final fields = <String, dynamic>{};
    for (final entry in raw.entries) {
      if (entry.value is num) {
        fields[entry.key] = entry.value;
      }
    }
    return fields.entries.map((e) => '${e.key}: ${e.value}').join(', ');
  }

  /// 从对象中按多个 key 查找值（大小写不敏感）
  static String? _findAny(Map<String, dynamic> obj, List<String> keys) {
    for (final k in keys) {
      final v = obj[k];
      if (v != null && v.toString().isNotEmpty) return v.toString();
    }
    final lowerKeys = keys.map((k) => k.toLowerCase()).toSet();
    for (final entry in obj.entries) {
      if (lowerKeys.contains(entry.key.toLowerCase())) {
        final v = entry.value;
        if (v != null && v.toString().isNotEmpty) return v.toString();
      }
    }
    return null;
  }
}
