import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

/// 扫码器 — 数字变焦 + scanWindow 缩小检测区
class ScannerView extends StatefulWidget {
  final void Function(String barcode) onDetect;
  final VoidCallback onClose;

  const ScannerView({
    super.key,
    required this.onDetect,
    required this.onClose,
  });

  @override
  State<ScannerView> createState() => _ScannerViewState();
}

class _ScannerViewState extends State<ScannerView>
    with SingleTickerProviderStateMixin {
  final MobileScannerController _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
    torchEnabled: false,
    facing: CameraFacing.back,
    returnImage: false,
  );
  bool _hasDetected = false;
  late final AnimationController _lineCtrl;
  late final Animation<double> _lineAnim;

  @override
  void initState() {
    super.initState();
    _lineCtrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);
    _lineAnim = Tween<double>(begin: 0.0, end: 1.0).animate(_lineCtrl);
  }

  @override
  void dispose() {
    _lineCtrl.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_hasDetected) return;
    final value = capture.barcodes.firstOrNull?.rawValue;
    if (value == null || value.isEmpty || value.length < 6) return;
    _hasDetected = true;
    widget.onDetect(value);
  }

  @override
  Widget build(BuildContext context) {
    final screenW = MediaQuery.of(context).size.width;
    // 镜头 2.5x 变焦 + 适中检测框
    final boxW = screenW * 0.75;
    final boxH = boxW * 0.55;

    // scanWindow 限制 ML Kit 只在框内检测
    final scanWindow = Rect.fromCenter(
      center: Offset(screenW / 2, MediaQuery.of(context).size.height / 2 - 30),
      width: boxW,
      height: boxH,
    );

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('扫码'),
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: widget.onClose,
        ),
      ),
      body: Stack(
        children: [
          MobileScanner(
            controller: _controller,
            onDetect: _onDetect,
          ),
          AnimatedBuilder(
            animation: _lineAnim,
            builder: (_, __) => CustomPaint(
              size: MediaQuery.of(context).size,
              painter: _ScanPainter(boxW, boxH, _lineAnim.value),
            ),
          ),
          Positioned(
            bottom: 50,
            left: 0,
            right: 0,
            child: Center(
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: const Text(
                  '将条码对准框内，保持 10-20cm 距离',
                  style: TextStyle(color: Colors.white70, fontSize: 13),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ScanPainter extends CustomPainter {
  final double boxW;
  final double boxH;
  final double linePos;

  _ScanPainter(this.boxW, this.boxH, this.linePos);

  @override
  void paint(Canvas canvas, Size size) {
    final boxRect = Rect.fromCenter(
      center: Offset(size.width / 2, size.height / 2 - 30),
      width: boxW,
      height: boxH,
    );

    // 半透明遮罩
    final mask = Path.combine(
      PathOperation.difference,
      Path()..addRect(Rect.fromLTWH(0, 0, size.width, size.height)),
      Path()..addRRect(
          RRect.fromRectAndRadius(boxRect, const Radius.circular(12))),
    );
    canvas.drawPath(mask, Paint()..color = Colors.black54);

    // 白色边框
    canvas.drawRRect(
      RRect.fromRectAndRadius(boxRect, const Radius.circular(12)),
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5,
    );

    // 红色扫描线
    final lineY = boxRect.top + boxRect.height * linePos;
    canvas.drawLine(
      Offset(boxRect.left + 10, lineY),
      Offset(boxRect.right - 10, lineY),
      Paint()
        ..color = Colors.red
        ..strokeWidth = 2.0
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
    );
  }

  @override
  bool shouldRepaint(_ScanPainter old) =>
      old.boxW != boxW || old.boxH != boxH || old.linePos != linePos;
}
