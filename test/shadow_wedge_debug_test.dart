import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:water_contact_angle/image_processor.dart';

/// Diagnostic: run the pipeline on the user's rig capture showing the
/// contact-shadow wedge (Case A/B sketch) and dump baseline diagnostics.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('shadow wedge rig image', timeout: const Timeout(Duration(minutes: 5)),
      () async {
    const path =
        '/Users/uday/btp/water_contact_angle/WhatsApp Image 2026-07-01 at 21.17.28.jpeg';
    final f = File(path);
    if (!f.existsSync()) {
      // ignore: avoid_print
      print('SKIP');
      return;
    }
    final r = await ImageProcessor.processImage(f);
    for (final k in [
      'annotated_path',
      'angle_numeric',
      'angle_left',
      'angle_right',
      'uncertainty_numeric',
      'baseline_y',
      'baseline_tilt',
      'baseline_method',
      'contact_x_left',
      'contact_x_right',
      'contact_y_surface_left',
      'drop_radius_px',
      'theta_circle',
      'theta_young_laplace',
      'theta_poly',
      'theta_ellipse',
      'quality_flags',
    ]) {
      // ignore: avoid_print
      print('  $k = ${r[k]}');
    }
  });
}
