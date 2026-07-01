import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:water_contact_angle/image_processor.dart';

/// Renders the annotated overlay (drop outline, baseline, contact points,
/// tangents + angle text) for every PFOTES drop into pfotes_annotated/, for
/// visual inspection of each fit.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const root = '/Users/uday/btp/water_contact_angle';

  test('generate annotated overlays for all PFOTES drops',
      timeout: const Timeout(Duration(minutes: 6)), () async {
    // Write OUTSIDE PFOTES/ so the recursive dataset scans in the batch tests
    // don't pick these overlays up as unlabelled inputs.
    final outDir = Directory('$root/pfotes_annotated');
    outDir.createSync(recursive: true);

    // The 12 drops (matches PFOTES/ground_truth.csv order).
    final names = [
      'C_1.5%_1 coat_5a',
      'C_1.5%_1 coat_5b',
      'C_1.5%_1 coat_6',
      'C_1.5%_2 coat_5',
      'C_1.5%_2 coat_6',
      'C_3%_1 coat_5',
      'C_3%_1 coat_6a',
      'C_3%_1 coat_6b',
      'C_3%_2 coat_5a',
      'C_3%_2 coat_5b',
      'C_3%_2 coat_6a',
      'C_3%_2 coat_6b',
    ];

    final log = <String>['filename,angle_deg,left_deg,right_deg,uncertainty_deg,annotated'];
    int ok = 0;
    for (final name in names) {
      File? src;
      for (final ext in ['JPG', 'jpg', 'jpeg', 'JPEG']) {
        final cand = File('$root/PFOTES/$name.$ext');
        if (cand.existsSync()) {
          src = cand;
          break;
        }
      }
      expect(src, isNotNull, reason: 'missing image for $name');

      final r = await ImageProcessor.processImage(src!);
      final angle = (r['angle_numeric'] as num?)?.toDouble();
      final left = (r['angle_left'] as num?)?.toDouble();
      final right = (r['angle_right'] as num?)?.toDouble();
      final unc = (r['uncertainty'] as num?)?.toDouble();
      final ann = r['annotated'];

      String outName = '$name.png';
      bool saved = false;
      if (ann is File && ann.existsSync()) {
        ann.copySync('${outDir.path}/$outName');
        saved = true;
        ok++;
      }
      String f(double? v) => v != null && v.isFinite ? v.toStringAsFixed(2) : '-';
      log.add('$name,${f(angle)},${f(left)},${f(right)},${f(unc)},'
          '${saved ? "pfotes_annotated/$outName" : "FAILED"}');
      // ignore: avoid_print
      print('$name -> angle=${f(angle)} (L=${f(left)} R=${f(right)}) '
          '${saved ? "saved" : "NO ANNOTATED"}');
    }

    File('$root/pfotes_annotated/index.csv')
        .writeAsStringSync('${log.join('\n')}\n');
    expect(ok, names.length, reason: 'not every drop produced an overlay');
  });
}
