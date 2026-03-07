// ignore_for_file: avoid_print, prefer_const_declarations

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:water_contact_angle/processing/angle_calibration.dart';

import 'headless_image_processor.dart';

class _Sample {
  final String filename;
  final double reference;
  final double raw;

  const _Sample({
    required this.filename,
    required this.reference,
    required this.raw,
  });
}

void main(List<String> args) async {
  final csvPath = _argValue(args, '--csv') ?? 'PFOTES 2/output.csv';
  final imagesDirPath = _argValue(args, '--images') ?? 'PFOTES 2';
  final outPath =
      _argValue(args, '--out') ?? 'calibration/angle_calibration_profile.json';

  final csvFile = File(csvPath);
  if (!await csvFile.exists()) {
    print('Error: reference CSV not found: $csvPath');
    exitCode = 1;
    return;
  }

  final imageDir = Directory(imagesDirPath);
  if (!await imageDir.exists()) {
    print('Error: image directory not found: $imagesDirPath');
    exitCode = 1;
    return;
  }

  final references = await _loadReferences(csvFile);
  if (references.isEmpty) {
    print('Error: no valid reference rows in $csvPath');
    exitCode = 1;
    return;
  }
  print('Loaded ${references.length} reference measurements.');

  String normalize(String s) =>
      s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
  final normalizedRef = <String, String>{};
  for (final k in references.keys) {
    normalizedRef[normalize(k)] = k;
  }

  final entities = await imageDir.list().toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  final samples = <_Sample>[];
  for (final entity in entities) {
    if (entity is! File) continue;
    final lower = entity.path.toLowerCase();
    if (!(lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.png'))) {
      continue;
    }
    final filename = entity.uri.pathSegments.last;
    final norm = normalize(filename);
    final refKey = normalizedRef[norm];
    if (refKey == null) continue;

    print('  Processing $filename ...');
    final result = await HeadlessImageProcessor.processImage(entity);
    final raw = (result['angle'] as num?)?.toDouble() ?? double.nan;
    if (!raw.isFinite) {
      print('    ⚠ skipped (NaN result)');
      continue;
    }

    samples.add(
      _Sample(
        filename: filename,
        reference: references[refKey]!,
        raw: raw,
      ),
    );
    print(
        '    raw=${raw.toStringAsFixed(2)}° ref=${references[refKey]!.toStringAsFixed(2)}° err=${(raw - references[refKey]!).abs().toStringAsFixed(2)}°');
  }

  if (samples.length < 4) {
    print('Error: not enough samples for calibration (${samples.length}).');
    exitCode = 1;
    return;
  }

  final rawAngles = samples.map((s) => s.raw).toList();
  final refAngles = samples.map((s) => s.reference).toList();

  // ── Compute raw baseline error ──
  final maeBefore = _mae(rawAngles, refAngles);
  print('\n══════════════════════════════════════');
  print('  RAW (uncalibrated) MAE: ${maeBefore.toStringAsFixed(3)}°');
  print('══════════════════════════════════════');

  // ── 1. Affine model ──
  final affineFit = _fitRobustAffine(rawAngles, refAngles);
  final affineSlope = affineFit['slope']!;
  final affineIntercept = affineFit['intercept']!;
  final absRawErr = samples.map((s) => (s.raw - s.reference).abs()).toList();
  final p90Err = _percentile(absRawErr, 90.0);
  final maxCorrectionDeg = (p90Err * 1.5).clamp(8.0, 30.0).toDouble();

  final affineCorrected = <double>[];
  for (final s in samples) {
    affineCorrected.add(_applyBoundedAffine(
      s.raw,
      slope: affineSlope,
      intercept: affineIntercept,
      maxCorrectionDeg: maxCorrectionDeg,
    ));
  }
  final maeAffine = _mae(affineCorrected, refAngles);
  final loocvAffine = _loocvMaeAffine(samples, maxCorrectionDeg);

  print('\n── Affine model ──');
  print('  slope=${affineSlope.toStringAsFixed(6)}');
  print('  intercept=${affineIntercept.toStringAsFixed(6)}');
  print('  MAE after=${maeAffine.toStringAsFixed(3)}°');
  print('  LOOCV MAE=${loocvAffine.toStringAsFixed(3)}°');

  // ── 2. Piecewise-linear model ──
  final pw = _buildPiecewiseLinear(samples, maxCorrectionDeg);
  final pwKnots = pw['knots'] as List<double>;
  final pwValues = pw['values'] as List<double>;

  final pwCorrected = <double>[];
  for (final s in samples) {
    pwCorrected.add(_applyPiecewise(s.raw, pwKnots, pwValues, maxCorrectionDeg));
  }
  final maePw = _mae(pwCorrected, refAngles);
  final loocvPw = _loocvMaePiecewise(samples, maxCorrectionDeg);

  print('\n── Piecewise-linear model ──');
  print('  knots: ${pwKnots.map((k) => k.toStringAsFixed(2)).join(', ')}');
  print('  values: ${pwValues.map((v) => v.toStringAsFixed(2)).join(', ')}');
  print('  MAE after=${maePw.toStringAsFixed(3)}°');
  print('  LOOCV MAE=${loocvPw.toStringAsFixed(3)}°');

  // ── Choose best model ──
  final bool usePiecewise = loocvPw < loocvAffine;
  final chosenModel = usePiecewise ? 'piecewise_linear' : 'affine';
  final chosenMae = usePiecewise ? maePw : maeAffine;
  final chosenLoocv = usePiecewise ? loocvPw : loocvAffine;
  final chosenCorrected = usePiecewise ? pwCorrected : affineCorrected;

  print('\n══════════════════════════════════════');
  print('  CHOSEN MODEL: $chosenModel');
  print('  MAE: ${maeBefore.toStringAsFixed(3)}° → ${chosenMae.toStringAsFixed(3)}°');
  print('  LOOCV MAE: ${chosenLoocv.toStringAsFixed(3)}°');
  print('══════════════════════════════════════');

  // ── Per-sample residual diagnostics ──
  print('\n── Per-sample diagnostics ──');
  print('${'File'.padRight(28)} | ${'Raw'.padLeft(7)} | ${'Ref'.padLeft(7)} | ${'Corr'.padLeft(7)} | ${'Resid'.padLeft(7)}');
  print('─' * 72);
  final residuals = <double>[];
  for (int i = 0; i < samples.length; i++) {
    final s = samples[i];
    final corr = chosenCorrected[i];
    final resid = corr - s.reference;
    residuals.add(resid.abs());
    print(
        '${s.filename.padRight(28)} | ${s.raw.toStringAsFixed(2).padLeft(7)} | ${s.reference.toStringAsFixed(2).padLeft(7)} | ${corr.toStringAsFixed(2).padLeft(7)} | ${resid.toStringAsFixed(2).padLeft(7)}');
  }
  print('─' * 72);

  // ── Build profile and write ──
  final rmseAfter = _rmse(chosenCorrected, refAngles);
  final AngleCalibrationProfile profile;
  if (usePiecewise) {
    profile = AngleCalibrationProfile.piecewiseLinear(
      knots: pwKnots,
      values: pwValues,
      slope: affineSlope,
      intercept: affineIntercept,
      maxCorrectionDeg: maxCorrectionDeg,
      residualStdDeg: rmseAfter,
      source: 'rig_calibrated_piecewise',
    );
  } else {
    profile = AngleCalibrationProfile(
      slope: affineSlope,
      intercept: affineIntercept,
      maxCorrectionDeg: maxCorrectionDeg,
      residualStdDeg: rmseAfter,
      source: 'rig_calibrated_affine',
    );
  }

  final outFile = File(outPath);
  await outFile.parent.create(recursive: true);
  final payload = {
    ...profile.toJson(),
    'created_at': DateTime.now().toIso8601String(),
    'n_samples': samples.length,
    'source_csv': csvPath,
    'source_images': imagesDirPath,
    'mae_before_deg': maeBefore,
    'mae_after_deg': chosenMae,
    'mae_loocv_deg': chosenLoocv,
    'rmse_after_deg': rmseAfter,
    'model_comparison': {
      'affine_mae': maeAffine,
      'affine_loocv': loocvAffine,
      'piecewise_mae': maePw,
      'piecewise_loocv': loocvPw,
      'chosen': chosenModel,
    },
  };
  await outFile
      .writeAsString(const JsonEncoder.withIndent('  ').convert(payload));

  print('\nCalibration profile written: ${outFile.path}');
  print('\nUse with: dart run test_scripts/run_comparison.dart');
}

// ── Reference CSV loader ──

Future<Map<String, double>> _loadReferences(File csvFile) async {
  final lines = await csvFile.readAsLines();
  final refs = <String, double>{};
  for (int i = 1; i < lines.length; i++) {
    final parts = lines[i].split(',');
    if (parts.length < 2) continue;
    final filename = parts[0].trim();
    final angle = double.tryParse(parts[1].trim());
    if (filename.isNotEmpty && angle != null && angle.isFinite) {
      refs[filename] = angle;
    }
  }
  return refs;
}

String? _argValue(List<String> args, String key) {
  final idx = args.indexOf(key);
  if (idx < 0 || idx + 1 >= args.length) return null;
  return args[idx + 1];
}

// ── Affine fitting ──

Map<String, double> _fitRobustAffine(List<double> x, List<double> y) {
  if (x.isEmpty || y.isEmpty || x.length != y.length) {
    return {'slope': 1.0, 'intercept': 0.0};
  }

  var w = List<double>.filled(x.length, 1.0);
  var coeff = _fitWeightedAffine(x, y, w);
  for (int iter = 0; iter < 4; iter++) {
    final residuals = <double>[];
    for (int i = 0; i < x.length; i++) {
      residuals
          .add((coeff['slope']! * x[i] + coeff['intercept']! - y[i]).abs());
    }
    final scale = (_percentile(residuals, 70.0) + 1e-6).clamp(0.4, 8.0);
    for (int i = 0; i < x.length; i++) {
      final r = residuals[i];
      final t = r / scale;
      w[i] = t <= 1.0 ? 1.0 : 1.0 / t;
    }
    coeff = _fitWeightedAffine(x, y, w);
  }

  final slope = coeff['slope']!.clamp(0.6, 1.5);
  final intercept = coeff['intercept']!.clamp(-35.0, 35.0);
  return {'slope': slope, 'intercept': intercept};
}

Map<String, double> _fitWeightedAffine(
  List<double> x,
  List<double> y,
  List<double> w,
) {
  double sw = 0.0, sx = 0.0, sy = 0.0, sxx = 0.0, sxy = 0.0;
  for (int i = 0; i < x.length; i++) {
    final wi = w[i].isFinite ? w[i] : 0.0;
    if (wi <= 0) continue;
    sw += wi;
    sx += wi * x[i];
    sy += wi * y[i];
    sxx += wi * x[i] * x[i];
    sxy += wi * x[i] * y[i];
  }
  if (sw <= 1e-9) return {'slope': 1.0, 'intercept': 0.0};

  final denom = sw * sxx - sx * sx;
  if (denom.abs() < 1e-9) {
    return {'slope': 1.0, 'intercept': (sy / sw) - (sx / sw)};
  }
  final slope = (sw * sxy - sx * sy) / denom;
  final intercept = (sy - slope * sx) / sw;
  return {'slope': slope, 'intercept': intercept};
}

double _applyBoundedAffine(
  double raw, {
  required double slope,
  required double intercept,
  required double maxCorrectionDeg,
}) {
  final target = slope * raw + intercept;
  final delta = (target - raw).clamp(-maxCorrectionDeg, maxCorrectionDeg);
  final corrected = raw + delta;
  return corrected.clamp(0.0, 180.0).toDouble();
}

// ── Piecewise-linear building ──

Map<String, dynamic> _buildPiecewiseLinear(
    List<_Sample> samples, double maxCorrectionDeg) {
  // Sort by raw angle
  final sorted = List<_Sample>.from(samples)
    ..sort((a, b) => a.raw.compareTo(b.raw));

  // Group nearby raw angles (within 2°) and average
  final knots = <double>[];
  final values = <double>[];

  int i = 0;
  while (i < sorted.length) {
    double sumRaw = sorted[i].raw;
    double sumRef = sorted[i].reference;
    int count = 1;
    int j = i + 1;
    while (j < sorted.length && (sorted[j].raw - sorted[i].raw) < 2.0) {
      sumRaw += sorted[j].raw;
      sumRef += sorted[j].reference;
      count++;
      j++;
    }
    knots.add(sumRaw / count);
    values.add(sumRef / count);
    i = j;
  }

  // Add extrapolation guard knots ±15° beyond data range if we have ≥ 2 knots
  if (knots.length >= 2) {
    final firstSlope = (values[1] - values[0]) / (knots[1] - knots[0]);
    final lastSlope = (values.last - values[values.length - 2]) /
        (knots.last - knots[knots.length - 2]);

    // Clamp extrapolation slope to [0.5, 1.5] for safety
    final clampedFirstSlope = firstSlope.clamp(0.5, 1.5);
    final clampedLastSlope = lastSlope.clamp(0.5, 1.5);

    final extraLow = knots.first - 15.0;
    final extraHigh = knots.last + 15.0;

    knots.insert(0, extraLow);
    values.insert(0, values[1] + clampedFirstSlope * (extraLow - knots[1]));

    knots.add(extraHigh);
    values.add(
        values[values.length - 2] + clampedLastSlope * (extraHigh - knots[knots.length - 2]));
  }

  return {'knots': knots, 'values': values};
}

double _applyPiecewise(
    double raw, List<double> knots, List<double> values, double maxCorr) {
  if (raw <= knots.first) {
    final segSlope = (values[1] - values[0]) / (knots[1] - knots[0]);
    final target = values.first + segSlope * (raw - knots.first);
    return _boundedPw(raw, target, maxCorr);
  }
  if (raw >= knots.last) {
    final n = knots.length;
    final segSlope = (values[n - 1] - values[n - 2]) / (knots[n - 1] - knots[n - 2]);
    final target = values.last + segSlope * (raw - knots.last);
    return _boundedPw(raw, target, maxCorr);
  }
  for (int i = 0; i < knots.length - 1; i++) {
    if (raw >= knots[i] && raw <= knots[i + 1]) {
      final t = (raw - knots[i]) / (knots[i + 1] - knots[i]);
      final target = values[i] + t * (values[i + 1] - values[i]);
      return _boundedPw(raw, target, maxCorr);
    }
  }
  return raw; // fallback
}

double _boundedPw(double raw, double target, double maxCorr) {
  if (maxCorr > 0) {
    final delta = (target - raw).clamp(-maxCorr, maxCorr);
    return (raw + delta).clamp(0.0, 180.0).toDouble();
  }
  return target.clamp(0.0, 180.0).toDouble();
}

// ── Statistics ──

double _mae(List<double> pred, List<double> ref) {
  if (pred.isEmpty || ref.isEmpty || pred.length != ref.length) {
    return double.nan;
  }
  double sum = 0.0;
  for (int i = 0; i < pred.length; i++) {
    sum += (pred[i] - ref[i]).abs();
  }
  return sum / pred.length;
}

double _rmse(List<double> pred, List<double> ref) {
  if (pred.isEmpty || ref.isEmpty || pred.length != ref.length) {
    return double.nan;
  }
  double sumSq = 0.0;
  for (int i = 0; i < pred.length; i++) {
    final d = pred[i] - ref[i];
    sumSq += d * d;
  }
  return math.sqrt(sumSq / pred.length);
}

double _percentile(List<double> values, double p) {
  if (values.isEmpty) return 0.0;
  final sorted = List<double>.from(values)..sort();
  final pos = (p.clamp(0.0, 100.0) / 100.0) * (sorted.length - 1);
  final lo = pos.floor();
  final hi = pos.ceil();
  if (lo == hi) return sorted[lo];
  final t = pos - lo;
  return sorted[lo] * (1.0 - t) + sorted[hi] * t;
}

// ── LOOCV for affine model ──

double _loocvMaeAffine(List<_Sample> samples, double maxCorrectionDeg) {
  if (samples.length < 4) return double.nan;
  double sum = 0.0;
  for (int i = 0; i < samples.length; i++) {
    final trainRaw = <double>[];
    final trainRef = <double>[];
    for (int j = 0; j < samples.length; j++) {
      if (j == i) continue;
      trainRaw.add(samples[j].raw);
      trainRef.add(samples[j].reference);
    }
    final fit = _fitRobustAffine(trainRaw, trainRef);
    final pred = _applyBoundedAffine(
      samples[i].raw,
      slope: fit['slope']!,
      intercept: fit['intercept']!,
      maxCorrectionDeg: maxCorrectionDeg,
    );
    sum += (pred - samples[i].reference).abs();
  }
  return sum / samples.length;
}

// ── LOOCV for piecewise-linear model ──

double _loocvMaePiecewise(List<_Sample> samples, double maxCorrectionDeg) {
  if (samples.length < 4) return double.nan;
  double sum = 0.0;
  for (int i = 0; i < samples.length; i++) {
    final trainSamples = <_Sample>[];
    for (int j = 0; j < samples.length; j++) {
      if (j == i) continue;
      trainSamples.add(samples[j]);
    }
    final pw = _buildPiecewiseLinear(trainSamples, maxCorrectionDeg);
    final knots = pw['knots'] as List<double>;
    final values = pw['values'] as List<double>;
    final pred =
        _applyPiecewise(samples[i].raw, knots, values, maxCorrectionDeg);
    sum += (pred - samples[i].reference).abs();
  }
  return sum / samples.length;
}
