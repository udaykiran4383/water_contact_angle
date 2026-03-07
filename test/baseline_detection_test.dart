import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:water_contact_angle/image_processor.dart';

List<math.Point<double>> _syntheticContour({
  double baselineY = 220.0,
  double centerX = 180.0,
  double radius = 58.0,
  double slopeDeg = 0.0,
  int baselinePoints = 260,
  int arcPoints = 180,
  double noisePx = 0.0,
}) {
  final points = <math.Point<double>>[];
  final slope = math.tan(slopeDeg * math.pi / 180.0);
  final rnd = math.Random(17);

  final xMin = centerX - radius * 2.8;
  final xMax = centerX + radius * 2.8;
  for (int i = 0; i < baselinePoints; i++) {
    final t = i / (baselinePoints - 1);
    final x = xMin + (xMax - xMin) * t;
    final jitter =
        noisePx > 0.0 ? (rnd.nextDouble() * 2.0 - 1.0) * noisePx : 0.0;
    final y = baselineY + slope * x + jitter;
    points.add(math.Point(x, y));
  }

  for (int i = 0; i < arcPoints; i++) {
    final t = i / (arcPoints - 1);
    final angle = math.pi * t;
    final x = centerX + radius * math.cos(angle);
    final y = baselineY - radius * math.sin(angle) + slope * x;
    points.add(math.Point(x, y));
  }

  return points;
}

List<math.Point<double>> _alignedDropWithCenterNoise() {
  const radius = 55.0;
  final points = <math.Point<double>>[];

  for (int i = 0; i < 220; i++) {
    final t = i / 219.0;
    final x = -radius + (2.0 * radius * t);
    final y = -math.sqrt(math.max(0.0, radius * radius - x * x));
    points.add(math.Point(x, y));
  }

  // Add baseline-adjacent noisy points biased toward the center,
  // which previously pulled contacts inward on both sides.
  const centerNoise = [
    -20.0,
    -16.0,
    -12.0,
    -9.0,
    -7.0,
    -5.0,
    5.0,
    7.0,
    9.0,
    12.0,
    16.0,
    20.0,
  ];
  for (final x in centerNoise) {
    points.add(math.Point(x, -0.7));
  }

  return points;
}

void main() {
  group('Baseline Detection', () {
    test('horizontal contour stays in horizontal fast path', () {
      final contour = _syntheticContour(slopeDeg: 0.0);
      final baseline = ImageProcessor.debugDetectBaseline(contour);
      final angle = ((baseline['angle'] as num?)?.toDouble() ?? 0.0).abs();
      final mode = angle < 0.5 ? 'HORIZONTAL_FAST_PATH' : 'SLOPED_SURFACE';

      expect(angle, lessThan(0.5));
      expect(mode, equals('HORIZONTAL_FAST_PATH'));
    });

    test('5 degree slope enters sloped-surface mode', () {
      final contour = _syntheticContour(slopeDeg: 5.0);
      final baseline = ImageProcessor.debugDetectBaseline(contour);
      final angle = (baseline['angle'] as num).toDouble();
      final mode =
          angle.abs() < 0.5 ? 'HORIZONTAL_FAST_PATH' : 'SLOPED_SURFACE';

      expect(angle.abs(), closeTo(5.0, 1.2));
      expect(mode, equals('SLOPED_SURFACE'));
    });

    test('baseline confidence drops when baseline points are noisy', () {
      final clean = ImageProcessor.debugDetectBaseline(
        _syntheticContour(slopeDeg: 0.0, noisePx: 0.15),
      );
      final noisy = ImageProcessor.debugDetectBaseline(
        _syntheticContour(slopeDeg: 0.0, noisePx: 3.5),
      );

      final cleanConf = (clean['confidence'] as num).toDouble();
      final noisyConf = (noisy['confidence'] as num).toDouble();

      expect(cleanConf, inInclusiveRange(0.0, 1.0));
      expect(noisyConf, inInclusiveRange(0.0, 1.0));
      expect(cleanConf, greaterThan(noisyConf));
    });

    test('contact estimation stays on outer flanks, not center noise', () {
      final aligned = _alignedDropWithCenterNoise();
      final contacts = ImageProcessor.debugDetectContactsAligned(aligned);
      final leftX = contacts['leftX']!;
      final rightX = contacts['rightX']!;

      expect(leftX.isFinite, isTrue);
      expect(rightX.isFinite, isTrue);
      expect(leftX, lessThan(-26.0));
      expect(rightX, greaterThan(26.0));
      expect(rightX - leftX, greaterThan(52.0));
    });
  });
}
