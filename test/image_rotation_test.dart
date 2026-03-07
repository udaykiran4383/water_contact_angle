import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as imglib;
import 'package:water_contact_angle/image_processor.dart';

List<math.Point<double>> _horizontalContour({
  double baselineY = 110.0,
  double centerX = 120.0,
  double radius = 36.0,
}) {
  final points = <math.Point<double>>[];

  for (int i = 0; i < 180; i++) {
    final t = i / 179.0;
    final x = centerX - radius * 2.2 + (radius * 4.4 * t);
    points.add(math.Point(x, baselineY));
  }

  for (int i = 0; i < 160; i++) {
    final t = i / 159.0;
    final angle = math.pi * t;
    final x = centerX + radius * math.cos(angle);
    final y = baselineY - radius * math.sin(angle);
    points.add(math.Point(x, y));
  }

  return points;
}

void main() {
  group('Rotation Utilities', () {
    test('rotatePoint -> rotatePointBack is lossless within tolerance', () {
      const p = math.Point<double>(75.25, 28.75);
      const cx = 120.0;
      const cy = 90.0;

      final rotated = ImageProcessor.debugRotatePoint(p, 13.5, cx, cy);
      final restored =
          ImageProcessor.debugRotatePointBack(rotated, 13.5, cx, cy);

      expect(restored.x, closeTo(p.x, 1e-9));
      expect(restored.y, closeTo(p.y, 1e-9));
    });

    test('rotation keeps point-to-point distance', () {
      const p1 = math.Point<double>(20.0, 40.0);
      const p2 = math.Point<double>(140.0, 80.0);
      const cx = 80.0;
      const cy = 70.0;

      final q1 = ImageProcessor.debugRotatePoint(p1, -22.0, cx, cy);
      final q2 = ImageProcessor.debugRotatePoint(p2, -22.0, cx, cy);

      final d0 = math.sqrt(math.pow(p2.x - p1.x, 2) + math.pow(p2.y - p1.y, 2));
      final d1 = math.sqrt(math.pow(q2.x - q1.x, 2) + math.pow(q2.y - q1.y, 2));
      expect(d1, closeTo(d0, 1e-9));
    });

    test('image rotation preserves geometry and center color', () {
      final image = imglib.Image(width: 64, height: 64);
      imglib.fill(image, color: imglib.ColorRgba8(25, 30, 35, 255));
      image.setPixelRgba(32, 32, 200, 90, 40, 255);

      final rotated = ImageProcessor.debugRotateImage(image, 11.0);

      expect(rotated.width, equals(64));
      expect(rotated.height, equals(64));
      final c = rotated.getPixel(32, 32);
      expect(c.r.toDouble(), closeTo(200.0, 3.0));
      expect(c.g.toDouble(), closeTo(90.0, 3.0));
      expect(c.b.toDouble(), closeTo(40.0, 3.0));
    });

    test('baseline can be leveled by inverse rotation', () {
      final base = _horizontalContour();
      const cx = 120.0;
      const cy = 120.0;

      final tilted = base
          .map((p) => ImageProcessor.debugRotatePoint(p, 6.0, cx, cy))
          .toList();
      final tiltedBaseline = ImageProcessor.debugDetectBaseline(tilted);
      final tiltedAngle = (tiltedBaseline['angle'] as num).toDouble();

      final leveled = tilted
          .map((p) => ImageProcessor.debugRotatePoint(p, -tiltedAngle, cx, cy))
          .toList();
      final leveledBaseline = ImageProcessor.debugDetectBaseline(leveled);
      final leveledAngle = ((leveledBaseline['angle'] as num).toDouble()).abs();

      expect(tiltedAngle.abs(), greaterThan(0.5));
      expect(leveledAngle, lessThan(0.5));
    });
  });
}
