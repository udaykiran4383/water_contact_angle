import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:water_contact_angle/processing/angle_utils.dart';

/// Unit tests for the primitive geometric fits, using exact analytic shapes so
/// the recovered parameters have a known ground truth. These guard the sign /
/// conditioning bugs found in the precision audit (circle R², ellipse center).
void main() {
  test('circleFit recovers a known circle with geometric R² ~ 1', () {
    const cx = 120.0, cy = 90.0, r = 60.0;
    final xs = <double>[], ys = <double>[];
    // Partial arc (a sessile-drop cap is < 360°) to catch arc-bias too.
    for (double deg = 200; deg <= 340; deg += 4) {
      final t = deg * math.pi / 180.0;
      xs.add(cx + r * math.cos(t));
      ys.add(cy + r * math.sin(t));
    }
    final res = AngleUtils.circleFit(xs, ys);
    expect(res[0], closeTo(cx, 0.5));
    expect(res[1], closeTo(cy, 0.5));
    expect(res[2], closeTo(r, 0.5));
    // The clean-arc case is exactly where the old radial-variance R² collapsed;
    // the geometric R² must now read ~1 so the fit is not spuriously rejected.
    expect(res[3], greaterThan(0.99));
  });

  test('ellipseFit recovers a known axis-aligned ellipse', () {
    const cx = 100.0, cy = 80.0, a = 50.0, b = 30.0;
    final xs = <double>[], ys = <double>[];
    for (double deg = 0; deg < 360; deg += 5) {
      final t = deg * math.pi / 180.0;
      xs.add(cx + a * math.cos(t));
      ys.add(cy + b * math.sin(t));
    }
    final res = AngleUtils.ellipseFit(xs, ys);
    // res = [cx, cy, semiA, semiB, theta, rSquared]
    expect(res[0], closeTo(cx, 1.0), reason: 'ellipse center x wrong');
    expect(res[1], closeTo(cy, 1.0), reason: 'ellipse center y wrong');
    final semiMajor = math.max(res[2], res[3]);
    final semiMinor = math.min(res[2], res[3]);
    expect(semiMajor, closeTo(a, 2.0), reason: 'semi-major wrong');
    expect(semiMinor, closeTo(b, 2.0), reason: 'semi-minor wrong');
    expect(res[5], greaterThan(0.98), reason: 'ellipse R² should be ~1');
  });

  test('ellipseFit recovers a rotated ellipse center', () {
    const cx = 60.0, cy = 140.0, a = 70.0, b = 40.0;
    const rot = 0.6; // radians
    final xs = <double>[], ys = <double>[];
    for (double deg = 0; deg < 360; deg += 5) {
      final t = deg * math.pi / 180.0;
      final ux = a * math.cos(t), uy = b * math.sin(t);
      xs.add(cx + ux * math.cos(rot) - uy * math.sin(rot));
      ys.add(cy + ux * math.sin(rot) + uy * math.cos(rot));
    }
    final res = AngleUtils.ellipseFit(xs, ys);
    expect(res[0], closeTo(cx, 1.5), reason: 'rotated ellipse center x wrong');
    expect(res[1], closeTo(cy, 1.5), reason: 'rotated ellipse center y wrong');
    expect(res[5], greaterThan(0.98), reason: 'rotated ellipse R² should be ~1');
  });
}
