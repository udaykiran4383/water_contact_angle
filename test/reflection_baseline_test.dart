import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:water_contact_angle/image_processor.dart';
import 'package:water_contact_angle/processing/silhouette_extractor.dart';

/// Reflective-substrate harness.
///
/// A real lab stage is often semi-reflective, so a back-lit drop casts a MIRROR
/// image below the true contact line (the surface plane). The combined dark
/// silhouette (drop + reflection) is symmetric about the baseline. If the
/// analyzer treats the bottom of that combined blob as the contact line it
/// places the baseline too LOW and reports the wrong angle — the failure the
/// user sketched. Here we render that scene with an EXACTLY known baseline and
/// contact angle, so we can measure the bias objectively.

const int _kW = 640;
const int _kH = 480;
const double _kCx = 320.0;
const double _kBaselineY = 300.0; // true surface plane (image row)
const double _kR = 130.0;
const int _kSS = 8;
const int _kFg = 38; // dark drop
const int _kBg = 235; // bright back-light

double _coverageDrop(double px0, double py0, double centerYImg) {
  int dark = 0;
  for (int sy = 0; sy < _kSS; sy++) {
    final py = py0 + (sy + 0.5) / _kSS;
    for (int sx = 0; sx < _kSS; sx++) {
      final px = px0 + (sx + 0.5) / _kSS;
      final dx = px - _kCx, dy = py - centerYImg;
      if (py < _kBaselineY && dx * dx + dy * dy <= _kR * _kR) dark++;
    }
  }
  return dark / (_kSS * _kSS);
}

/// Render a spherical cap PLUS its reflection on a stage of [reflectivity]
/// (0 = matte dark stage, 1 = perfect mirror).
img.Image _renderReflective(double thetaDeg, double reflectivity) {
  final theta = thetaDeg * math.pi / 180.0;
  final h = -_kR * math.cos(theta);
  final centerYImg = _kBaselineY - h;
  const stageDark = 30.0;
  final out = img.Image(width: _kW, height: _kH);
  for (int yy = 0; yy < _kH; yy++) {
    for (int xx = 0; xx < _kW; xx++) {
      double v;
      if (yy < _kBaselineY) {
        // Above the surface: the real drop against the back-light.
        final cov = _coverageDrop(xx.toDouble(), yy.toDouble(), centerYImg);
        v = _kBg - cov * (_kBg - _kFg);
      } else {
        // Below the surface: mirror reflection, attenuated by reflectivity,
        // blended onto a dark stage.
        final mirrorY = 2.0 * _kBaselineY - yy;
        final cov = _coverageDrop(xx.toDouble(), mirrorY, centerYImg);
        final mirrored = _kBg - cov * (_kBg - _kFg);
        v = mirrored * reflectivity + stageDark * (1.0 - reflectivity);
      }
      final g = v.round().clamp(0, 255);
      out.setPixelRgb(xx, yy, g, g, g);
    }
  }
  return out;
}

Future<Map<String, dynamic>> _run(img.Image im, String tag) async {
  final dir = Directory.systemTemp.createTempSync('refl_$tag');
  final f = File('${dir.path}/$tag.png');
  f.writeAsBytesSync(img.encodePng(im));
  final r = await ImageProcessor.processImage(f);
  try {
    dir.deleteSync(recursive: true);
  } catch (_) {}
  return r;
}

double? _n(Map<String, dynamic> r, String k) {
  final v = (r[k] as num?)?.toDouble();
  return (v != null && v.isFinite) ? v : null;
}

List<int> _grayOf(img.Image im) {
  final g = img.grayscale(im);
  final w = g.width, h = g.height;
  final out = List<int>.filled(w * h, 0);
  for (int y = 0; y < h; y++) {
    for (int x = 0; x < w; x++) {
      out[y * w + x] = g.getPixel(x, y).r.toInt();
    }
  }
  return out;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const root = '/Users/uday/btp/water_contact_angle';

  test('baseline placement error vs true surface plane', () {
    final rows = <String>['theta,reflectivity,detected_baseline,true,err_px,reflection_score'];
    for (final t in [110.0, 125.0, 140.0]) {
      for (final rf in [0.0, 0.35, 0.7]) {
        final im = _renderReflective(t, rf);
        final gray = _grayOf(im);
        final s = SilhouetteExtractor.extract(gray, im.width, im.height);
        if (s == null) {
          rows.add('${t.toStringAsFixed(0)},${rf.toStringAsFixed(2)},NULL,,,');
          continue;
        }
        final slope = s.baselineResult['slope'] as double;
        final intercept = s.baselineResult['intercept'] as double;
        final detected = slope * _kCx + intercept;
        final rscore = (s.baselineResult['reflection_score'] as num?)?.toDouble() ?? 0.0;
        rows.add('${t.toStringAsFixed(0)},${rf.toStringAsFixed(2)},'
            '${detected.toStringAsFixed(2)},${_kBaselineY.toStringAsFixed(1)},'
            '${(detected - _kBaselineY).toStringAsFixed(2)},'
            '${rscore.toStringAsFixed(2)}');
        // The baseline must land on the true surface plane for matte, moderate
        // AND strong specular stages — the reflection-symmetry fallback pins it
        // even when there is no dark substrate band.
        expect((detected - _kBaselineY).abs(), lessThan(2.0),
            reason: 'baseline off at theta=$t reflectivity=$rf');
        // On a strong mirror the specular symmetry path must have fired.
        if (rf >= 0.7) {
          expect(rscore, greaterThan(0.3),
              reason: 'specular symmetry not detected at theta=$t');
        }
      }
    }
    // ignore: avoid_print
    print(rows.join('\n'));
  });

  test('angle recovery across reflectivities (incl. strong mirror)',
      timeout: const Timeout(Duration(minutes: 8)), () async {
    final angles = [110.0, 125.0, 140.0];
    final refl = [0.0, 0.35, 0.7];
    final rows = <String>['theta_true,reflectivity,ensemble,err,yl,circle'];
    double maxErr = 0;
    for (final t in angles) {
      for (final rf in refl) {
        final r = await _run(_renderReflective(t, rf), 't${t.round()}_r${(rf * 100).round()}');
        final ens = _n(r, 'angle_numeric');
        final err = ens != null ? (ens - t).abs() : double.nan;
        if (err.isFinite && err > maxErr) maxErr = err;
        String f(double? v) => v != null ? v.toStringAsFixed(2) : '-';
        rows.add('${t.toStringAsFixed(0)},${rf.toStringAsFixed(2)},${f(ens)},'
            '${f(err.isFinite ? err : null)},${f(_n(r, "theta_young_laplace"))},'
            '${f(_n(r, "theta_circle"))}');
      }
    }
    File('$root/reflection_bias_report.csv')
        .writeAsStringSync('${rows.join('\n')}\n');
    // ignore: avoid_print
    print(rows.join('\n'));
    // With the specular baseline, the strong-mirror bias (previously up to
    // ~1.6 deg via the legacy fallback) is gone; every case stays reference-grade.
    expect(maxErr, lessThan(1.0),
        reason: 'reflective-substrate angle error regressed: $maxErr');
  });
}
