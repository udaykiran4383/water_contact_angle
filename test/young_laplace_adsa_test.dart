import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:water_contact_angle/processing/young_laplace.dart';

class _Cap {
  final List<math.Point<double>> pts;
  final double baselineY;
  _Cap(this.pts, this.baselineY);
}

/// Generate a spherical-cap silhouette (zero-gravity / Bond→0 ground truth)
/// of known contact angle [thetaDeg], sphere radius [r] px, apex at (cx, apexY).
_Cap _sphericalCap(double thetaDeg, double r, double cx, double apexY) {
  final theta = thetaDeg * math.pi / 180.0;
  final pts = <math.Point<double>>[];
  // psi is the polar angle from the apex; tangent angle from horizontal == psi.
  const steps = 200;
  for (int i = 0; i <= steps; i++) {
    final psi = theta * i / steps;
    final x = r * math.sin(psi);
    final z = r * (1 - math.cos(psi)); // depth below apex
    pts.add(math.Point<double>(cx + x, apexY + z));
    if (i != 0) pts.add(math.Point<double>(cx - x, apexY + z));
  }
  final baselineY = apexY + r * (1 - math.cos(theta));
  return _Cap(pts, baselineY);
}

void main() {
  group('ADSA Young-Laplace solver accuracy', () {
    // Bond→0 spherical caps: exact ground truth for contact angle.
    for (final theta in [50.0, 70.0, 90.0, 110.0, 130.0, 150.0]) {
      test('recovers spherical-cap contact angle ${theta.toInt()}°', () {
        final cap = _sphericalCap(theta, 160.0, 320.0, 60.0);
        final res = YoungLaplaceSolver.fitContour(cap.pts, cap.baselineY);
        final fitted = res['contact_angle']!;
        expect(fitted.isFinite, isTrue, reason: 'fit failed for theta=$theta');
        expect((fitted - theta).abs(), lessThan(2.0),
            reason: 'theta=$theta fitted=$fitted r2=${res['r_squared']}');
        // Spherical cap is a near-perfect fit -> high R², low residual.
        expect(res['r_squared']!, greaterThan(0.97));
        expect(res['residual']!, lessThan(0.02));
      });
    }

    // Noise robustness: ~1px sub-pixel noise should not move theta much.
    test('robust to ~1px contour noise', () {
      final cap = _sphericalCap(120.0, 150.0, 300.0, 50.0);
      final rnd = math.Random(11);
      final noisy = cap.pts
          .map((p) => math.Point<double>(p.x + (rnd.nextDouble() - 0.5) * 1.0,
              p.y + (rnd.nextDouble() - 0.5) * 1.0))
          .toList();
      final res = YoungLaplaceSolver.fitContour(noisy, cap.baselineY);
      final fitted = res['contact_angle']!;
      expect(fitted.isFinite, isTrue);
      expect((fitted - 120.0).abs(), lessThan(3.0),
          reason: 'fitted=$fitted r2=${res['r_squared']}');
    });
  });
}
