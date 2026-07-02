import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:water_contact_angle/image_processor.dart';

/// Scratch diagnostic: process single hard DropletLab images and dump the
/// baseline/geometry diagnostics the batch test hides. Skips if absent.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('debug single dropletlab images', timeout: const Timeout(Duration(minutes: 5)),
      () async {
    const root = '/Users/uday/btp/water_contact_angle/datasets/dropletlab/Teflon';
    final targets = [
      '$root/Glycerol/glycerol teflone-9.png',
    ];
    for (final path in targets) {
      final f = File(path);
      if (!f.existsSync()) {
        // ignore: avoid_print
        print('SKIP $path');
        continue;
      }
      final r = await ImageProcessor.processImage(f);
      // ignore: avoid_print
      print('--- ${path.split('/').last}');
      for (final k in [
        'annotated_path',
        'angle_numeric',
        'angle_left',
        'angle_right',
        'baseline_y',
        'baseline_tilt',
        'baseline_source',
        'baseline_method',
        'baseline_confidence',
        'contact_y_surface_left',
        'contact_y_surface_right',
        'drop_radius_px',
        'contour_count',
        'theta_circle',
        'theta_young_laplace',
        'theta_poly',
        'theta_ellipse',
      ]) {
        // ignore: avoid_print
        print('  $k = ${r[k]}');
      }
    }
  });
}
