import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:water_contact_angle/image_processor.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('batch PFOTES debug pass/fail report', timeout: const Timeout(Duration(minutes: 5)), () async {
    final dir = Directory('/Users/uday/btp/water_contact_angle/PFOTES');
    expect(dir.existsSync(), isTrue);

    final files = dir
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => RegExp(r'\.(jpg|jpeg|png)$', caseSensitive: false)
            .hasMatch(f.path))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));

    int ok = 0;
    int fail = 0;

    for (final f in files) {
      final r = await ImageProcessor.processImage(f);
      final text = (r['text'] ?? '').toString();
      final angle = (r['angle_numeric'] as num?)?.toDouble();
      final methodQuality = r['method_quality'];

      final isFail = text.startsWith('❌') || angle == null || !angle.isFinite;
      if (isFail) {
        fail++;
      } else {
        ok++;
      }

      // ignore: avoid_print
      print(
        '${isFail ? 'FAIL' : 'OK  '} | ${f.path.split('/').last} | '
        'angle=${angle?.toStringAsFixed(2)} | '
        'baseline=${r['baseline_confidence']} | contact=${r['contact_confidence']} | '
        'drop=${r['drop_contour_aligned_count']} raw=${r['contour_aligned_count']} | '
        'cL=${r['contact_left_x_aligned']} cR=${r['contact_right_x_aligned']} apex=${r['contact_apex_x_aligned']} | '
        'reason=$text | quality=$methodQuality',
      );
    }

    // ignore: avoid_print
    print('PFOTES SUMMARY: total=${files.length}, ok=$ok, fail=$fail');
  });
}
