import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/printer_config.dart';
import '../models/product_result.dart';
import '../services/print_service.dart';

/// 打印机模板编辑页
class PrinterEditSheet extends StatefulWidget {
  final PrinterConfig printer;
  final void Function(PrinterConfig) onSave;

  const PrinterEditSheet({super.key, required this.printer, required this.onSave});

  @override
  State<PrinterEditSheet> createState() => _PrinterEditSheetState();
}

class _PrinterEditSheetState extends State<PrinterEditSheet> {
  late PrinterConfig _p;
  final _ctrls = <String, TextEditingController>{};

  TextEditingController _c(String key, String initial) {
    if (!_ctrls.containsKey(key)) {
      _ctrls[key] = TextEditingController(text: initial);
    }
    return _ctrls[key]!;
  }

  @override
  void initState() {
    super.initState();
    _p = widget.printer;
      }

  @override
  void dispose() {
    for (final c in _ctrls.values) { c.dispose(); }
    super.dispose();
  }

  static const _elemTypes = ['barcode', 'name', 'price', 'supplier', 'barcodeNumber', 'spec', 'unit'];
  static const _elemLabels = ['条码', '名称', '价格', '供货商', '条码数字', '规格', '单位'];

  Widget _buildPreview() {
    return Container(
      decoration: BoxDecoration(border: Border.all(color: Colors.grey.shade400), borderRadius: BorderRadius.circular(6)),
      padding: const EdgeInsets.all(8),
      margin: const EdgeInsets.only(bottom: 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('${_p.labelWidth.toInt()}×${_p.labelHeight.toInt()}mm  ${_p.doubleColumn ? "双列" : "单列"}  ${_p.dpi}DPI',
            style: const TextStyle(fontSize: 11, color: Colors.grey)),
        const Divider(),
        for (final e in _p.elements)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text('${_elemLabels[_elemTypes.indexOf(e.type)]}  (${e.x.toStringAsFixed(0)},${e.y.toStringAsFixed(0)}) 字${e.fontSize} ${e.bold?"粗":""}',
                style: const TextStyle(fontSize: 11)),
          ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final previewWidget = _buildPreview();
    return Container(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // 固定预览区
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Center(child: Container(width: 40, height: 4, margin: const EdgeInsets.only(bottom: 12), decoration: BoxDecoration(color: Colors.grey.shade300, borderRadius: BorderRadius.circular(2)))),
            Text('编辑: ${_p.name}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            previewWidget,
          ]),
        ),
        // 滚动参数区
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // 基本信息
          Row(children: [
            Expanded(child: _field('名称', 'n', _p.name, (v) => _p = _p.copyWith(name: v))),
          ]),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(flex: 3, child: _field('IP地址', 'ip', _p.ip, (v) => _p = _p.copyWith(ip: v))),
            const SizedBox(width: 8),
            Expanded(flex: 1, child: _field('端口', 'port', _p.port.toString(), (v) => _p = _p.copyWith(port: int.tryParse(v) ?? 9100))),
          ]),
          // 第一行: 基本参数
          const SizedBox(height: 8),
          Row(children: [
            Expanded(child: _field('宽mm', 'w', _p.labelWidth.toStringAsFixed(0), (v) => _p = _p.copyWith(labelWidth: double.tryParse(v) ?? 40))),
            const SizedBox(width: 6),
            Expanded(child: _field('高mm', 'h', _p.labelHeight.toStringAsFixed(0), (v) => _p = _p.copyWith(labelHeight: double.tryParse(v) ?? 30))),
            const SizedBox(width: 6),
            Expanded(child: _field('DPI', 'dpi', _p.dpi.toString(), (v) => _p = _p.copyWith(dpi: int.tryParse(v) ?? 203))),
          ]),
          // 第二行: 打印机选项
          const SizedBox(height: 6),
          Row(children: [
            Expanded(child: _field('条码宽', 'bn', _p.barcodeNarrow.toString(), (v) => _p = _p.copyWith(barcodeNarrow: int.tryParse(v) ?? 2))),
            const SizedBox(width: 6),
            Expanded(child: DropdownButtonFormField<String>(
              value: _p.protocol,
              decoration: const InputDecoration(labelText: '协议', isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 4, vertical: 4), border: OutlineInputBorder()),
              items: const [
                DropdownMenuItem(value: 'tspl', child: Text('TSPL')),
                DropdownMenuItem(value: 'escpos', child: Text('ESC/POS')),
                DropdownMenuItem(value: 'zpl', child: Text('ZPL')),
              ],
              onChanged: (v) => setState(() => _p = _p.copyWith(protocol: v ?? 'tspl')),
            )),
            const SizedBox(width: 6),
            Expanded(child: _p.doubleColumn ? _field('列距mm', 'cg', _p.columnGap.toStringAsFixed(1), (v) => _p = _p.copyWith(columnGap: double.tryParse(v) ?? 2.0)) : const SizedBox()),
          ]),
          const SizedBox(height: 6),
          CheckboxListTile(
            title: const Text('双列', style: TextStyle(fontSize: 13)),
            value: _p.doubleColumn,
            onChanged: (v) => setState(() => _p = _p.copyWith(doubleColumn: v ?? false)),
            dense: true, contentPadding: EdgeInsets.zero,
          ),
          // 条码类型 + 字体方案
          Row(children: [
            const Text('条码:', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
            const SizedBox(width: 4),
            DropdownButton<String>(
              value: _p.barcodeType,
              items: const [
                DropdownMenuItem(value: 'code128', child: Text('Code128', style: TextStyle(fontSize: 12))),
                DropdownMenuItem(value: 'ean13', child: Text('EAN13', style: TextStyle(fontSize: 12))),
              ],
              onChanged: (v) => setState(() => _p = _p.copyWith(barcodeType: v ?? 'code128')),
            ),
            const SizedBox(width: 12),
            const Text('字体:', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
            const SizedBox(width: 8),
            DropdownButton<int>(
              value: _p.fontPreset,
              items: const [
                DropdownMenuItem(value: 0, child: Text('方案A 默认', style: TextStyle(fontSize: 12))),
                DropdownMenuItem(value: 1, child: Text('方案B 中等粗体', style: TextStyle(fontSize: 12))),
                DropdownMenuItem(value: 2, child: Text('方案C 大号TSS', style: TextStyle(fontSize: 12))),
                DropdownMenuItem(value: 3, child: Text('方案D 超大TSS', style: TextStyle(fontSize: 12))),
              ],
              onChanged: (v) => setState(() => _p = _p.copyWith(fontPreset: v ?? 0)),
            ),
          ]),
          const SizedBox(height: 12),
          // 打印元素
          const Text('打印元素', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
          ...List.generate(_elemTypes.length, (i) {
            final type = _elemTypes[i];
            final el = _p.elements.firstWhere((e) => e.type == type, orElse: () => PrintElement(type: type, x: 2, y: 2));
            final enabled = _p.elements.any((e) => e.type == type);
            return CheckboxListTile(
              title: Text(_elemLabels[i], style: const TextStyle(fontSize: 13)),
              value: enabled,
              onChanged: (v) {
                setState(() {
                  if (v == true) {
                    _p = _p.copyWith(elements: [..._p.elements, el]);
                  } else {
                    _p = _p.copyWith(elements: _p.elements.where((e) => e.type != type).toList());
                  }
                });
                              },
              dense: true, contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
            );
          }),
          // 元素位置微调 (简化: 只显示已启用的元素)
          if (_p.elements.isNotEmpty) ...[
            const SizedBox(height: 8),
            const Text('位置调整 (mm)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
            ..._p.elements.map((el) {
              final label = _elemLabels[_elemTypes.indexOf(el.type)];
              return Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  // Row 1: label + X Y + 右偏(W+H for barcode)
                  Row(children: [
                    SizedBox(width: 48, child: Text(label, style: const TextStyle(fontSize: 11))),
                    SizedBox(width: 48, child: _tinyField('X', 'x_${el.type}', el.x.toStringAsFixed(0), (v) {
                      _updateEl(el.type, x: double.tryParse(v) ?? el.x);
                    })),
                    SizedBox(width: 48, child: _tinyField('Y', 'y_${el.type}', el.y.toStringAsFixed(0), (v) {
                      _updateEl(el.type, y: double.tryParse(v) ?? el.y);
                    })),
                    if (_p.doubleColumn)
                      SizedBox(width: 48, child: _tinyField('右偏', 'ro_${el.type}', el.rightOffset.toStringAsFixed(0), (v) {
                        _updateEl(el.type, rightOffset: double.tryParse(v) ?? el.rightOffset);
                      })),
                  ]),
                  // Row 2: W+H (barcode) OR 字+粗 (text)
                  Row(children: [
                    if (el.type == 'barcode') ...[
                      SizedBox(width: 48, child: _tinyField('W', 'bw', (el.width ?? 36).toStringAsFixed(0), (v) {
                        _updateEl(el.type, width: double.tryParse(v));
                      })),
                      SizedBox(width: 48, child: _tinyField('H', 'bh', (el.height ?? 8).toStringAsFixed(0), (v) {
                        _updateEl(el.type, height: double.tryParse(v));
                      })),
                    ] else ...[
                      SizedBox(width: 48, child: _tinyField('字', 'fs_${el.type}', el.fontSize.toString(), (v) {
                        _updateEl(el.type, fontSize: int.tryParse(v));
                      })),
                      CheckboxListTile(
                        title: const Text('粗', style: TextStyle(fontSize: 10)),
                        value: el.bold, onChanged: (v) => _updateEl(el.type, bold: v ?? false),
                        dense: true, contentPadding: EdgeInsets.zero,
                        controlAffinity: ListTileControlAffinity.leading,
                      ),
                    ],
                  ]),
                ]),
              );
            }),
          ],
          const SizedBox(height: 16),
          SizedBox(width: double.infinity, child: ElevatedButton(
            onPressed: () {
              widget.onSave(_p);
              Navigator.pop(context);
            },
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF1976D2), foregroundColor: Colors.white),
            child: const Text('保存模板'),
          )),
          const SizedBox(height: 24),
        ]),
      ),
        ), // Expanded
      ]),
    );
  }

  void _updateEl(String type, {double? x, double? y, double? width, double? height, int? fontSize, bool? bold, double? rightOffset}) {
    setState(() {
      final list = _p.elements.toList();
      final idx = list.indexWhere((e) => e.type == type);
      if (idx >= 0) {
        final old = list[idx];
        list[idx] = PrintElement(
          type: type,
          x: x ?? old.x, y: y ?? old.y,
          width: width ?? old.width, height: height ?? old.height,
          fontSize: fontSize ?? old.fontSize,
          bold: bold ?? old.bold,
          rightOffset: rightOffset ?? old.rightOffset,
        );
        _p = _p.copyWith(elements: list);
      }
    });
      }

  Widget _field(String label, String key, String initial, ValueChanged<String> onChanged) {
    final ctrl = _c(key, initial);
    return TextField(controller: ctrl, onChanged: (v) { onChanged(v); },
      decoration: InputDecoration(labelText: label, isDense: true, contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8), border: const OutlineInputBorder()),
    );
  }

  Widget _tinyField(String label, String key, String value, ValueChanged<String> onChanged) {
    final ctrl = _c(key, value);
    return TextField(
      controller: ctrl,
      onChanged: (v) { onChanged(v); },
      keyboardType: TextInputType.number,
      decoration: InputDecoration(labelText: label, isDense: true, contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4), border: const OutlineInputBorder()),
      style: const TextStyle(fontSize: 12),
    );
  }
}

/// 打印弹窗 — 单打印机：数量 + 价格 + 确认
class PrintDialog extends StatefulWidget {
  final List<PrinterConfig> printers;
  final ProductData product;
  final bool singleMode;
  final void Function(String? error)? onResult;
  const PrintDialog({super.key, required this.printers, required this.product, this.singleMode = false, this.onResult});
  @override
  State<PrintDialog> createState() => _PrintDialogState();
}

class _PrintDialogState extends State<PrintDialog> {
  final _qtyCtrl = TextEditingController(text: '1');
  String? _selectedId;
  bool _showPrice = true;
  final _ps = PrintService();
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    if (widget.printers.isNotEmpty) {
      _selectedId = widget.printers.first.id;
      _loadPriceMemory();
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _qtyCtrl.selection = TextSelection(baseOffset: 0, extentOffset: _qtyCtrl.text.length);
    });
  }
  @override void dispose() { _qtyCtrl.dispose(); super.dispose(); }

  Future<void> _loadPriceMemory() async {
    final prefs = await SharedPreferences.getInstance();
    if (_selectedId != null) {
      final key = 'print_sp_$_selectedId';
      setState(() => _showPrice = prefs.getBool(key) ?? widget.printers.firstWhere((e)=>e.id==_selectedId).showPrice);
    }
  }

  Future<void> _savePriceMemory(bool v) async {
    final prefs = await SharedPreferences.getInstance();
    if (_selectedId != null) await prefs.setBool('print_sp_$_selectedId', v);
  }

  Future<void> _doPrint() async {
    final isLarge = _selectedId == 'p1';
    final qty = isLarge ? 1 : (int.tryParse(_qtyCtrl.text) ?? 1);
    if (qty < 1) return;
    final showPrice = isLarge ? true : _showPrice;
    final p = widget.printers.firstWhere((e) => e.id == _selectedId);
    if (p.ip.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('请先在配置页设置打印机IP'), backgroundColor: Colors.red));
      return;
    }
    setState(() => _busy = true);
    final err = await _ps.print(p, widget.product, showPrice: showPrice, qty: qty);
    setState(() => _busy = false);
    if (mounted) {
      Navigator.pop(context);
      widget.onResult?.call(err);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.printers.firstWhere((e) => e.id == _selectedId);
    final hasPrice = p.elements.any((e) => e.type == 'price');
    final isLarge = _selectedId == 'p1';

    return AlertDialog(
      title: Text(p.name, style: const TextStyle(fontSize: 16)),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        if (isLarge)
          const Text('大价签: 数量=1, 价格强制开启', style: TextStyle(fontSize: 13, color: Colors.grey))
        else ...[
          Row(children: [
            const Text('数量:', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
            const SizedBox(width: 12),
            SizedBox(
              width: 100,
              child: TextField(
                controller: _qtyCtrl, keyboardType: TextInputType.number,
                autofocus: true,
                decoration: const InputDecoration(isDense: true, contentPadding: EdgeInsets.symmetric(horizontal:12,vertical:10), border: OutlineInputBorder()),
                onSubmitted: (_) => _doPrint(),
              ),
            ),
            if (hasPrice) ...[
              const SizedBox(width: 16),
              Row(mainAxisSize: MainAxisSize.min, children: [
                Checkbox(value: _showPrice, onChanged: (v) {
                  setState(() {
                    _showPrice = v ?? true;
                    _qtyCtrl.selection = TextSelection(baseOffset: 0, extentOffset: _qtyCtrl.text.length);
                  });
                  _savePriceMemory(v ?? true);
                }, visualDensity: VisualDensity.compact),
                const Text('价格', style: TextStyle(fontSize: 13)),
              ]),
            ],
          ]),
        ],
        // 多打印机模式才显示选择列表
        if (!widget.singleMode && widget.printers.length > 1) ...[
          const Divider(),
          ...widget.printers.map((pr) => RadioListTile<String>(
            title: Text(pr.name, style: const TextStyle(fontSize: 13)),
            value: pr.id, groupValue: _selectedId,
            onChanged: (v) { setState(() => _selectedId = v); _loadPriceMemory(); },
            dense: true, contentPadding: EdgeInsets.zero,
          )),
        ],
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        ElevatedButton(
          onPressed: _busy ? null : _doPrint,
          style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF1976D2), foregroundColor: Colors.white),
          child: _busy ? const SizedBox(width:16,height:16, child: CircularProgressIndicator(strokeWidth:2, color:Colors.white)) : const Text('打印'),
        ),
      ],
    );
  }
}
