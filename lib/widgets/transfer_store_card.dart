import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/product_result.dart';
import '../utils/constants.dart';

enum TransferBtnType { add, swap }

class TransferStoreCard extends StatefulWidget {
  final String storeName;
  final StoreStockResult result;
  final int delta;
  final TransferBtnType btnType;
  final VoidCallback? onTap;
  final bool disabled;
  final VoidCallback? onDoubleTap;
  final bool isEditing;
  final TextEditingController? stockController;
  final VoidCallback? onEditConfirm;

  const TransferStoreCard({
    super.key,
    required this.storeName,
    required this.result,
    this.delta = 0,
    this.btnType = TransferBtnType.add,
    this.onTap,
    this.disabled = false,
    this.onDoubleTap,
    this.isEditing = false,
    this.stockController,
    this.onEditConfirm,
  });

  @override
  State<TransferStoreCard> createState() => _TransferStoreCardState();
}

class _TransferStoreCardState extends State<TransferStoreCard> {
  DateTime? _lastTapTime;

  /// 手动双击检测：避免父级双击手势延迟子级按钮点击
  void _handleCardTap() {
    final now = DateTime.now();
    if (_lastTapTime != null &&
        now.difference(_lastTapTime!) < const Duration(milliseconds: 350)) {
      _lastTapTime = null;
      widget.onDoubleTap?.call();
      return;
    }
    _lastTapTime = now;
  }

  @override
  Widget build(BuildContext context) {
    final result = widget.result;
    final delta = widget.delta;
    final isEditing = widget.isEditing;

    return GestureDetector(
      onTap: _handleCardTap,
      child: Card(
        margin: const EdgeInsets.symmetric(horizontal: 3, vertical: 2),
        elevation: delta != 0 ? 2 : (isEditing ? 3 : 1),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppConstants.radiusSm),
          side: isEditing
              ? const BorderSide(color: AppConstants.primaryColor, width: 2)
              : delta != 0
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
              Text(
                widget.storeName,
                style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppConstants.textSecondary),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 1),
              if (isEditing && widget.stockController != null)
                SizedBox(
                  width: 72,
                  height: 28,
                  child: TextField(
                    controller: widget.stockController,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                    decoration: const InputDecoration(
                      contentPadding: EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    autofocus: true,
                    inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[\d.]'))],
                    onSubmitted: (_) => widget.onEditConfirm?.call(),
                  ),
                )
              else if (result.ok && result.data != null)
                Text(
                  _formatStock(result.data!.stock),
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: _getStockColor(result.data!.stock)),
                )
              else
                const Text('—', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: AppConstants.textSecondary)),
              if (result.ok && result.data != null && result.data!.unit.isNotEmpty)
                Text(result.data!.unit, style: const TextStyle(fontSize: 10, color: AppConstants.textSecondary)),
              if (!result.ok && result.error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(result.error!, style: const TextStyle(fontSize: 10, color: AppConstants.errorColor), maxLines: 2, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center),
                ),
              if (delta != 0)
                Padding(
                  padding: const EdgeInsets.only(top: 3),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                    decoration: BoxDecoration(color: delta > 0 ? Colors.green : Colors.red, borderRadius: BorderRadius.circular(8)),
                    child: Text('${delta > 0 ? "+" : ""}$delta', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.white)),
                  ),
                ),
              const SizedBox(height: 3),
              _buildButton(isEditing),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildButton(bool isEditing) {
    if (isEditing) {
      return _circleBtn('✓', Colors.white, AppConstants.primaryColor, widget.onEditConfirm);
    }
    switch (widget.btnType) {
      case TransferBtnType.add:
        return _circleBtn('+', Colors.white, widget.disabled ? Colors.grey.shade300 : AppConstants.primaryColor, widget.onTap);
      case TransferBtnType.swap:
        return _circleBtn('⇄', AppConstants.primaryColor, Colors.white, widget.onTap);
    }
  }

  Widget _circleBtn(String text, Color fg, Color bg, VoidCallback? onPressed) {
    return GestureDetector(
      onTap: (onPressed != null && !widget.disabled) ? onPressed : null,
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: 40, height: 40,
        decoration: BoxDecoration(color: bg, shape: BoxShape.circle,
          border: bg == Colors.white ? Border.all(color: AppConstants.primaryColor, width: 1.5) : null),
        alignment: Alignment.center,
        child: Text(text, style: TextStyle(fontSize: text.length > 1 ? 15 : 22, fontWeight: FontWeight.bold, color: fg)),
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
