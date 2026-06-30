import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import '../models/printer_config.dart';
import '../models/product_result.dart';

/// 标签打印服务 — TSPL + ZPL 双协议
class PrintService {
  static int mmToDot(double mm, [int dpi = 180]) => (mm / 25.4 * dpi).round();

  Uint8List buildCommand(PrinterConfig cfg, ProductData p, {bool showPrice = true, int qty = 1}) {
    if (cfg.protocol == 'zpl') return buildZpl(cfg, p, showPrice: showPrice, qty: qty);
    return Uint8List.fromList(utf8.encode(buildTspl(cfg, p, showPrice: showPrice, qty: qty)));
  }

  // ====== TSPL ======

  String buildTspl(PrinterConfig cfg, ProductData p, {bool showPrice = true, int qty = 1}) {
    final dpi = cfg.dpi;
    final labelW = cfg.labelWidth.toInt();
    final labelH = cfg.labelHeight.toInt();
    final totalW = cfg.doubleColumn ? labelW * 2 : labelW;

    final buf = StringBuffer();
    buf.writeln('SIZE $totalW mm,$labelH mm');
    buf.writeln('GAP 2 mm,0');
    buf.writeln('DENSITY ${cfg.labelWidth <= 35 ? 12 : 8}');
    buf.writeln('DIRECTION 0');
    buf.writeln('CLS');
    _tsplEl(buf, cfg, p, dpi, 0, showPrice, isRight: false);
    if (cfg.doubleColumn) _tsplEl(buf, cfg, p, dpi, 0, showPrice, isRight: true);
    buf.writeln('PRINT $qty');
    return buf.toString();
  }

  void _tsplEl(StringBuffer b, PrinterConfig c, ProductData p, int dpi, int ox, bool sp, {bool isRight = false}) {
    final preset = c.fontPreset;
    final labelW = mmToDot(c.labelWidth, dpi);
    final colW = mmToDot(c.labelWidth, dpi);
    final tiny = c.labelHeight <= 15;
    for (final e in c.elements) {
      if (tiny && e.type == 'name' && sp && c.elements.any((x) => x.type == 'price')) continue;
      var x = mmToDot(e.x, dpi) + ox;
      if (isRight) x += colW + mmToDot(e.rightOffset, dpi);
      final y = mmToDot(e.y, dpi);
      switch (e.type) {
        case 'barcode':
          final bh = mmToDot(e.height ?? 8, dpi);
          final bx = mmToDot(1, dpi) + ox; // X=1mm 极限左移
          if (c.barcodeType == 'ean13' && p.barcode.length >= 11 && p.barcode.length <= 13) {
            final raw = p.barcode.replaceAll(RegExp(r'[^0-9]'), '');
            final ean = raw.length >= 13 ? raw.substring(0, 12) : raw.padLeft(12, '0');
            b.writeln('BARCODE $bx,$y,"EAN13",$bh,0,0,2,2,"$ean"');
          } else {
            // 自动计算窄线: 条码估算宽 > 可用宽90% → 用narrow=1
            final estimatedDots = (p.barcode.length + 5) * 11 * 2; // narrow=2估算
            final availableDots = mmToDot(c.labelWidth - 2, dpi); // 留2mm边距
            final n = estimatedDots > availableDots * 0.9 ? 1 : c.barcodeNarrow;
            b.writeln('BARCODE $bx,$y,"128",$bh,0,0,$n,$n,"${p.barcode}"');
          }
          break;
        case 'name':
          _tsplT(b, x, y, e.fontSize, e.bold, p.name.isNotEmpty ? p.name : p.barcode);
          break;
        case 'price':
          if (sp && p.sellPrice != null) _tsplT(b, x, y, e.fontSize, e.bold, 'R${p.sellPrice!.toStringAsFixed(2)}');
          break;
        case 'supplier':
          if (p.supplier.isNotEmpty) _tsplT(b, x, y, e.fontSize, e.bold, p.supplier);
          break;
        case 'barcodeNumber':
          _tsplT(b, x, y, e.fontSize, e.bold, p.barcode);
          break;
        case 'spec':
          if (p.specification.isNotEmpty) _tsplT(b, x, y, e.fontSize, e.bold, p.specification);
          break;
        case 'unit':
          if (p.unit.isNotEmpty && p.unit != '—') _tsplT(b, x, y, e.fontSize, e.bold, p.unit);
          break;
      }
    }
  }

  void _tsplT(StringBuffer b, int x, int y, int fs, bool bold, String text, {int preset = 0}) {
    // 计算每行最大字符数
    final maxChars = 40 * 16 ~/ fs.clamp(8, 48);
    final lines = _wrapText(text, maxChars, 2);

    String font; int mul;
    // 字体方案选择
    switch (preset) {
      case 1: font = bold ? '2' : '2'; mul = (fs / 14.0).round().clamp(1, 5); break; // 中等粗体
      case 2: font = 'TSS24.BF2'; mul = (fs / 20.0).round().clamp(1, 4); break;   // 大号TSS
      case 3: font = 'TSS24.BF2'; mul = (fs / 16.0).round().clamp(1, 5); break;   // 超大TSS
      default: // 默认方案
        if (fs >= 28) { font = 'TSS24.BF2'; mul = (fs / 24.0).round().clamp(1, 4); }
        else { font = bold ? '2' : '1'; mul = (fs <= 12) ? 1 : (fs <= 20 ? 2 : (fs <= 30 ? 3 : (fs <= 42 ? 4 : 5))); }
    }
    final lineH = (8 * mul).round();
    for (var i = 0; i < lines.length; i++) {
      b.writeln('TEXT $x,${y + i * lineH},"$font",0,$mul,$mul,"${lines[i]}"');
    }
  }

  List<String> _wrapText(String text, int maxChars, int maxLines) {
    if (text.length <= maxChars) return [text];
    final result = <String>[];
    var remaining = text;
    for (var i = 0; i < maxLines && remaining.isNotEmpty; i++) {
      if (remaining.length <= maxChars) {
        result.add(remaining);
        break;
      }
      var cut = maxChars;
      // 尝试在空格处断句
      final spaceIdx = remaining.lastIndexOf(' ', maxChars);
      if (spaceIdx > maxChars ~/ 2) cut = spaceIdx;
      result.add(remaining.substring(0, cut).trim());
      remaining = remaining.substring(cut).trim();
    }
    return result;
  }

  // ====== ZPL ======

  Uint8List buildZpl(PrinterConfig cfg, ProductData p, {bool showPrice = true, int qty = 1}) {
    final dpi = cfg.dpi;
    final w = mmToDot(cfg.labelWidth, dpi);
    final h = mmToDot(cfg.labelHeight, dpi);
    final tw = cfg.doubleColumn ? w * 2 + mmToDot(2, dpi) : w;

    final buf = StringBuffer();
    buf.writeln('^XA');
    buf.writeln('^PW$tw');
    buf.writeln('^LL$h');

    _zplEl(buf, cfg, p, dpi, 0, showPrice, isRight: false);
    if (cfg.doubleColumn) _zplEl(buf, cfg, p, dpi, 0, showPrice, isRight: true);

    buf.writeln('^PQ$qty');
    buf.writeln('^XZ');
    return Uint8List.fromList(utf8.encode(buf.toString()));
  }

  void _zplEl(StringBuffer b, PrinterConfig c, ProductData p, int dpi, int ox, bool sp, {bool isRight = false}) {
    final labelW = mmToDot(c.labelWidth, dpi);
    final colW = mmToDot(c.labelWidth, dpi);
    final tiny = c.labelHeight <= 15;
    for (final e in c.elements) {
      if (tiny && e.type == 'name' && sp && c.elements.any((x) => x.type == 'price')) continue;
      var x = mmToDot(e.x, dpi) + ox;
      if (isRight) x += colW + mmToDot(e.rightOffset, dpi);
      final y = mmToDot(e.y, dpi);
      switch (e.type) {
        case 'barcode':
          final bh = mmToDot(e.height ?? 8, dpi);
          final n = c.barcodeNarrow;
          // ^BY narrow,ratio,height — ^BC = CODE128
          b.writeln('^FO$x,$y^BY$n,2.0,$bh^BCN,$bh,N,N,N^FD${p.barcode}^FS');
          break;
        case 'name':
          _zplT(b, x, y, e.fontSize, e.bold, p.name.isNotEmpty ? p.name : p.barcode);
          break;
        case 'price':
          if (sp && p.sellPrice != null) _zplT(b, x, y, e.fontSize, e.bold, 'R${p.sellPrice!.toStringAsFixed(2)}');
          break;
        case 'supplier':
          if (p.supplier.isNotEmpty) _zplT(b, x, y, e.fontSize, e.bold, p.supplier);
          break;
        case 'barcodeNumber':
          _zplT(b, x, y, e.fontSize, e.bold, p.barcode);
          break;
        case 'spec':
          if (p.specification.isNotEmpty) _zplT(b, x, y, e.fontSize, e.bold, p.specification);
          break;
        case 'unit':
          if (p.unit.isNotEmpty && p.unit != '—') _zplT(b, x, y, e.fontSize, e.bold, p.unit);
          break;
      }
    }
  }

  void _zplT(StringBuffer b, int x, int y, int fs, bool bold, String text) {
    // ZPL font: ^A0N = scalable, height in dots, width in dots
    final h = (fs * 1.6).round();
    final w = (fs * 1.0).round();
    b.writeln('^FO$x,$y^A0N,$h,$w^FD$text^FS');
  }

  Future<String?> print(PrinterConfig config, ProductData product, {bool showPrice = true, int qty = 1}) async {
    try {
      final cmd = buildCommand(config, product, showPrice: showPrice, qty: qty);
      final socket = await Socket.connect(config.ip, config.port, timeout: const Duration(seconds: 5));
      socket.add(cmd);
      await socket.flush();
      socket.destroy();
      return null;
    } catch (e) {
      return '打印失败: $e';
    }
  }

  Future<bool> testConnection(String ip, int port) async {
    try { final s = await Socket.connect(ip, port, timeout: const Duration(seconds: 3)); s.destroy(); return true; } catch (_) { return false; }
  }
}
