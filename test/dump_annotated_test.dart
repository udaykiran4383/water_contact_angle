import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:water_contact_angle/image_processor.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('dump annotated image for shot2', () async {
    final f = File('/tmp/shot2.jpg');
    if (!f.existsSync()) return;
    final r = await ImageProcessor.processImage(f);
    // ignore: avoid_print
    print('ANGLE=${r['angle_numeric']} L=${r['angle_left']} R=${r['angle_right']} '
        'path=${r['annotated_path']}');
    final ann = r['annotated'];
    if (ann is File && ann.existsSync()) {
      ann.copySync('/tmp/annotated.png');
      // ignore: avoid_print
      print('COPIED to /tmp/annotated.png');
    }
  });
}
