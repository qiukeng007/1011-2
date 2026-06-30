import 'package:flutter/material.dart';
import '../models/product_result.dart';
import '../widgets/store_card.dart';
import '../utils/constants.dart';

/// 数字转中文大写（一二三.五格式）
String _numberToChinese(double value) {
  const digits = ['零', '一', '二', '三', '四', '五', '六', '七', '八', '九'];
  final parts = value.toStringAsFixed(2).split('.');
  final intPart = parts[0];
  final decPart = parts[1];

  final buffer = StringBuffer();
  for (var i = 0; i < intPart.length; i++) {
    buffer.write(digits[intPart.codeUnitAt(i) - 0x30]);
  }
  buffer.write('点');
  for (var i = 0; i < decPart.length; i++) {
    buffer.write(digits[decPart.codeUnitAt(i) - 0x30]);
  }
  return buffer.toString();
}

/// 查询结果页面
class ResultPage extends StatelessWidget {
  final MultiStoreResult? result;
  final VoidCallback onNewQuery;

  const ResultPage({
    super.key,
    this.result,
    required this.onNewQuery,
  });

  @override
  Widget build(BuildContext context) {
    if (result == null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.search,
              size: 64,
              color: AppConstants.textSecondary.withValues(alpha: 0.3),
            ),
            const SizedBox(height: 16),
            const Text(
              '输入条码或扫码查询库存',
              style: TextStyle(
                fontSize: 15,
                color: AppConstants.textSecondary,
              ),
            ),
          ],
        ),
      );
    }

    final r = result!;
    // 找到第一个有数据的门店
    final firstData = r.stores.values
        .where((s) => s.ok && s.data != null && s.data!.name.isNotEmpty)
        .firstOrNull
        ?.data;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 商品信息区
          if (firstData != null) _buildProductInfo(firstData, r.barcode),

          // 多条结果提示
          if (firstData?.multipleMatches != null && firstData!.multipleMatches! > 1)
            _buildMultipleHint(firstData.multipleMatches!),

          // 多店库存横向排列
          const SizedBox(height: 12),
          const Text(
            '门店库存',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 100,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 2),
              children: r.stores.entries.map((entry) {
                return StoreCard(
                  storeName: entry.value.storeName,
                  result: entry.value,
                );
              }).toList(),
            ),
          ),

          // 查询耗时
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              '查询耗时：${r.elapsedSeconds.toStringAsFixed(2)} 秒',
              style: const TextStyle(
                fontSize: 12,
                color: AppConstants.textSecondary,
              ),
            ),
          ),

          // 调试面板
          if (firstData?.rawKeys != null)
            _buildDebugPanel(firstData!),

          // 全部未找到提示
          if (r.stores.values.every((s) => !s.ok || s.data?.name.isEmpty == true))
            _buildNotFoundHint(),

          const SizedBox(height: 16),

          // 再次查询按钮
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: onNewQuery,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('查询其他条码'),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppConstants.primaryColor,
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildProductInfo(ProductData data, String barcode) {
    return Card(
      elevation: 1,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppConstants.radiusMd),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 搜索条码（顶部显示，方便用户确认搜索的是什么）
            Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: AppConstants.primaryColor.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                '搜索条码: $barcode',
                style: const TextStyle(
                  fontSize: 12,
                  color: AppConstants.primaryColor,
                  fontFamily: 'monospace',
                ),
              ),
            ),
            // 商品名称
            Text(
              data.name.isNotEmpty ? data.name : '(未命名商品)',
              style: const TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 6),
            // 信息行
            _buildInfoRow(Icons.qr_code, '条码', data.barcode.isNotEmpty ? data.barcode : barcode),
            if (data.specification.isNotEmpty)
              _buildInfoRow(Icons.straighten, '规格', data.specification),
            if (data.supplier.isNotEmpty)
              _buildInfoRow(Icons.business, '供货商', data.supplier),
            _buildInfoRow(Icons.scale, '单位', data.unit),
            // 售价（醒目红色大字体，R前缀）
            if (data.sellPrice != null)
              _buildSellPriceRow(data.sellPrice!),
            // 进货价（中文大写数字）
            if (data.buyPrice != null)
              _buildBuyPriceRow(data.buyPrice!),
          ],
        ),
      ),
    );
  }

  Widget _buildInfoRow(IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        children: [
          Icon(icon, size: 14, color: AppConstants.textSecondary),
          const SizedBox(width: 6),
          Text(
            '$label：',
            style: const TextStyle(
              fontSize: 13,
              color: AppConstants.textSecondary,
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontSize: 13),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  /// 售价行 - 醒目红色大字体，R前缀
  Widget _buildSellPriceRow(double price) {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        children: [
          const Icon(Icons.monetization_on, size: 16, color: Colors.red),
          const SizedBox(width: 6),
          const Text(
            '售价：',
            style: TextStyle(
              fontSize: 13,
              color: AppConstants.textSecondary,
            ),
          ),
          Text(
            'R${price.toStringAsFixed(2)}',
            style: const TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.bold,
              color: Colors.red,
            ),
          ),
        ],
      ),
    );
  }

  /// 进货价行 - 中文大写数字
  Widget _buildBuyPriceRow(double price) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        children: [
          const Icon(Icons.shopping_cart, size: 14, color: AppConstants.textSecondary),
          const SizedBox(width: 6),
          const Text(
            '进货价：',
            style: TextStyle(
              fontSize: 13,
              color: AppConstants.textSecondary,
            ),
          ),
          Text(
            'R${_numberToChinese(price)}',
            style: const TextStyle(
              fontSize: 13,
              color: Color(0xFF8B4513), // 棕色
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMultipleHint(int count) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Card(
        color: AppConstants.warningColor.withValues(alpha: 0.1),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            children: [
              const Icon(Icons.warning_amber, color: AppConstants.warningColor, size: 18),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '查询到 $count 条匹配结果，当前显示第一条',
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppConstants.warningColor,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildNotFoundHint() {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Card(
        color: AppConstants.warningColor.withValues(alpha: 0.08),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              const Icon(Icons.info_outline, color: AppConstants.textSecondary, size: 18),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  '未找到该条码商品，或当前工号无商品查看权限',
                  style: TextStyle(
                    fontSize: 13,
                    color: AppConstants.textSecondary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDebugPanel(ProductData data) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Card(
        elevation: 0,
        color: AppConstants.bgColor,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppConstants.radiusSm),
          side: BorderSide(color: AppConstants.dividerColor),
        ),
        child: ExpansionTile(
          title: Text(
            '🔍 原始数据字段 (${data.rawKeys?.split(',').length ?? 0}个)',
            style: const TextStyle(fontSize: 12, color: AppConstants.textSecondary),
          ),
          dense: true,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 所有列原始数据（调试列索引偏移）
                  if (data.allColumns != null) ...[
                    Text(
                      '📊 HTML列数据:',
                      style: const TextStyle(
                        fontSize: 10,
                        fontFamily: 'monospace',
                        fontWeight: FontWeight.bold,
                        color: AppConstants.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      data.allColumns!,
                      style: const TextStyle(
                        fontSize: 9,
                        fontFamily: 'monospace',
                        color: AppConstants.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 6),
                  ],
                  Text(
                    '📋 原始字段:',
                    style: const TextStyle(
                      fontSize: 10,
                      fontFamily: 'monospace',
                      fontWeight: FontWeight.bold,
                      color: AppConstants.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    data.rawKeys ?? '',
                    style: const TextStyle(
                      fontSize: 10,
                      fontFamily: 'monospace',
                      color: AppConstants.textSecondary,
                    ),
                  ),
                  if (data.numericFields != null && data.numericFields!.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      '🔢 数字字段: ${data.numericFields}',
                      style: const TextStyle(
                        fontSize: 10,
                        fontFamily: 'monospace',
                        color: AppConstants.textSecondary,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
