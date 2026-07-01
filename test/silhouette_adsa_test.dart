import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:water_contact_angle/processing/silhouette_extractor.dart';
import 'package:water_contact_angle/processing/young_laplace.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const root = '/Users/uday/btp/water_contact_angle';

  test('silhouette extractor + ADSA vs ground truth (standalone)', () {
    final gtFile = File('$root/PFOTES/ground_truth.csv');
    final gt = <String, double>{};
    for (final line in gtFile.readAsLinesSync().skip(1)) {
      if (line.trim().isEmpty) continue;
      final c = line.split(',');
      gt[c[0].trim()] = double.parse(c[1].trim());
    }

    double sumErr = 0;
    int n = 0, fired = 0;
    final rows = <String>['source,reference,adsa,abs_err,conf,dropW,dropH'];

    for (final e in gt.entries) {
      File? f;
      for (final ext in ['JPG', 'jpg', 'jpeg']) {
        final c = File('$root/PFOTES/${e.key}.$ext');
        if (c.existsSync()) {
          f = c;
          break;
        }
      }
      if (f == null) continue;

      final decoded = img.decodeImage(f.readAsBytesSync())!;
      final g = img.grayscale(decoded);
      final w = g.width, h = g.height;
      final gray = List<int>.filled(w * h, 0);
      for (int y = 0; y < h; y++) {
        for (int x = 0; x < w; x++) {
          gray[y * w + x] = g.getPixel(x, y).r.toInt();
        }
      }
      // Polarity: ensure bright background (match pipeline convention,
      // which samples only the TOP of the frame — far from the substrate).
      double corner = 0;
      int cn = 0;
      final ch = (h * 0.12).round().clamp(8, 60);
      for (int yy = 0; yy < ch; yy++) {
        for (int x = 0; x < w; x += 5) {
          corner += gray[yy * w + x];
          cn++;
        }
      }
      corner /= cn;
      if (corner < 100) {
        for (int i = 0; i < gray.length; i++) {
          gray[i] = 255 - gray[i];
        }
      }

      final s = SilhouetteExtractor.extract(gray, w, h);
      if (s == null) {
        rows.add('${e.key},${e.value.toStringAsFixed(2)},NULL,-,-,-,-');
        continue;
      }
      // Align: baseline approx horizontal -> baselineY at drop centre.
      final cx = (s.leftContactX + s.rightContactX) / 2.0;
      final slope = s.baselineResult['slope'] as double;
      final intercept = s.baselineResult['intercept'] as double;
      final baselineY = slope * cx + intercept;
      final adsa = YoungLaplaceSolver.fitContour(
        s.contour,
        baselineY,
        dropRadiusPixels: (s.rightContactX - s.leftContactX) / 2.0,
      );
      final ang = adsa['contact_angle']!;
      final err = (ang.isFinite) ? (ang - e.value).abs() : double.nan;
      if (ang.isFinite) {
        fired++;
        sumErr += err;
        n++;
      }
      rows.add(
          '${e.key},${e.value.toStringAsFixed(2)},${ang.isFinite ? ang.toStringAsFixed(2) : "NaN"},${err.isFinite ? err.toStringAsFixed(2) : "-"},${s.confidence.toStringAsFixed(2)},${s.dropWidth.toStringAsFixed(0)},${s.dropHeight.toStringAsFixed(0)}');
    }

    final mae = n > 0 ? sumErr / n : double.nan;
    rows.add('# MAE=${mae.toStringAsFixed(2)} fired=$fired/${gt.length}');
    // ignore: avoid_print
    print(rows.join('\n'));
    File('$root/silhouette_adsa_report.csv').writeAsStringSync('${rows.join('\n')}\n');

    expect(fired, greaterThanOrEqualTo(8));
  });
}
