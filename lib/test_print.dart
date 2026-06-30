import 'package:barcode/barcode.dart';
import 'package:image/image.dart' as img;
import 'dart:io';

void main() {
  final data = '6901234567890';
  final dpi = 203;

  for (final bc in [
    MapEntry('code93', Barcode.code93()),
    MapEntry('gs1-128', Barcode.gs128()),
    MapEntry('codabar', Barcode.codabar()),
  ]) {
    try {
      final svg = bc.value.toSvg(data, width: 240.0, height: 60.0, drawText: true);
      final pathMatch = RegExp(r'd="([^"]+)"').firstMatch(svg);
      if (pathMatch == null) continue;
      final pathStr = pathMatch.group(1)!;

      final image = img.Image(240, 80);
      img.fill(image, 0xFFFFFFFF);
      final segments = pathStr.split('M').where((s) => s.trim().isNotEmpty);
      for (final seg in segments) {
        final nums = RegExp(r'[-0-9.]+').allMatches(seg).map((m) => double.parse(m.group(0)!)).toList();
        if (nums.length >= 3) {
          final x = nums[0].round();
          final w = nums[2].round();
          if (w > 0) img.fillRect(image, x, 0, x + w, 60, 0xFF000000);
        }
      }

      final out = File('test_${bc.key}.png');
      out.writeAsBytesSync(img.encodePng(image));
      print('${bc.key}: ${out.absolute.path} (${image.width}x${image.height}px = ${(image.width/dpi*25.4).toStringAsFixed(1)}mm)');
    } catch (e) {
      print('${bc.key}: ERROR - $e');
    }
  }
}
