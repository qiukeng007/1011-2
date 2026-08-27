/// 商品库存变动记录（银豹 /Inventory/LoadStockChangeHistory 返回）
class StockChangeRecord {
  final int index;
  final String time;
  final String operator;
  final String changeType;
  final double? stockChange;
  final double? correctedStock;
  final String remark;

  const StockChangeRecord({
    required this.index,
    required this.time,
    required this.operator,
    required this.changeType,
    this.stockChange,
    this.correctedStock,
    required this.remark,
  });
}

/// 单个门店的库存变动查询结果
class StockHistoryResult {
  final String storeId;
  final String storeName;
  final List<StockChangeRecord> records;
  final String? error;

  const StockHistoryResult({
    required this.storeId,
    required this.storeName,
    this.records = const [],
    this.error,
  });
}
