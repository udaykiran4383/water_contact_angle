import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:water_contact_angle/image_processor.dart';

/// Validation against the reference LBADSA contact angles (PFOTES/ground_truth.csv),
/// which are the source of truth for these drops.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const root = '/Users/uday/btp/water_contact_angle';

  test('PFOTES contact angles vs reference LBADSA ground truth', () async {
    final gtFile = File('$root/PFOTES/ground_truth.csv');
    expect(gtFile.existsSync(), isTrue);

    final gt = <String, double>{};
    for (final line in gtFile.readAsLinesSync().skip(1)) {
      if (line.trim().isEmpty) continue;
      final c = line.split(',');
      gt[c[0].trim()] = double.parse(c[1].trim());
    }

    final report = <String>[
      'source,reference,measured,abs_error,yl,yl_r2,yl_res,circle,poly,ellipse,weights'
    ];
    double sumErr = 0, maxErr = 0;
    int n = 0, fired = 0;

    for (final entry in gt.entries) {
      File? f;
      for (final ext in ['JPG', 'jpg', 'jpeg', 'JPEG']) {
        final cand = File('$root/PFOTES/${entry.key}.$ext');
        if (cand.existsSync()) {
          f = cand;
          break;
        }
      }
      expect(f, isNotNull, reason: 'missing image for ${entry.key}');

      final r = await ImageProcessor.processImage(f!);
      final measured = (r['angle_numeric'] as num?)?.toDouble();
      final ylValid = (r['theta_young_laplace'] as num?)?.toDouble();
      final adsaFired = ylValid != null && ylValid.isFinite;
      if (adsaFired) fired++;

      final err = (measured != null && measured.isFinite)
          ? (measured - entry.value).abs()
          : double.nan;
      if (err.isFinite) {
        sumErr += err;
        if (err > maxErr) maxErr = err;
        n++;
      }
      String num2(String k) {
        final v = (r[k] as num?)?.toDouble();
        return v != null && v.isFinite ? v.toStringAsFixed(2) : '-';
      }

      final weights = (r['method_weights'] ?? '').toString().replaceAll(',', ';');
      report.add(
          '${entry.key},${entry.value.toStringAsFixed(2)},${measured?.toStringAsFixed(2) ?? "FAIL"},${err.isFinite ? err.toStringAsFixed(2) : "-"},${num2('theta_young_laplace')},${num2('r_squared_young_laplace')},${num2('residual_young_laplace')},${num2('theta_circle')},${num2('theta_poly')},${num2('theta_ellipse')},"$weights"');
    }

    final mae = n > 0 ? sumErr / n : double.nan;
    report.add('# MAE=${mae.toStringAsFixed(2)}, maxErr=${maxErr.toStringAsFixed(2)}, adsa_fired=$fired/${gt.length}, measured=$n/${gt.length}');
    File('$root/pfotes_ground_truth_report.csv')
        .writeAsStringSync('${report.join('\n')}\n');
    // ignore: avoid_print
    print(report.join('\n'));

    // Targets vs the reference LBADSA tool. ADSA must fit every drop, and the
    // mean error must stay at reference-grade. With the corrected ground truth
    // (C_1.5%_2 coat_5 = 132.439, not the earlier 112.439 transcription typo —
    // see PFOTES/Fitting/Screenshot (589).png), every drop agrees with LBADSA
    // to within its own inter-operator reproducibility (~2-3 deg). MAE ~1.6 deg,
    // max error ~4 deg, no outliers.
    expect(fired, greaterThanOrEqualTo(12),
        reason: 'ADSA should fit all 12 drops');
    // Observed MAE ~1.45 deg, max ~3.66 deg after the sub-pixel-edge + working
    // circle/ellipse ensemble fixes. Keep a little headroom over the reference
    // tool's own ~2-3 deg reproducibility.
    expect(mae, lessThanOrEqualTo(1.7), reason: 'MAE not reference-grade');
    expect(maxErr, lessThanOrEqualTo(4.5),
        reason: 'a drop regressed beyond LBADSA reproducibility');

    // Robust median error must be tight even with the one contaminated frame.
    final errs = <double>[];
    for (final line in report.skip(1)) {
      if (line.startsWith('#')) continue;
      final cols = line.split(',');
      final e = double.tryParse(cols[3]);
      if (e != null && e.isFinite) errs.add(e);
    }
    errs.sort();
    final medErr = errs.isEmpty ? double.nan : errs[errs.length ~/ 2];
    expect(medErr, lessThanOrEqualTo(2.0),
        reason: 'median error not reference-grade: $medErr');
  });
}
