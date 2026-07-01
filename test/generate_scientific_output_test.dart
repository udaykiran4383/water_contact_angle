import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:water_contact_angle/image_processor.dart';

String _csvCell(dynamic value) {
  final text = (value ?? '').toString();
  final escaped = text.replaceAll('"', '""');
  return '"$escaped"';
}

String _fmt(dynamic value, {int digits = 6}) {
  if (value is num) {
    final d = value.toDouble();
    if (d.isFinite) return d.toStringAsFixed(digits);
  }
  return '';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('generate scientific output csv from PFOTES', timeout: const Timeout(Duration(minutes: 5)), () async {
    final inputDir = Directory('/Users/uday/btp/water_contact_angle/PFOTES');
    final outputFile =
        File('/Users/uday/btp/water_contact_angle/scentific_output_current.csv');

    expect(inputDir.existsSync(), isTrue);

    final files = inputDir
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => RegExp(r'\.(jpg|jpeg|png)$', caseSensitive: false)
            .hasMatch(f.path))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));

    final rows = <String>[];
    rows.add([
      'filename',
      'relative_path',
      'status',
      'angle_deg',
      'left_deg',
      'right_deg',
      'uncertainty_deg',
      'surface_type',
      'baseline_tilt_deg',
      'baseline_confidence',
      'contact_confidence',
      'symmetry_score',
      'circle_deg',
      'ellipse_deg',
      'polynomial_deg',
      'young_laplace_deg',
      'r2_circle',
      'r2_ellipse',
      'r2_young_laplace',
      'method_weights',
      'method_quality',
      'message',
    ].map(_csvCell).join(','));

    int ok = 0;
    int fail = 0;

    for (final f in files) {
      final r = await ImageProcessor.processImage(f);
      final text = (r['text'] ?? '').toString();
      final angle = (r['angle_numeric'] as num?)?.toDouble();
      final isOk = angle != null && angle.isFinite && !text.startsWith('❌');
      if (isOk) {
        ok++;
      } else {
        fail++;
      }

      final relPath = f.path.startsWith('${inputDir.path}/')
          ? f.path.substring(inputDir.path.length + 1)
          : f.path;
      final methodWeights = (r['method_weights'] ?? '').toString();
      final methodQuality = (r['method_quality'] ?? '').toString();

      rows.add([
        f.uri.pathSegments.isNotEmpty ? f.uri.pathSegments.last : f.path,
        relPath,
        isOk ? 'OK' : 'FAIL',
        _fmt(r['angle_numeric']),
        _fmt(r['angle_left']),
        _fmt(r['angle_right']),
        _fmt(r['uncertainty_numeric']),
        (r['surface_type'] ?? '').toString(),
        _fmt(r['baseline_tilt']),
        _fmt(r['baseline_confidence']),
        _fmt(r['contact_confidence']),
        _fmt(r['symmetry_score']),
        _fmt(r['theta_circle']),
        _fmt(r['theta_ellipse']),
        _fmt(r['theta_poly']),
        _fmt(r['theta_young_laplace']),
        _fmt(r['r_squared_circle']),
        _fmt(r['r_squared_ellipse']),
        _fmt(r['r_squared_young_laplace']),
        methodWeights,
        methodQuality,
        text.replaceAll('\n', ' | '),
      ].map(_csvCell).join(','));
    }

    final summary = '# summary: total=${files.length}, ok=$ok, fail=$fail';
    rows.add(_csvCell(summary));
    await outputFile.writeAsString('${rows.join('\n')}\n');

    expect(outputFile.existsSync(), isTrue);
    expect(rows.length, greaterThan(2));
  });
}
