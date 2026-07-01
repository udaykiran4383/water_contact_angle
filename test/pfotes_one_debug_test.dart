import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:water_contact_angle/image_processor.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('one PFOTES file debug', () async {
    final f = File('/Users/uday/btp/water_contact_angle/PFOTES/C_3%_1 coat_6a.JPG');
    final r = await ImageProcessor.processImage(f);
    final keys = r.keys.toList()..sort();
    for (final k in keys) {
      if (k == 'annotated') continue;
      // ignore: avoid_print
      print('$k: ${r[k]}');
    }
  });
}
