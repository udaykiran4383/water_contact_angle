import 'dart:io';

void main() {
  final src = File('lib/image_processor.dart').readAsStringSync();
  final out = src.replaceAll(
    "import 'package:flutter/foundation.dart';",
    "// Headless execution: No Flutter imports"
  ).replaceAll(
    "import 'package:flutter/widgets.dart';",
    "// Headless execution: No Flutter widgets"
  ).replaceAll(
    "class ImageProcessor {",
    "class HeadlessImageProcessor {"
  ).replaceAll(
    "import 'package:image/image.dart' as imglib;",
    "import 'package:image/image.dart' as imglib;\nimport 'dart:typed_data';"
  );
  File('test_scripts/headless_image_processor.dart').writeAsStringSync(out);
  print('Headless processor generated.');
}
