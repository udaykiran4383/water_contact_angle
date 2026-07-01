import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:water_contact_angle/image_processor.dart';

/// External-dataset validation against the DropletLab CC-BY contact-angle
/// dataset (dropletlab.com/dataset). These are REAL phone-style side-view drops
/// on Glass/Nylon/PMMA/Teflon with a dispensing needle in the drop and a
/// reflective substrate — a much harder, independent test than our 12 PFOTES
/// images. Ground-truth angles are burned into each image; we transcribe the
/// per-image mean into datasets/dropletlab/labels.csv (filename,true_mean).
///
/// The harness skips gracefully if the dataset isn't downloaded, so it never
/// fails on a machine without the data. Download with:
///   curl -sL https://dropletlab.com/wp-content/uploads/2026/02/Teflon-Dataset.zip -o t.zip
///   unzip t.zip -d datasets/dropletlab/
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const root = '/Users/uday/btp/water_contact_angle';
  final dir = Directory('$root/datasets/dropletlab');

  test('DropletLab external dataset accuracy',
      timeout: const Timeout(Duration(minutes: 15)), () async {
    if (!dir.existsSync()) {
      // ignore: avoid_print
      print('DropletLab dataset not present — skipping. See test header.');
      return;
    }

    // Optional ground-truth labels: filename (basename), true_mean_deg.
    final labels = <String, double>{};
    final labelFile = File('${dir.path}/labels.csv');
    if (labelFile.existsSync()) {
      for (final line in labelFile.readAsLinesSync().skip(1)) {
        if (line.trim().isEmpty || line.startsWith('#')) continue;
        final c = line.split(',');
        if (c.length >= 2) {
          final v = double.tryParse(c[1].trim());
          if (v != null) labels[c[0].trim()] = v;
        }
      }
    }

    final images = dir
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.toLowerCase().endsWith('.png'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));

    final rows = <String>['substrate,liquid,file,measured,left,right,true,error'];
    // Per-liquid error accumulation (labelled images only).
    final perGroup = <String, List<double>>{};
    int measured = 0, failed = 0;
    final allErrs = <double>[];

    for (final f in images) {
      final parts = f.path.split('/');
      final base = parts.last;
      final liquid = parts.length >= 2 ? parts[parts.length - 2] : '?';
      final substrate = parts.length >= 3 ? parts[parts.length - 3] : '?';

      double? m, l, r;
      try {
        final res = await ImageProcessor.processImage(f);
        m = (res['angle_numeric'] as num?)?.toDouble();
        l = (res['angle_left'] as num?)?.toDouble();
        r = (res['angle_right'] as num?)?.toDouble();
      } catch (_) {}
      if (m != null && m.isFinite) {
        measured++;
      } else {
        failed++;
      }

      final t = labels[base];
      double err = double.nan;
      if (t != null && m != null && m.isFinite) {
        err = (m - t).abs();
        allErrs.add(err);
        (perGroup['$substrate/$liquid'] ??= []).add(err);
      }
      String s(double? v) => v != null && v.isFinite ? v.toStringAsFixed(2) : '-';
      rows.add('$substrate,$liquid,$base,${s(m)},${s(l)},${s(r)},'
          '${t != null ? t.toStringAsFixed(2) : '-'},'
          '${err.isFinite ? err.toStringAsFixed(2) : '-'}');
    }

    // Summary lines.
    rows.add('# measured=$measured/${images.length}, failed=$failed');
    for (final e in perGroup.entries) {
      final list = e.value..sort();
      final mae = list.reduce((a, b) => a + b) / list.length;
      final med = list[list.length ~/ 2];
      rows.add('# ${e.key}: n=${list.length} MAE=${mae.toStringAsFixed(2)} '
          'median=${med.toStringAsFixed(2)} max=${list.last.toStringAsFixed(2)}');
    }
    if (allErrs.isNotEmpty) {
      final mae = allErrs.reduce((a, b) => a + b) / allErrs.length;
      rows.add('# OVERALL labelled MAE=${mae.toStringAsFixed(2)} '
          'n=${allErrs.length}');
    }

    File('${dir.path}/results.csv').writeAsStringSync('${rows.join('\n')}\n');
    // ignore: avoid_print
    print(rows.join('\n'));

    // The pipeline should at least PRODUCE an angle for most real images.
    expect(measured, greaterThan((images.length * 0.6).floor()),
        reason: 'pipeline failed to measure too many dataset images');
  });
}
