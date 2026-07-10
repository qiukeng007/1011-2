import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:image_picker/image_picker.dart';
import 'package:image/image.dart' as img;
import '../widgets/crop_page.dart';
import '../models/restock_prefill_data.dart';
import '../models/store_config.dart';
import '../services/restock_service.dart';
import '../services/query_service.dart';
import '../services/session_manager.dart';
import '../services/operation_log_service.dart';
import '../models/product_result.dart';
import '../utils/constants.dart';
import '../widgets/barcode_icon.dart';
import '../widgets/scanner_view.dart';

/// 补货页面（日常补货 + 顾客预定 + 订单查询）
class RestockPage extends StatefulWidget {
  final RestockService restockService;
  final RestockPrefillData? prefillData;
  final VoidCallback? onPrefillConsumed;
  final VoidCallback? onSubmitted;
  final PageController? pageController;
  final QueryService? queryService;
  final List<StoreConfig>? configs;

  const RestockPage({
    super.key,
    required this.restockService,
    this.prefillData,
    this.onPrefillConsumed,
    this.onSubmitted,
    this.pageController,
    this.queryService,
    this.configs,
  });

  @override
  State<RestockPage> createState() => _RestockPageState();
}

class _RestockPageState extends State<RestockPage>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  static const _tabColors = [
    Color(0xFF007bff), // 日常补货 蓝
    Color(0xFF28a745), // 顾客预定 绿
    Color(0xFF6f42c1), // 订单查询 紫
  ];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _tabController.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Widget _buildTab(int index, String label) {
    final active = _tabController.index == index;
    return Expanded(
      child: GestureDetector(
        onTap: () => _tabController.animateTo(index),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: active ? Colors.white : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
            boxShadow: active
                ? [BoxShadow(color: Colors.black.withValues(alpha: 0.08), blurRadius: 4, offset: const Offset(0, 2))]
                : null,
          ),
          alignment: Alignment.center,
          child: Text(
            label,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.bold,
              color: active ? _tabColors[index] : const Color(0xFF666666),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final config = widget.restockService;
    if (!config.serverUrl.isNotEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.warning_amber,
                  size: 48, color: AppConstants.warningColor),
              const SizedBox(height: 16),
              const Text(
                '请先在配置页面设置补货服务器地址',
                style: TextStyle(fontSize: 16, color: AppConstants.textSecondary),
              ),
            ],
          ),
        ),
      );
    }

    return Column(
      children: [
        // Tab 切换栏 + 左右滑动切主Tab
        Padding(
          padding: const EdgeInsets.all(12),
          child: GestureDetector(
            onHorizontalDragEnd: (details) {
              if (details.primaryVelocity == null) return;
              if (details.primaryVelocity! > 500) {
                // 右滑 → 回到查询页
                widget.pageController?.animateToPage(0, duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
              } else if (details.primaryVelocity! < -500) {
                // 左滑 → 到配置页
                widget.pageController?.animateToPage(2, duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
              }
            },
            child: Container(
              decoration: BoxDecoration(
                color: const Color(0xFFe9ecef),
                borderRadius: BorderRadius.circular(12),
              ),
              padding: const EdgeInsets.all(4),
              child: Row(
                children: [
                  _buildTab(0, '日常补货'),
                  _buildTab(1, '顾客预定'),
                  _buildTab(2, '订单查询'),
                ],
              ),
            ),
          ),
        ),
        // Tab 内容（边界滑动 → 切主Tab）
        Expanded(
          child: NotificationListener<OverscrollNotification>(
            onNotification: (n) {
              if (n.overscroll < 0 && _tabController.index == 0) {
                widget.pageController?.animateToPage(0, duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
                return true;
              }
              if (n.overscroll > 0 && _tabController.index == 2) {
                widget.pageController?.animateToPage(2, duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
                return true;
              }
              return false;
            },
            child: TabBarView(
                controller: _tabController,
                children: [
              _ReplenishForm(
                service: widget.restockService,
                prefillData: widget.prefillData,
                onPrefillConsumed: widget.onPrefillConsumed,
                onSubmitted: widget.onSubmitted,
                queryService: widget.queryService,
                configs: widget.configs,
              ),
              _BookingForm(
                service: widget.restockService,
                prefillData: widget.prefillData,
                onPrefillConsumed: widget.onPrefillConsumed,
                onSubmitted: widget.onSubmitted,
              ),
              _OrderList(service: widget.restockService),
            ],
            ),
          ),
        ),
      ],
    );
  }
}

/// 日常补货表单
class _ReplenishForm extends StatefulWidget {
  final RestockService service;
  final RestockPrefillData? prefillData;
  final VoidCallback? onPrefillConsumed;
  final VoidCallback? onSubmitted;
  final QueryService? queryService;
  final List<StoreConfig>? configs;
  const _ReplenishForm({
    required this.service,
    this.prefillData,
    this.onPrefillConsumed,
    this.onSubmitted,
    this.queryService,
    this.configs,
  });

  @override
  State<_ReplenishForm> createState() => _ReplenishFormState();
}

class _ReplenishFormState extends State<_ReplenishForm> {
  final _formKey = GlobalKey<FormState>();
  String? _selectedShop;
  final _shopCtrl = TextEditingController();
  final _barcodeCtrl = TextEditingController();
  final _qtyCtrl = TextEditingController(text: '1');
  final _descCtrl = TextEditingController();
  final _qtyFocus = FocusNode();
  final _descFocus = FocusNode();
  File? _imageFile;
  bool _submitting = false;

  // 条码查询结果
  double? _buyPrice;
  double? _sellPrice;
  String? _productName;
  bool _lookingUp = false;
  Timer? _lookupTimer;

  @override
  void initState() {
    super.initState();
    if (widget.prefillData != null) {
      _applyPrefill(widget.prefillData!);
    }
  }

  void _applyPrefill(RestockPrefillData data) {
    setState(() {
      _selectedShop = data.supplier.isNotEmpty ? data.supplier : null;
      _buyPrice = data.buyPrice;
      _sellPrice = data.sellPrice;
      _productName = data.productName.isNotEmpty ? data.productName.replaceAll('&', '') : null;
    });
    _shopCtrl.text = data.supplier;
    _barcodeCtrl.text = data.barcode;
    // 使用预填的商品名称
    if (data.productName.isNotEmpty && _descCtrl.text.isEmpty) {
      _descCtrl.text = data.productName;
    }
  }

  @override
  void dispose() {
    _lookupTimer?.cancel();
    _shopCtrl.dispose();
    _barcodeCtrl.dispose();
    _qtyCtrl.dispose();
    _descCtrl.dispose();
    _qtyFocus.dispose();
    _descFocus.dispose();
    super.dispose();
  }

  /// 条码输入后延迟查询进价/售价
  void _onBarcodeChanged(String value) {
    _lookupTimer?.cancel();
    if (value.length < 6) {
      setState(() { _buyPrice = null; _sellPrice = null; _productName = null; });
      return;
    }
    _lookupTimer = Timer(const Duration(milliseconds: 500), () => _lookupBarcode(value));
  }

  Future<void> _lookupBarcode(String barcode) async {
    if (widget.queryService == null || widget.configs == null) return;
    // 用任意有效门店配置查询（供货商名 ≠ 门店名）
    final storeConfig = widget.configs!.isNotEmpty ? widget.configs!.first : null;
    if (storeConfig == null) return;

    setState(() => _lookingUp = true);
    try {
      final result = await widget.queryService!.queryByBarcode(storeConfig, barcode);
      if (!mounted) return;
      if (result.ok && result.data != null) {
        final data = result.data!;
        setState(() {
          _buyPrice = data.buyPrice;
          _sellPrice = data.sellPrice;
          _productName = data.name.isNotEmpty ? data.name.replaceAll('&', '') : null;
          _lookingUp = false;
        });
        // 自动填充备注为商品名称
        if (_productName != null && _descCtrl.text.isEmpty) {
          _descCtrl.text = _productName!;
        }
      } else {
        setState(() {
          _buyPrice = null; _sellPrice = null; _productName = null; _lookingUp = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _lookingUp = false);
    }
  }

  @override
  void didUpdateWidget(covariant _ReplenishForm oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.prefillData != null &&
        widget.prefillData != oldWidget.prefillData) {
      _applyPrefill(widget.prefillData!);
      widget.onPrefillConsumed?.call();
    }
  }

  Future<void> _pickImage() async {
    FocusManager.instance.primaryFocus?.unfocus();
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.camera_alt),
              title: const Text('拍照'),
              onTap: () => Navigator.pop(ctx, ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library),
              title: const Text('从相册选择'),
              onTap: () => Navigator.pop(ctx, ImageSource.gallery),
            ),
          ],
        ),
      ),
    );

    if (source == null) return;

    try {
      final picker = ImagePicker();
      final picked = await picker.pickImage(source: source, maxWidth: 1200, maxHeight: 1200);
      if (picked == null || !mounted) return;

      // 进入裁剪页面
      final croppedPath = await Navigator.of(context).push<String>(
        MaterialPageRoute(builder: (_) => CropPage(imagePath: picked.path)),
      );
      if (!mounted) return;
      if (croppedPath != null) setState(() => _imageFile = File(croppedPath));
      // 裁剪页面返回后延后收键盘，等路由动画完成
      WidgetsBinding.instance.addPostFrameCallback((_) {
        FocusManager.instance.primaryFocus?.unfocus();
      });
    } catch (e) {
      if (mounted) _showMsg('获取图片失败：$e');
    }
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    if (_selectedShop == null || _selectedShop!.isEmpty) {
      _showMsg('请填写供货商');
      return;
    }
    if (_imageFile == null) {
      _showMsg('请拍照上传照片');
      return;
    }
    // 检查操作员姓名
    if (widget.service.operatorName.isEmpty) {
      await _askOperatorName();
    }

    setState(() => _submitting = true);
    try {
      final imageBytes = await _imageFile!.readAsBytes();
      final ok = await widget.service.submitReplenish(
        shopName: _selectedShop!,
        barcode: _barcodeCtrl.text,
        quantity: int.tryParse(_qtyCtrl.text) ?? 1,
        desc: _descCtrl.text,
        imageBytes: imageBytes,
        imageName: 'IMG_${DateTime.now().millisecondsSinceEpoch}.jpg',
      );

      if (mounted) {
        if (ok) {
          _showMsg('提交成功！');
          OperationLogService.add(
            store: _selectedShop!,
            action: '补货',
            barcode: _barcodeCtrl.text,
            detail: '数量: ${int.tryParse(_qtyCtrl.text) ?? 1}',
          );
          _resetForm();
          widget.onSubmitted?.call();
        } else {
          _showMsg('提交失败，请检查网络和服务器地址');
        }
      }
    } catch (e) {
      if (mounted) _showMsg('提交出错：$e');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _askOperatorName() async {
    final ctrl = TextEditingController();
    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('操作员姓名'),
        content: TextField(controller: ctrl, decoration: const InputDecoration(hintText: '请输入操作员姓名', border: OutlineInputBorder())),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('确认')),
        ],
      ),
    );
    final name = ctrl.text.trim();
    if (name.isNotEmpty) {
      await widget.service.updateOperatorName(name);
    }
  }

  void _resetForm() {
    _shopCtrl.clear();
    _barcodeCtrl.clear();
    _qtyCtrl.text = '1';
    _descCtrl.clear();
    setState(() {
      _imageFile = null;
      _selectedShop = null;
    });
  }

  void _showMsg(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 供货商
            const Text('供货商 *',
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: AppConstants.textSecondary)),
            const SizedBox(height: 6),
            _buildShopDropdown(),
            const SizedBox(height: 12),
            // 条码
            const Text('商品条码',
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: AppConstants.textSecondary)),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _barcodeCtrl,
                    decoration: _inputDecoration(hint: '手动输入或扫码'),
                    keyboardType: TextInputType.number,
                    onChanged: _onBarcodeChanged,
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 70,
                  height: 42,
                  child: ElevatedButton(
                    onPressed: () {
                      // 扫码功能 - 使用 mobile_scanner
                      _scanBarcode();
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.grey,
                      foregroundColor: Colors.white,
                      padding: EdgeInsets.zero,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    child: BarcodeIcon(size: 18, color: Colors.white),
                  ),
                ),
              ],
            ),
            // 进价/售价显示
            if (_lookingUp)
              const Padding(
                padding: EdgeInsets.only(top: 6),
                child: Row(children: [
                  SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2)),
                  SizedBox(width: 8),
                  Text('查询中…', style: TextStyle(fontSize: 12, color: AppConstants.textSecondary)),
                ]),
              )
            else if (_buyPrice != null || _sellPrice != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Row(children: [
                  if (_sellPrice != null) ...[
                    const Icon(Icons.monetization_on, size: 16, color: Colors.red),
                    const SizedBox(width: 4),
                    Text('售价 R${_sellPrice!.toStringAsFixed(2)}',
                        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.red)),
                  ],
                  if (_sellPrice != null && _buyPrice != null) const SizedBox(width: 16),
                  if (_buyPrice != null) ...[
                    const Icon(Icons.shopping_cart, size: 14, color: Color(0xFF8B4513)),
                    const SizedBox(width: 4),
                    Text('进价 R${_buyPrice!.toStringAsFixed(2)}',
                        style: const TextStyle(fontSize: 13, color: Color(0xFF8B4513))),
                  ],
                ]),
              ),
            const SizedBox(height: 12),
            // 数量和备注
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('数量 *',
                          style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                              color: AppConstants.textSecondary)),
                      const SizedBox(height: 6),
                      TextFormField(
                        controller: _qtyCtrl,
                        focusNode: _qtyFocus,
                        decoration: _inputDecoration(),
                        keyboardType: TextInputType.number,
                        onTap: () {
                          // 先收起当前键盘，再弹出数字键盘
                          FocusScope.of(context).unfocus();
                          Future.delayed(const Duration(milliseconds: 50), () {
                            if (mounted) _qtyFocus.requestFocus();
                          });
                          _qtyCtrl.selection = TextSelection(
                            baseOffset: 0, extentOffset: _qtyCtrl.text.length,
                          );
                        },
                        validator: (v) {
                          if (v == null || v.isEmpty) return '必填';
                          if (int.tryParse(v) == null || int.parse(v) <= 0) {
                            return '请输入有效数量';
                          }
                          return null;
                        },
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 2,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('备注',
                          style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                              color: AppConstants.textSecondary)),
                      const SizedBox(height: 6),
                      TextFormField(
                        controller: _descCtrl,
                        focusNode: _descFocus,
                        decoration: _inputDecoration(hint: '颜色、货号等'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            // 照片上传
            const Text('照片上传 *',
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: AppConstants.textSecondary)),
            const SizedBox(height: 6),
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                FocusManager.instance.primaryFocus?.unfocus();
                _pickImage();
              },
              child: Container(
                height: 180,
                decoration: BoxDecoration(
                  border: Border.all(
                    color: _imageFile != null
                        ? AppConstants.primaryColor
                        : Colors.grey.shade300,
                    width: 2,
                    style: _imageFile != null ? BorderStyle.solid : BorderStyle.solid,
                  ),
                  borderRadius: BorderRadius.circular(10),
                  color: AppConstants.bgColor,
                ),
                child: _imageFile != null
                    ? ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Image.file(
                          _imageFile!,
                          fit: BoxFit.contain,
                          width: double.infinity,
                        ),
                      )
                    : const Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.camera_alt,
                                size: 40, color: AppConstants.textSecondary),
                            SizedBox(height: 8),
                            Text(
                              '点击拍照 / 选图 (必传)',
                              style: TextStyle(
                                  fontSize: 13, color: AppConstants.textSecondary),
                            ),
                          ],
                        ),
                      ),
            ),
            ),
            const SizedBox(height: 16),
            // 提交按钮
            SizedBox(
              width: double.infinity,
              height: 46,
              child: ElevatedButton(
                onPressed: _submitting ? null : _submit,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppConstants.primaryColor,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(23),
                  ),
                  elevation: 0,
                ),
                child: _submitting
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Text('提交补货',
                        style: TextStyle(
                            fontSize: 16, fontWeight: FontWeight.bold)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _scanBarcode() {
    // 使用 Navigator 打开扫码页面，返回条码结果
    Navigator.of(context)
        .push(MaterialPageRoute(
      builder: (_) => const _ScanPage(),
    ))
        .then((result) {
      if (result != null && result is String) {
        _barcodeCtrl.text = result;
      }
    });
  }

  Widget _buildShopDropdown() {
    final configSuppliers = widget.service.suppliers;
    // 合并配置列表 + 当前选中值（支持从查询结果预填的供货商）
    final options = <String>[...configSuppliers];
    if (_selectedShop != null &&
        _selectedShop!.isNotEmpty &&
        !options.contains(_selectedShop)) {
      options.insert(0, _selectedShop!);
    }

    return DropdownButtonFormField<String>(
      value: _selectedShop != null && options.contains(_selectedShop)
          ? _selectedShop
          : null,
      decoration: _inputDecoration(hint: '-- 请选择供货商 --'),
      isExpanded: true,
      items: options.map((s) {
        return DropdownMenuItem(value: s, child: Text(s));
      }).toList(),
      onChanged: (v) => setState(() {
        _selectedShop = v;
        _shopCtrl.text = v ?? '';
      }),
      validator: (v) {
        if (v == null || v.trim().isEmpty) return '请选择供货商';
        return null;
      },
    );
  }

  InputDecoration _inputDecoration({String hint = ''}) {
    return InputDecoration(
      hintText: hint,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: Colors.grey),
      ),
    );
  }
}

/// 顾客预定表单
class _BookingForm extends StatefulWidget {
  final RestockService service;
  final RestockPrefillData? prefillData;
  final VoidCallback? onPrefillConsumed;
  final VoidCallback? onSubmitted;
  const _BookingForm({
    required this.service,
    this.prefillData,
    this.onPrefillConsumed,
    this.onSubmitted,
  });

  @override
  State<_BookingForm> createState() => _BookingFormState();
}

class _BookingFormState extends State<_BookingForm> {
  final _formKey = GlobalKey<FormState>();
  String? _selectedShop;
  final _shopCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _barcodeCtrl = TextEditingController();
  final _qtyCtrl = TextEditingController(text: '1');
  final _descCtrl = TextEditingController();
  File? _imageFile;
  bool _submitting = false;

  @override
  void dispose() {
    _shopCtrl.dispose();
    _phoneCtrl.dispose();
    _barcodeCtrl.dispose();
    _qtyCtrl.dispose();
    _descCtrl.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _BookingForm oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.prefillData != null &&
        widget.prefillData != oldWidget.prefillData) {
      _applyPrefill(widget.prefillData!);
      widget.onPrefillConsumed?.call();
    }
  }

  void _applyPrefill(RestockPrefillData data) {
    setState(() {
      _selectedShop = data.supplier.isNotEmpty ? data.supplier : null;
    });
    _shopCtrl.text = data.supplier;
    _barcodeCtrl.text = data.barcode;
  }

  Future<void> _pickImage() async {
    FocusManager.instance.primaryFocus?.unfocus();
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.camera_alt),
              title: const Text('拍照'),
              onTap: () => Navigator.pop(ctx, ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library),
              title: const Text('从相册选择'),
              onTap: () => Navigator.pop(ctx, ImageSource.gallery),
            ),
          ],
        ),
      ),
    );

    if (source == null) return;

    try {
      final picker = ImagePicker();
      final picked = await picker.pickImage(source: source, maxWidth: 1200, maxHeight: 1200);
      if (picked == null || !mounted) return;

      // 进入裁剪页面
      final croppedPath = await Navigator.of(context).push<String>(
        MaterialPageRoute(builder: (_) => CropPage(imagePath: picked.path)),
      );
      if (!mounted) return;
      if (croppedPath != null) setState(() => _imageFile = File(croppedPath));
      // 裁剪页面返回后延后收键盘，等路由动画完成
      WidgetsBinding.instance.addPostFrameCallback((_) {
        FocusManager.instance.primaryFocus?.unfocus();
      });
    } catch (e) {
      if (mounted) _showMsg('获取图片失败：$e');
    }
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    if (_phoneCtrl.text.trim().isEmpty) {
      _showMsg('请输入顾客电话');
      return;
    }
    if (_descCtrl.text.trim().isEmpty) {
      _showMsg('请输入规格说明');
      return;
    }
    if (_imageFile == null) {
      _showMsg('请拍照上传照片');
      return;
    }
    if (widget.service.operatorName.isEmpty) {
      await _askOperatorName();
    }

    setState(() => _submitting = true);
    try {
      final imageBytes = await _imageFile!.readAsBytes();
      final ok = await widget.service.submitBooking(
        shopName: _selectedShop,
        phone: _phoneCtrl.text.trim(),
        barcode: _barcodeCtrl.text,
        quantity: int.tryParse(_qtyCtrl.text) ?? 1,
        desc: _descCtrl.text.trim(),
        imageBytes: imageBytes,
        imageName: 'IMG_${DateTime.now().millisecondsSinceEpoch}.jpg',
      );

      if (mounted) {
        if (ok) {
          _showMsg('预定提交成功！');
          OperationLogService.add(
            store: _selectedShop!,
            action: '预定',
            barcode: _barcodeCtrl.text,
            detail: '数量: ${int.tryParse(_qtyCtrl.text) ?? 1}',
          );
          _resetForm();
          widget.onSubmitted?.call();
        } else {
          _showMsg('提交失败，请检查网络和服务器地址');
        }
      }
    } catch (e) {
      if (mounted) _showMsg('提交出错：$e');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _askOperatorName() async {
    final ctrl = TextEditingController();
    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('操作员姓名'),
        content: TextField(controller: ctrl, decoration: const InputDecoration(hintText: '请输入操作员姓名', border: OutlineInputBorder())),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('确认')),
        ],
      ),
    );
    final name = ctrl.text.trim();
    if (name.isNotEmpty) {
      await widget.service.updateOperatorName(name);
    }
  }

  void _resetForm() {
    _shopCtrl.clear();
    _phoneCtrl.clear();
    _barcodeCtrl.clear();
    _qtyCtrl.text = '1';
    _descCtrl.clear();
    setState(() {
      _imageFile = null;
      _selectedShop = null;
    });
  }

  void _showMsg(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 供货商
            const Text('供货商',
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: AppConstants.textSecondary)),
            const SizedBox(height: 6),
            _buildShopDropdown(),
            const SizedBox(height: 12),
            // 顾客电话
            const Text('顾客电话 *',
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: AppConstants.textSecondary)),
            const SizedBox(height: 6),
            TextFormField(
              controller: _phoneCtrl,
              decoration: _inputDecoration(hint: '手机号'),
              keyboardType: TextInputType.phone,
              validator: (v) {
                if (v == null || v.trim().isEmpty) return '必填';
                return null;
              },
            ),
            const SizedBox(height: 12),
            // 条码
            const Text('条码',
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: AppConstants.textSecondary)),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _barcodeCtrl,
                    decoration: _inputDecoration(hint: '选填'),
                    keyboardType: TextInputType.number,
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 70,
                  height: 42,
                  child: ElevatedButton(
                    onPressed: () => _scanBarcode(),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.grey,
                      foregroundColor: Colors.white,
                      padding: EdgeInsets.zero,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    child: BarcodeIcon(size: 18, color: Colors.white),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            // 数量和规格
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('数量 *',
                          style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                              color: AppConstants.textSecondary)),
                      const SizedBox(height: 6),
                      TextFormField(
                        controller: _qtyCtrl,
                        decoration: _inputDecoration(),
                        keyboardType: TextInputType.number,
                        validator: (v) {
                          if (v == null || v.isEmpty) return '必填';
                          if (int.tryParse(v) == null || int.parse(v) <= 0) {
                            return '请输入有效数量';
                          }
                          return null;
                        },
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 2,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('规格说明 *',
                          style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                              color: AppConstants.textSecondary)),
                      const SizedBox(height: 6),
                      TextFormField(
                        controller: _descCtrl,
                        decoration: _inputDecoration(hint: '颜色规格 (必填)'),
                        validator: (v) {
                          if (v == null || v.trim().isEmpty) return '必填';
                          return null;
                        },
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            // 照片上传
            const Text('照片上传 *',
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: AppConstants.textSecondary)),
            const SizedBox(height: 6),
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                FocusManager.instance.primaryFocus?.unfocus();
                _pickImage();
              },
              child: Container(
                height: 180,
                decoration: BoxDecoration(
                  border: Border.all(
                    color: _imageFile != null
                        ? AppConstants.primaryColor
                        : Colors.grey.shade300,
                    width: 2,
                  ),
                  borderRadius: BorderRadius.circular(10),
                  color: AppConstants.bgColor,
                ),
                child: _imageFile != null
                    ? ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Image.file(
                          _imageFile!,
                          fit: BoxFit.contain,
                          width: double.infinity,
                        ),
                      )
                    : const Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.camera_alt,
                                size: 40, color: AppConstants.textSecondary),
                            SizedBox(height: 8),
                            Text(
                              '点击拍照 / 选图 (必传)',
                              style: TextStyle(
                                  fontSize: 13, color: AppConstants.textSecondary),
                            ),
                          ],
                        ),
                      ),
            ),
            ),
            const SizedBox(height: 16),
            // 提交按钮
            SizedBox(
              width: double.infinity,
              height: 46,
              child: ElevatedButton(
                onPressed: _submitting ? null : _submit,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF43A047),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(23),
                  ),
                  elevation: 0,
                ),
                child: _submitting
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Text('提交预定',
                        style: TextStyle(
                            fontSize: 16, fontWeight: FontWeight.bold)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _scanBarcode() {
    Navigator.of(context)
        .push(MaterialPageRoute(
      builder: (_) => const _ScanPage(),
    ))
        .then((result) {
      if (result != null && result is String) {
        _barcodeCtrl.text = result;
      }
    });
  }

  Widget _buildShopDropdown() {
    final configSuppliers = widget.service.suppliers;
    final options = <String>[...configSuppliers];
    if (_selectedShop != null &&
        _selectedShop!.isNotEmpty &&
        !options.contains(_selectedShop)) {
      options.insert(0, _selectedShop!);
    }

    return DropdownButtonFormField<String>(
      value: _selectedShop != null && options.contains(_selectedShop)
          ? _selectedShop
          : null,
      decoration: _inputDecoration(hint: '-- (选填) --'),
      isExpanded: true,
      items: options.map((s) {
        return DropdownMenuItem(value: s, child: Text(s));
      }).toList(),
      onChanged: (v) => setState(() {
        _selectedShop = v;
        _shopCtrl.text = v ?? '';
      }),
    );
  }

  InputDecoration _inputDecoration({String hint = ''}) {
    return InputDecoration(
      hintText: hint,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: Colors.grey),
      ),
    );
  }
}

/// 订单查询列表
class _OrderList extends StatefulWidget {
  final RestockService service;
  const _OrderList({required this.service});

  @override
  State<_OrderList> createState() => _OrderListState();
}

class _OrderListState extends State<_OrderList> {
  List<OrderRecord> _orders = [];
  bool _loading = false;
  String _searchKey = '';
  String _filterShop = '';
  String _sortMode = 'date';

  @override
  void initState() {
    super.initState();
    _loadOrders();
  }

  Future<void> _loadOrders() async {
    setState(() => _loading = true);
    try {
      final orders = await widget.service.queryOrders(searchKey: _searchKey);
      if (mounted) {
        setState(() {
          _orders = orders;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  List<OrderRecord> get _sortedOrders {
    var filtered = _orders.where((o) {
      // 供货商过滤
      if (_filterShop.isNotEmpty && o.shopname != _filterShop) return false;
      // 搜索过滤（电话、条码、说明）
      if (_searchKey.isNotEmpty) {
        final key = _searchKey.toLowerCase();
        final phone = (o.customerPhone ?? '').toLowerCase();
        final barcode = (o.productBarcode ?? '').toLowerCase();
        final desc = (o.productDesc ?? '').toLowerCase();
        if (!phone.contains(key) && !barcode.contains(key) && !desc.contains(key)) {
          return false;
        }
      }
      return true;
    }).toList();

    if (_sortMode == 'qty') {
      filtered.sort((a, b) => (int.tryParse(b.orderQty ?? '0') ?? 0) -
          (int.tryParse(a.orderQty ?? '0') ?? 0));
    } else {
      filtered.sort((a, b) {
        final da = DateTime.tryParse(a.orderTime ?? '');
        final db = DateTime.tryParse(b.orderTime ?? '');
        if (da == null && db == null) return 0;
        if (da == null) return 1;
        if (db == null) return -1;
        return db.compareTo(da);
      });
    }
    return filtered;
  }

  Future<void> _finishOrder(String id) async {
    if (id.isEmpty || id == 'undefined') {
      _showMsg('订单ID无效');
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认完结'),
        content: const Text('确定要完结此订单吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确认完结'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      final ok = await widget.service.finishOrder(id);
      if (mounted) {
        if (ok) {
          _showMsg('订单已成功完结！');
          _loadOrders();
        } else {
          _showMsg('完结失败');
        }
      }
    }
  }

  void _showMsg(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // 搜索和排序
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Column(
            children: [
              // 供货商筛选
              DropdownButtonFormField<String>(
                value: _filterShop.isEmpty ? null : _filterShop,
                decoration: _inputDecoration(hint: '-- 全部供货商 --'),
                isExpanded: true,
                items: [
                  const DropdownMenuItem<String>(
                    value: '',
                    child: Text('-- 全部供货商 --', style: TextStyle(fontSize: 14)),
                  ),
                  ...widget.service.suppliers.map((s) =>
                      DropdownMenuItem<String>(value: s, child: Text(s, style: const TextStyle(fontSize: 14)))),
                ],
                onChanged: (v) => setState(() => _filterShop = v ?? ''),
              ),
              const SizedBox(height: 8),
              // 搜索框
              TextField(
                decoration: _inputDecoration(hint: '搜电话、条码、说明'),
                style: const TextStyle(fontSize: 14),
                onChanged: (v) => setState(() => _searchKey = v),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: _buildSortButton('date', '按时间 ↓'),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _buildSortButton('qty', '按数量 ↓'),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        // 订单列表
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _orders.isEmpty
                  ? const Center(
                      child: Text('无记录',
                          style: TextStyle(
                              color: AppConstants.textSecondary, fontSize: 14)),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      itemCount: _sortedOrders.length,
                      itemBuilder: (context, index) {
                        final order = _sortedOrders[index];
                        return _buildOrderItem(order);
                      },
                    ),
        ),
      ],
    );
  }

  Widget _buildSortButton(String mode, String label) {
    final active = _sortMode == mode;
    return OutlinedButton(
      onPressed: () {
        setState(() => _sortMode = mode);
      },
      style: OutlinedButton.styleFrom(
        foregroundColor: active ? const Color(0xFF6f42c1) : AppConstants.textSecondary,
        backgroundColor: active ? const Color(0xFFf0ebf8) : null,
        side: BorderSide(
          color: active ? const Color(0xFF6f42c1) : Colors.grey.shade300,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        padding: const EdgeInsets.symmetric(vertical: 6),
      ),
      child: Text(label, style: const TextStyle(fontSize: 12)),
    );
  }

  Widget _buildOrderItem(OrderRecord order) {
    final imgSrc = order.displayImageUrl.isNotEmpty
        ? '${widget.service.serverUrl}${order.displayImageUrl}'
        : '';

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Color(0xFFf2f2f2))),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 图片（点击放大）
          GestureDetector(
            onTap: () {
              if (imgSrc.isNotEmpty) {
                Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => _ZoomPage(imageUrl: imgSrc),
                ));
              }
            },
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: imgSrc.isNotEmpty
                  ? Image.network(
                      imgSrc,
                      width: 70,
                      height: 70,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => Container(
                        width: 70,
                        height: 70,
                        color: Colors.grey.shade200,
                        child: const Icon(Icons.image, color: Colors.grey),
                      ),
                    )
                  : Container(
                      width: 70,
                      height: 70,
                      color: Colors.grey.shade200,
                      child: const Icon(Icons.image, color: Colors.grey),
                    ),
            ),
          ),
          const SizedBox(width: 10),
          // 信息
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 第一行：电话 + 完结按钮
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '📞 ${order.customerPhone ?? '日常补货'}',
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF333333),
                        ),
                      ),
                    ),
                    SizedBox(
                      height: 28,
                      child: ElevatedButton(
                        onPressed: () => _finishOrder(order.id ?? ''),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppConstants.successColor,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(6),
                          ),
                        ),
                        child: const Text('完结',
                            style: TextStyle(
                                fontSize: 12, fontWeight: FontWeight.bold)),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                // 第二行：条码 + 供货商
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '条码: ${order.productBarcode ?? '未录入'}',
                        style: const TextStyle(
                            fontSize: 12, color: Color(0xFF777777)),
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: const Color(0xFFf3e8ff),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        order.shopname ?? '无供货商',
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF6f42c1),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                // 第三行：说明
                Text(
                  '说明: ${order.productDesc ?? '无说明'}',
                  style: const TextStyle(
                      fontSize: 12, color: Color(0xFF444444)),
                ),
                const SizedBox(height: 4),
                // 第四行：数量 + 时间
                Row(
                  children: [
                    Text(
                      'x ${order.orderQty ?? 1}',
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFFd9534f),
                      ),
                    ),
                    const Spacer(),
                    Text(
                      order.orderTime ?? '',
                      style: const TextStyle(
                          fontSize: 11, color: AppConstants.textSecondary),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  InputDecoration _inputDecoration({String hint = ''}) {
    return InputDecoration(
      hintText: hint,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: Colors.grey),
      ),
    );
  }
}

/// 裁剪页面（Flutter 原生实现，无第三方原生依赖）
class _CropPage extends StatefulWidget {
  final String imagePath;
  const _CropPage({required this.imagePath});

  @override
  State<_CropPage> createState() => _CropPageState();
}

class _CropPageState extends State<_CropPage> {
  bool _busy = false;
  double _cropSize = 0;
  Offset _cropCenter = Offset.zero;

  @override
  void initState() {
    super.initState();
    final sw = MediaQuery.of(context).size.width;
    _cropSize = sw - 80;
    _cropCenter = Offset(sw / 2, MediaQuery.of(context).size.height / 2);
  }

  Future<void> _done() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final srcBytes = await File(widget.imagePath).readAsBytes();
      final src = img.decodeImage(srcBytes);
      if (src == null) { Navigator.pop(context, widget.imagePath); return; }

      final sw = MediaQuery.of(context).size.width;
      final sh = MediaQuery.of(context).size.height;
      // 图片按 contain 方式显示，计算显示区域
      final imgAspect = src.width / src.height;
      final viewAspect = sw / sh;
      double dispW, dispH, offsetX, offsetY;
      if (imgAspect > viewAspect) {
        dispW = sw; dispH = sw / imgAspect;
        offsetX = 0; offsetY = (sh - dispH) / 2;
      } else {
        dispH = sh; dispW = sh * imgAspect;
        offsetX = (sw - dispW) / 2; offsetY = 0;
      }

      final scaleX = src.width / dispW;
      final scaleY = src.height / dispH;
      final sx = ((_cropCenter.dx - offsetX - _cropSize / 2) * scaleX).round().clamp(0, src.width);
      final sy = ((_cropCenter.dy - offsetY - _cropSize / 2) * scaleY).round().clamp(0, src.height);
      final cropW = (_cropSize * scaleX).round().clamp(1, src.width - sx);
      final cropH = (_cropSize * scaleY).round().clamp(1, src.height - sy);

      final cropped = img.copyCrop(src, sx, sy, cropW, cropH);
      final resized = img.copyResize(cropped, width: 800, height: 800);
      final jpg = img.encodeJpg(resized, quality: 85);
      final out = File('${Directory.systemTemp.path}/crop_${DateTime.now().millisecondsSinceEpoch}.jpg');
      await out.writeAsBytes(jpg);
      if (mounted) Navigator.pop(context, out.path);
    } catch (_) {
      if (mounted) Navigator.pop(context, widget.imagePath);
    }
  }

  @override
  Widget build(BuildContext context) {
    final sw = MediaQuery.of(context).size.width;
    final sh = MediaQuery.of(context).size.height;
    if (_cropCenter == Offset.zero) _cropCenter = Offset(sw / 2, sh / 2);

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black, foregroundColor: Colors.white,
        title: const Text('裁剪图片 (拖动框+双指缩放)'),
        actions: [
          TextButton(
            onPressed: _busy ? null : _done,
            child: Text(_busy ? '处理中…' : '确认 ✓',
                style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
      body: GestureDetector(
        onPanUpdate: (d) => setState(() => _cropCenter += d.delta),
        child: Stack(
          children: [
            // 图片 - 全屏展示
            Image.file(File(widget.imagePath), fit: BoxFit.contain, width: sw, height: sh),
            // 遮罩 + 裁剪框
            CustomPaint(
              size: Size(sw, sh),
              painter: _CropOverlayPainter2(_cropCenter, _cropSize),
            ),
            if (_busy)
              const Center(child: CircularProgressIndicator(color: Colors.white)),
          ],
        ),
      ),
    );
  }
}

class _CropOverlayPainter2 extends CustomPainter {
  final Offset center;
  final double size;
  _CropOverlayPainter2(this.center, this.size);

  @override
  void paint(Canvas canvas, Size canvasSize) {
    final rect = Rect.fromLTWH(0, 0, canvasSize.width, canvasSize.height);
    final cropRect = Rect.fromCenter(center: center, width: size, height: size);
    canvas.drawPath(
      Path.combine(PathOperation.difference, Path()..addRect(rect), Path()..addRect(cropRect)),
      Paint()..color = Colors.black54,
    );
    canvas.drawRect(cropRect, Paint()..color = Colors.white..style = PaintingStyle.stroke..strokeWidth = 2.0);
  }

  @override
  bool shouldRepaint(covariant _CropOverlayPainter2 old) =>
      old.center != center || old.size != size;
}

class _CropOverlayPainter extends CustomPainter {
  final double cropSize;
  _CropOverlayPainter(this.cropSize);

  @override
  void paint(Canvas canvas, Size size) {
    final fullRect = Rect.fromLTWH(0, 0, size.width, size.height);
    final cropRect = Rect.fromCenter(
      center: Offset(size.width / 2, size.height / 2),
      width: cropSize,
      height: cropSize,
    );

    canvas.drawPath(
      Path.combine(
        PathOperation.difference,
        Path()..addRect(fullRect),
        Path()..addRect(cropRect),
      ),
      Paint()..color = Colors.black54,
    );
    canvas.drawRect(
      cropRect,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0,
    );
  }

  @override
  bool shouldRepaint(_CropOverlayPainter old) => old.cropSize != cropSize;
}

/// 图片放大查看页面
class _ZoomPage extends StatelessWidget {
  final String imageUrl;
  const _ZoomPage({required this.imageUrl});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      body: GestureDetector(
        onTap: () => Navigator.pop(context),
        child: Center(
          child: InteractiveViewer(
            minScale: 1.0,
            maxScale: 4.0,
            child: Image.network(
              imageUrl,
              fit: BoxFit.contain,
              errorBuilder: (_, __, ___) => const Icon(Icons.broken_image,
                  size: 64, color: Colors.white54),
            ),
          ),
        ),
      ),
    );
  }
}

/// 扫码页面
class _ScanPage extends StatelessWidget {
  const _ScanPage();

  @override
  Widget build(BuildContext context) {
    return ScannerView(
      onDetect: (barcode) => Navigator.pop(context, barcode),
      onClose: () => Navigator.pop(context),
    );
  }
}
