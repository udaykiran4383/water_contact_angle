import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:water_contact_angle/processing/young_laplace.dart';

void main() {
  group('YoungLaplaceSolver', () {
    test('fitContour returns finite solution for synthetic contour', () {
      const baselineY = 300.0;
      const centerX = 200.0;
      const scale = 80.0;
      const targetHeightRatio = 1.35;

      final profile = YoungLaplaceSolver.integrateProfile(
        apexCurvature: 1.0,
        bondNumber: 0.55,
        numSteps: 700,
        maxArcLength: 5.0,
      );

      final contour = <math.Point<double>>[];
      for (final p in profile) {
        if (p[1] > targetHeightRatio) break;
        final y = baselineY - p[1] * scale;
        if (y >= baselineY) continue;
        contour.add(math.Point(centerX - p[0] * scale, y));
        contour.add(math.Point(centerX + p[0] * scale, y));
      }

      final fit = YoungLaplaceSolver.fitContour(
        contour,
        baselineY,
        dropRadiusPixels: scale,
      );

      expect(fit['contact_angle']!, greaterThan(80.0));
      expect(fit['contact_angle']!, lessThan(180.0));
      expect(fit['r_squared']!, greaterThan(0.75));
      expect(fit['residual']!, lessThan(0.25));
    });
  });
}
