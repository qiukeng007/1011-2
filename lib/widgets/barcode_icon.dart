import 'package:flutter/material.dart';

/// 条码扫码图标
class BarcodeIcon extends StatelessWidget {
  final double size;
  final Color? color;

  const BarcodeIcon({super.key, this.size = 24, this.color});

  @override
  Widget build(BuildContext context) {
    final c = color ?? Colors.white;
    return SizedBox(
      width: size, height: size,
      child: Center(
        child: CustomPaint(
          size: Size(size * 0.85, size * 0.7),
          painter: _BarcodePainter(c),
        ),
      ),
    );
  }
}

class _BarcodePainter extends CustomPainter {
  final Color color;
  _BarcodePainter(this.color);
  // 条码竖线宽度序列
  static const bars = [3.0,1.0,2.5,2.0,1.5,3.5,1.0,3.0,1.5,2.5,2.0,1.0,3.5,1.0,2.0,3.0];

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color..strokeCap = StrokeCap.butt;
    final totalW = bars.fold(1.5, (a,b) => a + b + 0.8);
    double x = (size.width - totalW) / 2;
    final h = size.height;
    for (var i = 0; i < bars.length; i++) {
      final w = bars[i];
      paint.strokeWidth = w;
      final cx = x + w / 2;
      canvas.drawLine(Offset(cx, 0), Offset(cx, h), paint);
      x += w + 0.8;
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter old) => false;
}
