import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

/// 裁剪 — 拖动选框，等比映射
class CropPage extends StatefulWidget {
  final String imagePath;
  const CropPage({super.key, required this.imagePath});
  @override
  State<CropPage> createState() => _CropPageState();
}

class _CropPageState extends State<CropPage> {
  bool _busy = false;
  double _cropW = 0, _cropX = -1, _cropY = -1;
  double _scale = 1.0;
  double _baseScale = 1.0;
  img.Image? _src;
  Rect _imgRect = Rect.zero;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final bytes = await File(widget.imagePath).readAsBytes();
    _src = img.decodeImage(bytes);
    if (mounted) setState(() => _loaded = true);
  }

  double get _topPad => MediaQuery.of(context).padding.top + kToolbarHeight;

  Rect _computeImgRect(double bw, double bh) {
    if (_src == null) return Rect.zero;
    final a = _src!.width / _src!.height;
    final va = bw / bh.clamp(1, double.infinity);
    double iw, ih;
    if (a > va) { iw = bw; ih = iw / a; }
    else { ih = bh; iw = ih * a; }
    return Rect.fromLTWH((bw - iw) / 2, (bh - ih) / 2, iw, ih);
  }

  Future<void> _done() async {
    if (_busy || _src == null) return;
    setState(() => _busy = true);
    try {
      final bw = MediaQuery.of(context).size.width;
      final bh = MediaQuery.of(context).size.height - _topPad;
      final ir = _computeImgRect(bw, bh);
      // 缩放后图片显示区域
      final scaledW = ir.width * _scale;
      final scaledH = ir.height * _scale;
      final scaledLeft = ir.left - (scaledW - ir.width) / 2;
      final scaledTop = ir.top - (scaledH - ir.height) / 2;
      final sx = ((_cropX - scaledLeft) / scaledW * _src!.width).round().clamp(0, _src!.width - 1);
      final sy = ((_cropY - scaledTop) / scaledH * _src!.height).round().clamp(0, _src!.height - 1);
      final sw = (_cropW / scaledW * _src!.width).round().clamp(1, _src!.width - sx);
      final sh = (_cropW / scaledH * _src!.height).round().clamp(1, _src!.height - sy);

      final cropped = img.copyCrop(_src!, sx, sy, sw, sh);
      final resized = img.copyResize(cropped, width: 800, height: 800);
      final out = File('${Directory.systemTemp.path}/crop_${DateTime.now().millisecondsSinceEpoch}.jpg');
      await out.writeAsBytes(img.encodeJpg(resized, quality: 85));
      if (mounted) Navigator.pop(context, out.path);
    } catch (_) {
      if (mounted) Navigator.pop(context, widget.imagePath);
    }
  }

  @override
  Widget build(BuildContext context) {
    final sw = MediaQuery.of(context).size.width;
    final bh = MediaQuery.of(context).size.height - _topPad;
    if (_cropW == 0) _cropW = sw - 80;
    _imgRect = _computeImgRect(sw, bh);
    if (_cropX < 0) { _cropX = (sw - _cropW) / 2; _cropY = (bh - _cropW) / 2; }

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black, foregroundColor: Colors.white,
        title: const Text('裁剪 (拖动选框)'),
        actions: [
          TextButton(
            onPressed: (_busy || !_loaded) ? null : _done,
            child: Text(_busy ? '…' : '确认 ✓',
                style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator(color: Colors.white))
          : LayoutBuilder(builder: (_, c) {
              return GestureDetector(
                onScaleStart: (_) => _baseScale = _scale,
                onScaleUpdate: (d) {
                  setState(() {
                    if (d.pointerCount >= 2) {
                      _scale = (_baseScale * d.scale).clamp(0.5, 4.0);
                    } else {
                      _cropX = (_cropX + d.focalPointDelta.dx).clamp(0.0, c.maxWidth - _cropW);
                      _cropY = (_cropY + d.focalPointDelta.dy).clamp(0.0, c.maxHeight - _cropW);
                    }
                  });
                },
                child: Stack(
                  children: [
                    Transform.scale(
                      scale: _scale,
                      alignment: Alignment.center,
                      child: Image.file(File(widget.imagePath), fit: BoxFit.contain,
                          width: c.maxWidth, height: c.maxHeight),
                    ),
                    CustomPaint(
                      size: Size(c.maxWidth, c.maxHeight),
                      painter: _Mask(Rect.fromLTWH(_cropX, _cropY, _cropW, _cropW)),
                    ),
                    if (_busy) const Center(child: CircularProgressIndicator(color: Colors.white)),
                  ],
                ),
              );
            }),
    );
  }
}

class _Mask extends CustomPainter {
  final Rect crop;
  _Mask(this.crop);
  @override
  void paint(Canvas canvas, Size size) {
    final r = Rect.fromLTWH(0, 0, size.width, size.height);
    canvas.drawPath(Path.combine(PathOperation.difference, Path()..addRect(r), Path()..addRect(crop)), Paint()..color = Colors.black54);
    canvas.drawRect(crop, Paint()..color = Colors.white..style = PaintingStyle.stroke..strokeWidth = 2.0);
  }
  @override
  bool shouldRepaint(_Mask old) => old.crop != crop;
}
