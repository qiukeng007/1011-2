import 'package:flutter/material.dart';
import '../models/product_result.dart';
import '../utils/constants.dart';

/// 门店库存结果卡片
class StoreCard extends StatelessWidget {
  final String storeName;
  final StoreStockResult result;

  const StoreCard({
    super.key,
    required this.storeName,
    required this.result,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      elevation: 1,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppConstants.radiusSm),
      ),
      child: Container(
        width: 90,
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 门店名称
            Text(
              storeName,
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: AppConstants.textSecondary,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 2),
            // 库存数量
            if (result.ok && result.data != null)
              Text(
                _formatStock(result.data!.stock),
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: _getStockColor(result.data!.stock),
                ),
              )
            else
              const Text(
                '—',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: AppConstants.textSecondary,
                ),
              ),
            // 单位
            if (result.ok && result.data != null && result.data!.unit.isNotEmpty)
              Text(
                result.data!.unit,
                style: const TextStyle(
                  fontSize: 10,
                  color: AppConstants.textSecondary,
                ),
              ),
            // 错误信息
            if (!result.ok && result.error != null)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  result.error!,
                  style: const TextStyle(
                    fontSize: 10,
                    color: AppConstants.errorColor,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                ),
              ),
          ],
        ),
      ),
    );
  }

  String _formatStock(double? stock) {
    if (stock == null) return '—';
    if (stock == stock.roundToDouble()) {
      return stock.toInt().toString();
    }
    return stock.toStringAsFixed(2);
  }

  Color _getStockColor(double? stock) {
    if (stock == null) return AppConstants.textSecondary;
    if (stock <= 0) return AppConstants.errorColor;
    if (stock < 10) return AppConstants.warningColor;
    return AppConstants.successColor;
  }
}
