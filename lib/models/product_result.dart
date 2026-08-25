import 'query_log.dart';

/// 商品查询结果
class ProductResult {
  final bool ok;
  final ProductData? data;
  final String? error;

  const ProductResult({required this.ok, this.data, this.error});
}

/// 商品数据
class ProductData {
  final String barcode;
  final String name;
  final String specification;
  final String category;
  final double? stock;
  final String unit;
  final String supplier;
  final double? sellPrice;
  final double? buyPrice;
  final dynamic uid;

  /// 商品图片URL
  final String? imageUrl;

  /// 多条结果标记
  final int? multipleMatches;

  /// 多条匹配时的候选商品列表（供用户弹窗选择）
  final List<ProductData>? candidates;

  /// 调试字段
  final String? rawKeys;
  final String? numericFields;
  final bool parseFailed;
  final bool fromBrowser;

  /// HTML 表格所有列原始数据（用于调试列索引偏移问题）
  final String? allColumns;

  const ProductData({
    required this.barcode,
    this.name = '',
    this.specification = '',
    this.category = '',
    this.stock,
    this.unit = '—',
    this.supplier = '',
    this.sellPrice,
    this.buyPrice,
    this.uid,
    this.imageUrl,
    this.multipleMatches,
    this.candidates,
    this.rawKeys,
    this.numericFields,
    this.parseFailed = false,
    this.fromBrowser = false,
    this.allColumns,
  });

  /// 复制一份并修改部分字段（用于附加多条匹配的候选列表）
  ProductData copyWith({
    String? barcode,
    String? name,
    String? specification,
    String? category,
    double? stock,
    String? unit,
    String? supplier,
    double? sellPrice,
    double? buyPrice,
    dynamic uid,
    String? imageUrl,
    int? multipleMatches,
    List<ProductData>? candidates,
    String? allColumns,
  }) {
    return ProductData(
      barcode: barcode ?? this.barcode,
      name: name ?? this.name,
      specification: specification ?? this.specification,
      category: category ?? this.category,
      stock: stock ?? this.stock,
      unit: unit ?? this.unit,
      supplier: supplier ?? this.supplier,
      sellPrice: sellPrice ?? this.sellPrice,
      buyPrice: buyPrice ?? this.buyPrice,
      uid: uid ?? this.uid,
      imageUrl: imageUrl ?? this.imageUrl,
      multipleMatches: multipleMatches ?? this.multipleMatches,
      candidates: candidates ?? this.candidates,
      rawKeys: rawKeys,
      numericFields: numericFields,
      parseFailed: parseFailed,
      fromBrowser: fromBrowser,
      allColumns: allColumns ?? this.allColumns,
    );
  }

  factory ProductData.fromRaw(Map<String, dynamic> raw, String barcode) {    return ProductData(
      barcode: _strVal(raw, ['barcode', 'Barcode', 'productBarcode', 'ProductBarcode']) ?? barcode,
      name: _strVal(raw, ['name', 'Name', 'productName', 'ProductName']) ?? '',
      specification: _strVal(raw, [
        'specification', 'Specification', 'attribute6', 'Attribute6',
        'spec', 'Spec',
      ]) ?? '',
      category: _strVal(raw, ['categoryName', 'CategoryName', 'category', 'Category']) ?? '',
      stock: _numVal(raw, [
        'stock', 'Stock', 'stockQuantity', 'StockQuantity',
        'inventory', 'Inventory', 'quantity', 'Quantity',
        'currentStock', 'CurrentStock', 'storeQuantity', 'StoreQuantity',
        'availableStock', 'AvailableStock', 'realStock', 'RealStock',
      ]),
      unit: _strVal(raw, [
        'baseUnitName', 'BaseUnitName', 'unitName', 'UnitName',
        'productUnitName', 'ProductUnitName', 'unit', 'Unit',
        'baseUnit', 'BaseUnit', 'measureUnit', 'MeasureUnit',
      ]) ?? '—',
      supplier: _strVal(raw, [
        'supplierName', 'SupplierName', 'supplier', 'Supplier',
        'vendor', 'Vendor', 'provider', 'Provider',
      ]) ?? '',
      sellPrice: _numVal(raw, [
        'sellPrice', 'SellPrice', 'salePrice', 'SalePrice',
        'sellingPrice', 'SellingPrice', 'retailPrice', 'RetailPrice',
        'price', 'Price',
      ]),
      buyPrice: _numVal(raw, [
        'buyPrice', 'BuyPrice', 'purchasePrice', 'PurchasePrice',
        'costPrice', 'CostPrice', 'buyingPrice', 'BuyingPrice',
      ]),
      uid: raw['uid'] ?? raw['Uid'] ?? raw['id'] ?? raw['Id'],
      rawKeys: raw.keys.join(','),
    );
  }

  /// 智能库存匹配（当常规字段未匹配到时，从原始数据中找数字字段）
  static double? smartFindStock(Map<String, dynamic> raw) {
    const priceFields = [
      'sellPrice', 'SellPrice', 'salePrice', 'SalePrice',
      'sellingPrice', 'SellingPrice', 'retailPrice', 'RetailPrice',
      'price', 'Price',
      'buyPrice', 'BuyPrice', 'purchasePrice', 'PurchasePrice',
      'costPrice', 'CostPrice',
      'memberPrice', 'MemberPrice', 'vipPrice', 'VipPrice',
    ];

    final numericFields = <String, double>{};
    for (final entry in raw.entries) {
      if (entry.value is num) {
        numericFields[entry.key] = (entry.value as num).toDouble();
      }
    }

    // 1. 找名称含 stock/quantity/inventory 的非价格字段
    for (final entry in numericFields.entries) {
      final lk = entry.key.toLowerCase();
      if (priceFields.any((p) => p.toLowerCase() == lk)) continue;
      if (RegExp(r'stock|quantity|inventory|库存|数量|qty|store').hasMatch(lk)) {
        return entry.value;
      }
    }

    // 2. 取第一个非价格数字字段
    for (final entry in numericFields.entries) {
      final lk = entry.key.toLowerCase();
      if (priceFields.any((p) => p.toLowerCase() == lk)) continue;
      return entry.value;
    }

    // 3. 取第一个数字字段
    if (numericFields.isNotEmpty) {
      return numericFields.values.first;
    }

    return null;
  }

  static String? _strVal(Map<String, dynamic> obj, List<String> keys) {
    for (final k in keys) {
      final v = obj[k];
      if (v != null && v.toString().isNotEmpty) return v.toString();
    }
    // 大小写不敏感匹配
    final lowerKeys = keys.map((k) => k.toLowerCase()).toSet();
    for (final entry in obj.entries) {
      if (lowerKeys.contains(entry.key.toLowerCase())) {
        final v = entry.value;
        if (v != null && v.toString().isNotEmpty) return v.toString();
      }
    }
    return null;
  }

  static double? _numVal(Map<String, dynamic> obj, List<String> keys) {
    for (final k in keys) {
      final v = obj[k];
      if (v is num) return v.toDouble();
    }
    // 大小写不敏感匹配
    final lowerKeys = keys.map((k) => k.toLowerCase()).toSet();
    for (final entry in obj.entries) {
      if (lowerKeys.contains(entry.key.toLowerCase()) && entry.value is num) {
        return (entry.value as num).toDouble();
      }
    }
    return null;
  }
}

/// 多门店查询结果
class MultiStoreResult {
  final String barcode;
  final Map<String, StoreStockResult> stores;
  final double elapsedSeconds;

  /// 本次 queryAllStores 的诊断数据（含每步耗时），供上层合并日志用
  final List<StoreQueryDiagnostics>? diagnostics;

  const MultiStoreResult({
    required this.barcode,
    required this.stores,
    required this.elapsedSeconds,
    this.diagnostics,
  });
}

/// 单个门店的查询结果
class StoreStockResult {
  final String storeName;
  final ProductData? data;
  final String? error;
  final bool ok;

  const StoreStockResult({
    required this.storeName,
    this.data,
    this.error,
    required this.ok,
  });
}
