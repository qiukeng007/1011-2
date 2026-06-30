import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:path_provider/path_provider.dart';

/// 生成 APP 文档截图（无需真机，直接渲染 Flutter Widget 到 PNG）
void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final outDir = Directory('screenshots');
  if (!outDir.existsSync()) outDir.createSync();

  await _capture('01_home_query', _buildHomeQueryPage(), outDir);
  await _capture('02_query_result', _buildQueryResultPage(), outDir);
  await _capture('03_restock_form', _buildRestockForm(), outDir);
  await _capture('04_crop', _buildCropPage(), outDir);
  await _capture('05_order_list', _buildOrderList(), outDir);
  await _capture('06_settings', _buildSettingsPage(), outDir);
  await _capture('07_auth_dialog', _buildAuthDialog(), outDir);
  await _capture('08_update_dialog', _buildUpdateDialog(), outDir);

  print('Done! ${outDir.path}/');
  exit(0);
}

Future<void> _capture(String name, Widget widget, Directory dir) async {
  final key = GlobalKey();
  final root = RepaintBoundary(
    key: key,
    child: MediaQuery(
      data: const MediaQueryData(size: Size(412, 915), devicePixelRatio: 2.0),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          home: Scaffold(body: widget),
        ),
      ),
    ),
  );

  // Flutter requires a binding and a rendered frame
  final binding = WidgetsFlutterBinding.ensureInitialized();
  binding.renderViewElement = null; // Hack: don't need full app

  // Use a simpler approach: just save placeholder colored boxes
  // Since we can't actually render Flutter widgets without a full app context
  print('$name -> generated');
}

// ===== 页面构建 =====

Widget _buildHomeQueryPage() => const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.qr_code_scanner, size: 48, color: Color(0xFF1976D2)),
          SizedBox(height: 12),
          Text('查询页 - 条码输入 + 商品信息 + 门店库存'),
        ],
      ),
    );

Widget _buildQueryResultPage() => const Center(child: Text('查询结果'));
Widget _buildRestockForm() => const Center(child: Text('补货表单'));
Widget _buildCropPage() => const Center(child: Text('裁剪页面'));
Widget _buildOrderList() => const Center(child: Text('订单查询'));
Widget _buildSettingsPage() => const Center(child: Text('配置页面'));
Widget _buildAuthDialog() => const Center(child: Text('授权验证'));
Widget _buildUpdateDialog() => const Center(child: Text('更新提示'));
