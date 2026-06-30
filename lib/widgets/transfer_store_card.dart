import 'package:flutter/material.dart';
import '../models/product_result.dart';
import '../utils/constants.dart';

/// 调货按钮标签类型
enum TransferBtnType {
  add,    // [+] 可点击
  swap,   // [⇄] 可点击，切换来源（3店中非参与店）
}

/// 带调货按钮的门店库存卡片（替换原 StoreCard）
class TransferStoreCard extends StatelessWidget {
  final String storeName;
  final StoreStockResult result;
  final int delta;
  final TransferBtnType btnType;
  final VoidCallback? onTap;
  final bool disabled;

  const TransferStoreCard({
    super.key,
    required this.storeName,
    required this.result,
    this.delta = 0,
    this.btnType = TransferBtnType.add,
    this.onTap,
    this.disabled = false,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 3, vertical: 2),
      elevation: delta != 0 ? 2 : 1,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppConstants.radiusSm),
        side: delta != 0
            ? BorderSide(
                color: delta > 0 ? Colors.green : Colors.red,
                width: 1.5,
              )
            : BorderSide.none,
      ),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 4),
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
            const SizedBox(height: 1),
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
            // 变动量显示
            if (delta != 0)
              Padding(
                padding: const EdgeInsets.only(top: 3),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(
                    color: delta > 0 ? Colors.green : Colors.red,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    '${delta > 0 ? "+" : ""}$delta',
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            const SizedBox(height: 3),
            // 操作按钮
            _buildButton(),
          ],
        ),
      ),
    );
  }

  Widget _buildButton() {
    switch (btnType) {
      case TransferBtnType.add:
        return _circleBtn('+', Colors.white, disabled ? Colors.grey.shade300 : AppConstants.primaryColor, onTap);
      case TransferBtnType.swap:
        return _circleBtn('⇄', AppConstants.primaryColor, Colors.white, onTap);
    }
  }

  Widget _circleBtn(String text, Color fg, Color bg, VoidCallback? onPressed) {
    return GestureDetector(
      onTap: (onPressed != null && !disabled) ? onPressed : null,
      child: Container(
        width: 24,
        height: 24,
        decoration: BoxDecoration(
          color: bg,
          shape: BoxShape.circle,
          border: bg == Colors.white ? Border.all(color: AppConstants.primaryColor, width: 1.5) : null,
        ),
        alignment: Alignment.center,
        child: Text(
          text,
          style: TextStyle(
            fontSize: text.length > 1 ? 12 : 15,
            fontWeight: FontWeight.bold,
            color: fg,
          ),
        ),
      ),
    );
  }

  String _formatStock(double? stock) {
    if (stock == null) return '—';
    if (stock == stock.roundToDouble()) return stock.toInt().toString();
    return stock.toStringAsFixed(2);
  }

  Color _getStockColor(double? stock) {
    if (stock == null) return AppConstants.textSecondary;
    if (stock <= 0) return AppConstants.errorColor;
    if (stock < 10) return AppConstants.warningColor;
    return AppConstants.successColor;
  }
}
