// ignore_for_file: avoid_print, prefer_const_declarations

import 'dart:convert';
import 'dart:io';

import 'package:water_contact_angle/processing/angle_calibration.dart';

import 'headless_image_processor.dart';

void main(List<String> args) async {
  // Define paths relative to project root (assuming run from root)
  // If run from test_scripts/, we might need to adjust, but let's assume root execution.
  final csvPath = 'PFOTES 2/output.csv';
  final imagesDirPath = 'PFOTES 2';

  final csvFile = File(csvPath);
  if (!await csvFile.exists()) {
    print('Error: Reference file not found: $csvPath');
    print('Please run this script from the project root directory.');
    return;
  }

  final lines = await csvFile.readAsLines();
  final referenceData = <String, double>{};

  // Skip header
  for (var i = 1; i < lines.length; i++) {
    final parts = lines[i].split(',');
    if (parts.length >= 2) {
      final filename = parts[0].trim();
      final angleStr = parts[1].trim();
      final angle = double.tryParse(angleStr);
      if (angle != null) {
        referenceData[filename] = angle;
      }
    }
  }

  // Helper to normalize filenames for matching
  String normalize(String s) {
    return s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
  }

  final normalizedRefData = <String, String>{};
  for (var key in referenceData.keys) {
    normalizedRefData[normalize(key)] = key;
  }

  final bool disableCalibration = args.contains('--no-calibration');
  final int calibArgIdx = args.indexOf('--calibration');
  String calibrationPath = 'calibration/angle_calibration_profile.json';
  if (calibArgIdx >= 0 && calibArgIdx + 1 < args.length) {
    calibrationPath = args[calibArgIdx + 1];
  }
  AngleCalibrationProfile? angleCalibration;
  if (!disableCalibration) {
    final calibFile = File(calibrationPath);
    if (await calibFile.exists()) {
      try {
        final jsonMap =
            jsonDecode(await calibFile.readAsString()) as Map<String, dynamic>;
        angleCalibration = AngleCalibrationProfile.fromJson(jsonMap);
        print('Loaded angle calibration profile: $calibrationPath');
        print('  slope=${angleCalibration.slope.toStringAsFixed(6)} '
            'intercept=${angleCalibration.intercept.toStringAsFixed(6)} '
            'source=${angleCalibration.source}');
      } catch (e) {
        print('Warning: failed to load calibration profile: $e');
      }
    } else if (calibArgIdx >= 0) {
      print('Warning: calibration file not found: $calibrationPath');
    }
  }

  print('Loaded ${referenceData.length} reference measurements from CSV.');

  // 2. Process images
  final imageDir = Directory(imagesDirPath);
  if (!await imageDir.exists()) {
    print('Error: Image directory not found: $imagesDirPath');
    return;
  }

  final results = <Map<String, dynamic>>[];
  final images = await imageDir.list().toList();
  // Sort for consistent order
  images.sort((a, b) => a.path.compareTo(b.path));

  int processedCount = 0;
  double totalDiff = 0.0;
  double maxDiff = 0.0;

  print('\nStarting batch processing...');
  print('----------------------------------------------------------------');
  print(
      '${'Filename'.padRight(25)} | ${'Ref (°)'} | ${'Meas (°)'} | ${'Diff (°)'} | ${'Unc (°)'}');
  print('----------------------------------------------------------------');

  for (var entity in images) {
    if (entity is File) {
      final lowerPath = entity.path.toLowerCase();
      if (lowerPath.endsWith('.jpg') ||
          lowerPath.endsWith('.jpeg') ||
          lowerPath.endsWith('.png')) {
        final filename = entity.uri.pathSegments.last;
        final normFilename = normalize(filename);

        // Only process if we have a reference value
        if (!normalizedRefData.containsKey(normFilename)) {
          // print('Skipping $filename (no match for $normFilename)');
          continue;
        }

        final refKey = normalizedRefData[normFilename]!;

        try {
          final result = await HeadlessImageProcessor.processImage(
            entity,
            angleCalibration: angleCalibration,
          );

          final measuredAngle =
              (result['angle'] as num?)?.toDouble() ?? double.nan;
          final uncertainty =
              (result['uncertainty'] as num?)?.toDouble() ?? 0.0;

          if (measuredAngle.isNaN) {
            print(
                '${filename.padRight(25)} | ${referenceData[refKey]!.toStringAsFixed(1).padLeft(7)} | ${'NaN'.padLeft(8)} | ${'-'.padLeft(8)} | -');
            continue;
          }

          final referenceAngle = referenceData[refKey]!;
          final diff = (measuredAngle - referenceAngle).abs();

          totalDiff += diff;
          if (diff > maxDiff) maxDiff = diff;
          processedCount++;

          results.add({
            'filename': filename,
            'reference': referenceAngle,
            'measured': measuredAngle,
            'diff': diff,
            'uncertainty': uncertainty,
            'details': result
          });

          print(
              '${filename.padRight(25)} | ${referenceAngle.toStringAsFixed(1).padLeft(7)} | ${measuredAngle.toStringAsFixed(1).padLeft(8)} | ${diff.toStringAsFixed(1).padLeft(8)} | ${uncertainty.toStringAsFixed(1).padLeft(7)}');
        } catch (e) {
          print('Error processing $filename: $e');
        }
      }
    }
  }

  // 3. Generate Report
  if (processedCount > 0) {
    final avgDiff = totalDiff / processedCount;
    print('----------------------------------------------------------------');
    print('Summary:');
    print('  Images Processed: $processedCount');
    print('  Average Abs Diff: ${avgDiff.toStringAsFixed(2)}°');
    print('  Max Diff:         ${maxDiff.toStringAsFixed(2)}°');

    final reportFile = File('comparison_report.csv');
    final sink = reportFile.openWrite();
    sink.writeln(
        'Filename,Reference_Angle,Measured_Angle,Difference,Uncertainty');
    for (var r in results) {
      sink.writeln(
          '${r['filename']},${r['reference']},${r['measured']},${r['diff']},${r['uncertainty']}');
    }
    await sink.close();
    print('\nDetailed report saved to: ${reportFile.absolute.path}');
  } else {
    print('\nNo matching images processed.');
  }
}
