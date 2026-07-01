import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:water_contact_angle/image_processor.dart';

List<String> _parseCsvLine(String line) {
  final out = <String>[];
  final sb = StringBuffer();
  bool inQuotes = false;
  for (int i = 0; i < line.length; i++) {
    final ch = line[i];
    if (ch == '"') {
      if (inQuotes && i + 1 < line.length && line[i + 1] == '"') {
        sb.write('"');
        i++;
      } else {
        inQuotes = !inQuotes;
      }
    } else if (ch == ',' && !inQuotes) {
      out.add(sb.toString());
      sb.clear();
    } else {
      sb.write(ch);
    }
  }
  out.add(sb.toString());
  return out;
}

double? _toDouble(String? s) {
  if (s == null) return null;
  final t = s.trim();
  if (t.isEmpty) return null;
  return double.tryParse(t);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('compare current output vs verified scentific_output.csv', timeout: const Timeout(Duration(minutes: 5)), () async {
    final inputDir = Directory('/Users/uday/btp/water_contact_angle/PFOTES');
    final verifiedFile =
        File('/Users/uday/btp/water_contact_angle/scentific_output.csv');
    final reportFile =
        File('/Users/uday/btp/water_contact_angle/comparison_report_latest.csv');

    expect(inputDir.existsSync(), isTrue);
    expect(verifiedFile.existsSync(), isTrue);

    final lines = verifiedFile.readAsLinesSync();
    expect(lines.length, greaterThan(2));
    final header = _parseCsvLine(lines.first);
    final relIdx = header.indexOf('relative_path');
    final angleIdx = header.indexOf('angle_deg');
    expect(relIdx, greaterThanOrEqualTo(0));
    expect(angleIdx, greaterThanOrEqualTo(0));

    final verifiedAngles = <String, double>{};
    for (final line in lines.skip(1)) {
      if (line.trim().isEmpty) continue;
      final cols = _parseCsvLine(line);
      if (cols.isEmpty) continue;
      if (cols.first.startsWith('# summary:')) continue;
      if (cols.length <= math.max(relIdx, angleIdx)) continue;
      final rel = cols[relIdx];
      final angle = _toDouble(cols[angleIdx]);
      if (rel.isNotEmpty && angle != null && angle.isFinite) {
        verifiedAngles[rel] = angle;
      }
    }
    expect(verifiedAngles.isNotEmpty, isTrue);

    final files = inputDir
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => RegExp(r'\.(jpg|jpeg|png)$', caseSensitive: false)
            .hasMatch(f.path))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));

    double mae = 0.0;
    double maxErr = 0.0;
    int n = 0;
    int missing = 0;

    final reportLines = <String>[
      '"relative_path","verified_angle_deg","current_angle_deg","abs_error_deg","status"'
    ];

    for (final f in files) {
      final rel = f.path.startsWith('${inputDir.path}/')
          ? f.path.substring(inputDir.path.length + 1)
          : f.path;
      final v = verifiedAngles[rel];
      if (v == null) {
        missing++;
        reportLines.add('"$rel","","","","MISSING_IN_VERIFIED"');
        continue;
      }
      final r = await ImageProcessor.processImage(f);
      final current = (r['angle_numeric'] as num?)?.toDouble();
      if (current == null || !current.isFinite) {
        missing++;
        reportLines.add('"$rel","${v.toStringAsFixed(6)}","","","NO_CURRENT_OUTPUT"');
        continue;
      }
      final err = (current - v).abs();
      mae += err;
      n++;
      if (err > maxErr) maxErr = err;
      reportLines.add(
        '"$rel","${v.toStringAsFixed(6)}","${current.toStringAsFixed(6)}","${err.toStringAsFixed(6)}","OK"',
      );
    }

    if (n > 0) {
      mae /= n;
    }
    reportLines.add('"# summary: matched=$n, missing=$missing, mae=$mae, max_err=$maxErr"');
    await reportFile.writeAsString('${reportLines.join('\n')}\n');

    // Keep strict so regressions are caught quickly.
    expect(missing, 0);
    expect(mae, lessThanOrEqualTo(2.0));
    expect(maxErr, lessThanOrEqualTo(7.0));
  });
}
