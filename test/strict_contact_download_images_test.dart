import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:water_contact_angle/image_processor.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('strict contact outputs on provided download images', () async {
    final paths = <String>[
      '/Users/uday/Downloads/WhatsApp Image 2026-04-23 at 15.10.21.jpeg',
      '/Users/uday/Downloads/WhatsApp Image 2026-04-23 at 15.10.21-2.jpeg',
    ];

    // These are ad-hoc probe images from a personal Downloads folder; skip
    // gracefully on any machine that doesn't have them rather than failing.
    if (!paths.every((p) => File(p).existsSync())) {
      // ignore: avoid_print
      print('skipping: download probe images not present on this machine');
      return;
    }

    for (final p in paths) {
      final f = File(p);
      expect(f.existsSync(), isTrue, reason: 'Missing image: $p');
      final r = await ImageProcessor.processImage(f);
      // ignore: avoid_print
      print(
        '${f.path.split('/').last} | angle=${r['angle_numeric']} '
        '| left=${r['contact_x_left_aligned']}, right=${r['contact_x_right_aligned']} '
        '| y=${r['contact_y_surface_aligned']} '
        '| slopeL=${r['contact_slope_left']} slopeR=${r['contact_slope_right']} '
        '| baseline=${r['baseline_tilt']} conf=${r['contact_confidence']} '
        '| text=${(r['text'] ?? '').toString().split('\n').first}',
      );
    }
  });
}
