import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:water_contact_angle/processing/angle_utils.dart';

void main() {
  group('AngleUtils circleFit', () {
    test('reports high quality for a clean circular arc', () {
      const cx = 80.0;
      const cy = -30.0;
      const r = 42.0;
      final xs = <double>[];
      final ys = <double>[];

      for (int i = 20; i <= 160; i += 4) {
        final t = i * math.pi / 180.0;
        xs.add(cx + r * math.cos(t));
        ys.add(cy + r * math.sin(t));
      }

      final fit = AngleUtils.circleFit(xs, ys);
      final rSq = fit[3];

      expect(fit[2], closeTo(r, 0.8));
      expect(rSq, greaterThan(0.9));
    });
  });

  group('AngleUtils polynomialAngleDetailed', () {
    test('recovers symmetric contact angles for a smooth droplet flank', () {
      const double contactLeft = 5.0;
      const double contactRight = 95.0;

      final leftPoints = <math.Point<double>>[];
      final rightPoints = <math.Point<double>>[];

      for (int x = 5; x <= 35; x++) {
        final xf = x.toDouble();
        final y = 0.01 * (xf - 50.0) * (xf - 50.0) - 20.25;
        leftPoints.add(math.Point(xf, y));
      }
      for (int x = 65; x <= 95; x++) {
        final xf = x.toDouble();
        final y = 0.01 * (xf - 50.0) * (xf - 50.0) - 20.25;
        rightPoints.add(math.Point(xf, y));
      }

      final left = AngleUtils.polynomialAngleDetailed(
        leftPoints,
        contactLeft,
        0.0,
        true,
        degree: 4,
        useWeighting: true,
      );
      final right = AngleUtils.polynomialAngleDetailed(
        rightPoints,
        contactRight,
        0.0,
        false,
        degree: 4,
        useWeighting: true,
      );

      expect(left['angle']!, inInclusiveRange(130.0, 150.0));
      expect(right['angle']!, inInclusiveRange(130.0, 150.0));
      expect((left['angle']! - right['angle']!).abs(), lessThan(2.0));
      expect(left['r_squared']!, greaterThan(0.95));
      expect(right['r_squared']!, greaterThan(0.95));
    });

    test('stays stable with large coordinate magnitudes', () {
      const double x0 = 1.0e6;
      final points = <math.Point<double>>[];
      for (int i = 0; i <= 30; i++) {
        final x = x0 + i.toDouble();
        final y = -0.5 * (x - x0);
        points.add(math.Point(x, y));
      }

      final result = AngleUtils.polynomialAngleDetailed(
        points,
        x0,
        0.0,
        true,
        degree: 4,
        useWeighting: true,
      );

      // Expected interior contact angle for slope -0.5 on left flank.
      expect(result['angle']!, closeTo(153.435, 1.0));
      expect(result['r_squared']!, greaterThan(0.99));
    });
  });
}
