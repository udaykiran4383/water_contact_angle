import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:water_contact_angle/image_processor.dart';

/// Objective, noise-free precision harness.
///
/// We render analytic sessile-drop silhouettes whose contact angle is known
/// EXACTLY (a spherical cap sitting on a dark substrate, back-lit: dark drop +
/// dark stage on a bright background). Anti-aliasing by super-sampling puts the
/// true edge at the 50%-intensity crossing, so this measures the pipeline's
/// sub-pixel edge + baseline + angle recovery against ground truth — something
/// the 12 real PFOTES photos cannot do (their "truth" is itself a manual fit).
///
/// A spherical cap is the exact zero-Bond Young–Laplace solution, so every
/// method (circle, ellipse, polynomial, ADSA) should recover it. Deviations are
/// pipeline error, not physics.

const int _kW = 640;
const int _kH = 480;
const double _kCx = 320.0;
const double _kBaselineY = 360.0; // image-coords row of the substrate top
const double _kR = 150.0; // sphere radius in pixels
const int _kSS = 8; // super-sampling factor per axis (8x8 = 64 samples/px)
const int _kFg = 40; // dark silhouette (drop + stage)
const int _kBg = 235; // bright back-light

/// Render a spherical-cap silhouette for contact angle [thetaDeg].
///
/// Optional [tiltDeg] rotates the whole scene about the drop apex to emulate a
/// non-level stage; [noiseSigma] adds Gaussian sensor noise.
img.Image _renderCap(double thetaDeg,
    {double tiltDeg = 0.0, double noiseSigma = 0.0, int seed = 1}) {
  final theta = thetaDeg * math.pi / 180.0;
  // Analytic geometry (math y-up, baseline at Y=0): circle center height above
  // the baseline is h = -R*cos(theta); contact half-width a = R*sin(theta).
  final h = -_kR * math.cos(theta);
  final centerYImg = _kBaselineY - h; // image row of the circle center
  final rnd = math.Random(seed);
  final cosT = math.cos(-tiltDeg * math.pi / 180.0);
  final sinT = math.sin(-tiltDeg * math.pi / 180.0);

  bool isDark(double px, double py) {
    // Rotate the sample point about the apex to apply stage tilt.
    double x = px, y = py;
    if (tiltDeg != 0.0) {
      final ax = _kCx, ay = _kBaselineY;
      final dx = px - ax, dy = py - ay;
      x = ax + dx * cosT - dy * sinT;
      y = ay + dx * sinT + dy * cosT;
    }
    if (y >= _kBaselineY) return true; // substrate/stage
    final dx = x - _kCx, dy = y - centerYImg;
    return dx * dx + dy * dy <= _kR * _kR; // inside the drop cap
  }

  final out = img.Image(width: _kW, height: _kH);
  final inv = 1.0 / (_kSS * _kSS);
  for (int yy = 0; yy < _kH; yy++) {
    for (int xx = 0; xx < _kW; xx++) {
      int dark = 0;
      for (int sy = 0; sy < _kSS; sy++) {
        final py = yy + (sy + 0.5) / _kSS;
        for (int sx = 0; sx < _kSS; sx++) {
          final px = xx + (sx + 0.5) / _kSS;
          if (isDark(px, py)) dark++;
        }
      }
      final coverage = dark * inv;
      double v = _kBg - coverage * (_kBg - _kFg);
      if (noiseSigma > 0) {
        // Box–Muller Gaussian noise.
        final u1 = rnd.nextDouble().clamp(1e-9, 1.0);
        final u2 = rnd.nextDouble();
        final g = math.sqrt(-2 * math.log(u1)) * math.cos(2 * math.pi * u2);
        v += g * noiseSigma;
      }
      final g = v.round().clamp(0, 255);
      out.setPixelRgb(xx, yy, g, g, g);
    }
  }
  return out;
}

Future<Map<String, dynamic>> _run(img.Image im, String tag) async {
  final dir = Directory.systemTemp.createTempSync('synth_$tag');
  final f = File('${dir.path}/$tag.png');
  f.writeAsBytesSync(img.encodePng(im));
  final r = await ImageProcessor.processImage(f);
  try {
    dir.deleteSync(recursive: true);
  } catch (_) {}
  return r;
}

double? _num(Map<String, dynamic> r, String k) {
  final v = (r[k] as num?)?.toDouble();
  return (v != null && v.isFinite) ? v : null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const root = '/Users/uday/btp/water_contact_angle';

  test('synthetic spherical-cap contact-angle recovery (clean)',
      timeout: const Timeout(Duration(minutes: 5)), () async {
    final angles = [95.0, 105.0, 115.0, 125.0, 135.0, 145.0];
    final rows = <String>['theta_true,ensemble,err,yl,circle,poly,ellipse'];
    double sumErr = 0, maxErr = 0, sumYlErr = 0;
    int n = 0, nYl = 0;

    for (final t in angles) {
      final r = await _run(_renderCap(t), 'clean_${t.round()}');
      final ens = _num(r, 'angle_numeric');
      final yl = _num(r, 'theta_young_laplace');
      final circle = _num(r, 'theta_circle');
      final poly = _num(r, 'theta_poly');
      final ell = _num(r, 'theta_ellipse');
      final err = ens != null ? (ens - t).abs() : double.nan;
      if (err.isFinite) {
        sumErr += err;
        if (err > maxErr) maxErr = err;
        n++;
      }
      if (yl != null) {
        sumYlErr += (yl - t).abs();
        nYl++;
      }
      String f(double? v) => v != null ? v.toStringAsFixed(2) : '-';
      rows.add('${t.toStringAsFixed(1)},${f(ens)},${f(err)},${f(yl)},'
          '${f(circle)},${f(poly)},${f(ell)}');
    }

    final mae = n > 0 ? sumErr / n : double.nan;
    final ylMae = nYl > 0 ? sumYlErr / nYl : double.nan;
    rows.add('# ensemble_MAE=${mae.toStringAsFixed(3)}, '
        'maxErr=${maxErr.toStringAsFixed(3)}, '
        'yl_MAE=${ylMae.toStringAsFixed(3)}, n=$n/${angles.length}');
    File('$root/synthetic_precision_report.csv')
        .writeAsStringSync('${rows.join('\n')}\n');
    // ignore: avoid_print
    print(rows.join('\n'));

    expect(n, angles.length, reason: 'pipeline failed on some synthetic caps');
    // On perfect, noise-free geometry the pipeline must be near-exact. These
    // bounds lock in the sub-pixel-edge + working circle/ellipse/ADSA ensemble
    // (observed MAE ~0.22 deg, max ~0.47 deg) against regression.
    expect(mae, lessThanOrEqualTo(0.6),
        reason: 'synthetic MAE regressed: $mae');
    expect(maxErr, lessThanOrEqualTo(1.0),
        reason: 'synthetic max error regressed: $maxErr');
  });

  test('synthetic recovery under noise, tilt and small drops (stress)',
      timeout: const Timeout(Duration(minutes: 8)), () async {
    final cases = <String, img.Image>{
      'noise4_115': _renderCap(115, noiseSigma: 4, seed: 2),
      'noise4_135': _renderCap(135, noiseSigma: 4, seed: 3),
      'noise8_125': _renderCap(125, noiseSigma: 8, seed: 4),
      'tilt5_120': _renderCap(120, tiltDeg: 5),
      'tilt-4_130': _renderCap(130, tiltDeg: -4),
      'small_R_115': _renderCapSmall(115, 65),
      'small_R_140': _renderCapSmall(140, 65),
    };
    final truth = <String, double>{
      'noise4_115': 115,
      'noise4_135': 135,
      'noise8_125': 125,
      'tilt5_120': 120,
      'tilt-4_130': 130,
      'small_R_115': 115,
      'small_R_140': 140,
    };
    final rows = <String>['case,theta_true,ensemble,err,yl,circle,poly,ellipse'];
    double sumErr = 0, maxErr = 0;
    int n = 0;
    for (final e in cases.entries) {
      final r = await _run(e.value, e.key);
      final t = truth[e.key]!;
      final ens = _num(r, 'angle_numeric');
      final err = ens != null ? (ens - t).abs() : double.nan;
      if (err.isFinite) {
        sumErr += err;
        if (err > maxErr) maxErr = err;
        n++;
      }
      String f(double? v) => v != null ? v.toStringAsFixed(2) : '-';
      rows.add('${e.key},${t.toStringAsFixed(1)},${f(ens)},${f(err)},'
          '${f(_num(r, "theta_young_laplace"))},${f(_num(r, "theta_circle"))},'
          '${f(_num(r, "theta_poly"))},${f(_num(r, "theta_ellipse"))}');
    }
    final mae = n > 0 ? sumErr / n : double.nan;
    rows.add('# stress_MAE=${mae.toStringAsFixed(3)}, '
        'maxErr=${maxErr.toStringAsFixed(3)}, n=$n/${cases.length}');
    File('$root/synthetic_stress_report.csv')
        .writeAsStringSync('${rows.join('\n')}\n');
    // ignore: avoid_print
    print(rows.join('\n'));

    expect(n, cases.length, reason: 'pipeline failed on some stress cases');
    // Observed stress MAE ~0.51 deg, worst (+5 deg tilt) ~1.76 deg. Lock in.
    expect(mae, lessThanOrEqualTo(1.0), reason: 'stress MAE regressed: $mae');
    expect(maxErr, lessThanOrEqualTo(2.5),
        reason: 'stress max error regressed: $maxErr');
  });
}

/// Render a smaller cap (radius [rPix]) to expose edge-quantization error, which
/// averages down as 1/sqrt(N) and so bites harder when there are fewer points.
img.Image _renderCapSmall(double thetaDeg, double rPix) {
  final theta = thetaDeg * math.pi / 180.0;
  final h = -rPix * math.cos(theta);
  final centerYImg = _kBaselineY - h;
  final out = img.Image(width: _kW, height: _kH);
  final inv = 1.0 / (_kSS * _kSS);
  for (int yy = 0; yy < _kH; yy++) {
    for (int xx = 0; xx < _kW; xx++) {
      int dark = 0;
      for (int sy = 0; sy < _kSS; sy++) {
        final py = yy + (sy + 0.5) / _kSS;
        for (int sx = 0; sx < _kSS; sx++) {
          final px = xx + (sx + 0.5) / _kSS;
          final isDark = py >= _kBaselineY ||
              ((px - _kCx) * (px - _kCx) +
                      (py - centerYImg) * (py - centerYImg) <=
                  rPix * rPix);
          if (isDark) dark++;
        }
      }
      final coverage = dark * inv;
      final g = (_kBg - coverage * (_kBg - _kFg)).round().clamp(0, 255);
      out.setPixelRgb(xx, yy, g, g, g);
    }
  }
  return out;
}
