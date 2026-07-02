part of '../image_processor.dart';

/// Calculate ensemble angle from multiple methods weighted by R²
Map<String, dynamic> _calculateEnsembleAngle(
    Map<String, Map<String, dynamic>> methodResults) {
  final polyResult = methodResults['polynomial'];
  final polyAngle = _isMethodValid(polyResult)
      ? ((polyResult!['angle'] as num?)?.toDouble() ?? double.nan)
      : double.nan;

  final validAngles = <double>[];
  for (final result in methodResults.values) {
    final angle = (result['angle'] as num?)?.toDouble() ?? double.nan;
    if (_isMethodValid(result) && angle.isFinite) validAngles.add(angle);
  }
  validAngles.sort();
  double medianAngle = 90.0;
  if (validAngles.isNotEmpty) {
    final mid = validAngles.length ~/ 2;
    medianAngle = validAngles.length.isOdd
        ? validAngles[mid]
        : (validAngles[mid - 1] + validAngles[mid]) / 2.0;
  }
  double robustScale = 18.0;
  if (validAngles.length >= 3) {
    final absDev = validAngles.map((a) => (a - medianAngle).abs()).toList();
    final mad = _median(absDev);
    robustScale = math.max(10.0, 2.8 * 1.4826 * mad + 8.0);
  }

  double tukeyWeight(double angle) {
    final disagreement = (angle - medianAngle).abs();
    final cutoff = math.max(6.0, robustScale * 1.5);
    final u = disagreement / cutoff;
    if (u >= 1.0) {
      return 0.03;
    }
    final core = 1.0 - u * u;
    return core * core;
  }

  double baseMethodWeight(String key, Map<String, dynamic> result) {
    final angle = (result['angle'] as num?)?.toDouble() ?? double.nan;
    if (!angle.isFinite) return 0.0;

    double rSq = (result['r_squared'] as num?)?.toDouble() ?? 0.5;
    final contactConfidence =
        ((result['contact_confidence'] as num?)?.toDouble() ?? 0.7)
            .clamp(0.0, 1.0);
    final symmetryScore =
        ((result['symmetry_score'] as num?)?.toDouble() ?? 0.6).clamp(0.0, 1.0);

    rSq = rSq.clamp(0.0, 1.0);
    final residual = (result['residual'] as num?)?.toDouble() ?? double.nan;

    // Axisymmetric Drop Shape Analysis (Young-Laplace) is the physically
    // rigorous, gold-standard method. When it achieves a near-perfect geometric
    // fit (true R² and a small orthogonal residual) it is authoritative and
    // should ANCHOR the ensemble rather than be down-weighted as an "outlier"
    // versus geometrically cruder circle/polynomial fits. In that regime we
    // bypass the median-based Tukey penalty and grant a strong, quality-scaled
    // weight; otherwise Young-Laplace is weighted like any other method.
    final bool ylAuthoritative =
        key == 'young_laplace' && _isYoungLaplaceAuthoritative(result);
    if (ylAuthoritative) {
      final residualPenalty =
          residual.isFinite ? math.exp(-(residual / 0.05).clamp(0.0, 3.0)) : 0.7;
      double weight = (2.6 + 3.0 * (rSq - 0.97).clamp(0.0, 0.03) / 0.03) *
          residualPenalty *
          (0.5 + 0.5 * symmetryScore) *
          (0.55 + 0.45 * contactConfidence);
      return weight;
    }

    double weight = rSq >= _minRSquared ? (rSq * rSq + 0.05) : rSq * 0.35;
    weight *= tukeyWeight(angle);

    if (key == 'young_laplace' && rSq > 0.7) {
      final residualPenalty = residual.isFinite
          ? math.exp(-(residual / 0.22).clamp(0.0, 3.5))
          : 0.85;
      weight *= 1.28 * residualPenalty * (0.45 + 0.55 * symmetryScore);
    }
    if (key == 'polynomial') {
      final usedPoints = (result['used_points'] as num?)?.toDouble() ?? 0.0;
      if (usedPoints < 12.0) weight *= 0.7;
      if (validAngles.length >= 2) weight *= 0.82;
      final yl = methodResults['young_laplace'];
      if (polyAngle.isFinite && _isMethodValid(yl)) {
        final ylAngle = (yl!['angle'] as num?)?.toDouble() ?? double.nan;
        final ylResidual =
            (yl['residual'] as num?)?.toDouble() ?? double.infinity;
        if (ylAngle.isFinite &&
            (ylAngle - polyAngle).abs() > 45.0 &&
            ylResidual < 0.12) {
          weight *= 0.58;
        }
      }
    }
    if (key == 'ellipse') {
      weight *= (0.60 + 0.40 * symmetryScore);
    }
    weight *= (0.55 + 0.45 * contactConfidence);
    return weight;
  }

  double weightedAverageAngle(
    Map<String, double> rawWeights, {
    String? exclude,
  }) {
    double sum = 0.0;
    double total = 0.0;
    for (final entry in rawWeights.entries) {
      if (entry.key == exclude) continue;
      final angle = (methodResults[entry.key]!['angle'] as num?)?.toDouble() ??
          double.nan;
      if (!angle.isFinite || entry.value <= 0.0) continue;
      sum += angle * entry.value;
      total += entry.value;
    }
    return total > 1e-8 ? sum / total : double.nan;
  }

  final rawWeights = <String, double>{};
  for (final entry in methodResults.entries) {
    if (!_isMethodValid(entry.value)) continue;
    final weight = baseMethodWeight(entry.key, entry.value);
    if (weight >= 1e-5) {
      rawWeights[entry.key] = weight;
    }
  }

  // An authoritative ADSA fit is *meant* to move the ensemble; do not punish
  // it via the leave-one-out consistency check (which assumes every method is
  // an equally-trusted vote).
  final bool ylAuthoritative =
      _isYoungLaplaceAuthoritative(methodResults['young_laplace']);

  if (rawWeights.length >= 3) {
    final baseAngle = weightedAverageAngle(rawWeights);
    if (baseAngle.isFinite) {
      for (final key in rawWeights.keys.toList()) {
        if (key == 'young_laplace' && ylAuthoritative) continue;
        final looAngle = weightedAverageAngle(rawWeights, exclude: key);
        if (!looAngle.isFinite) continue;
        final shift = (looAngle - baseAngle).abs();
        if (shift > 3.0) {
          final penalty = math.exp(-math.pow((shift - 3.0) / 4.0, 2));
          rawWeights[key] = rawWeights[key]! * penalty;
        }
      }
    }
  }

  double sumAngle = 0.0, sumWeight = 0.0;
  double sumLeft = 0.0, sumRight = 0.0;
  double sumWeightLR = 0.0;
  Map<String, double> weights = {};

  for (final entry in rawWeights.entries) {
    final angle =
        (methodResults[entry.key]!['angle'] as num?)?.toDouble() ?? double.nan;
    if (!angle.isFinite || entry.value <= 0.0) continue;

    sumAngle += angle * entry.value;
    sumWeight += entry.value;
    weights[entry.key] = entry.value;

    final left = (methodResults[entry.key]!['angle_left'] as num?)?.toDouble();
    final right =
        (methodResults[entry.key]!['angle_right'] as num?)?.toDouble();
    if (left != null && left.isFinite && right != null && right.isFinite) {
      sumLeft += left * entry.value;
      sumRight += right * entry.value;
      sumWeightLR += entry.value;
    }
  }

  if (sumWeight < 0.01) {
    final poly = methodResults['polynomial'];
    if (_isMethodValid(poly)) {
      final polyAngle = (poly!['angle'] as num?)?.toDouble() ?? 90.0;
      final polyLeft = (poly['angle_left'] as num?)?.toDouble() ?? polyAngle;
      final polyRight = (poly['angle_right'] as num?)?.toDouble() ?? polyAngle;
      return {
        'angle': polyAngle,
        'angle_left': polyLeft,
        'angle_right': polyRight,
        'weights': {'polynomial': 1.0},
      };
    }
    final fallback = validAngles.isNotEmpty ? _median(validAngles) : double.nan;
    return {
      'angle': fallback,
      'angle_left': fallback,
      'angle_right': fallback,
      'weights': weights,
    };
  }

  double ensembleAngle = sumAngle / sumWeight;
  double ensembleLeft = sumWeightLR > 0 ? sumLeft / sumWeightLR : ensembleAngle;
  double ensembleRight =
      sumWeightLR > 0 ? sumRight / sumWeightLR : ensembleAngle;

  // Normalize weights
  for (var key in weights.keys) {
    weights[key] = weights[key]! / sumWeight;
  }

  return {
    'angle': ensembleAngle,
    'angle_left': ensembleLeft,
    'angle_right': ensembleRight,
    'weights': weights,
  };
}

/// Calculate combined uncertainty from multiple sources
Map<String, double> _calculateUncertainty(
    List<double> xs,
    List<double> ys,
    List<math.Point<double>> leftPoints,
    List<math.Point<double>> rightPoints,
    double baselineY,
    double leftX,
    double rightX,
    Map<String, Map<String, dynamic>> methodResults,
    {double baselineSigmaPx = 0.5}) {
  // 1. Bootstrap uncertainty with multi-model sampling.
  //
  // Contour points are NOT independent: neighbouring edge samples share the
  // same local blur/noise, so an i.i.d. bootstrap badly under-estimates the
  // confidence interval. We use a circular *moving-block* bootstrap, drawing
  // contiguous blocks (length ≈ √n) so the resamples preserve the spatial
  // correlation structure of the contour and yield an honest interval.
  List<double> bootstrapAngles = [];
  final rnd = math.Random(7);
  final int blockLen =
      xs.isEmpty ? 1 : math.sqrt(xs.length).round().clamp(5, 40);

  for (int t = 0; t < _bootstrapIterations; t++) {
    try {
      if (xs.length < 10) break;
      final indices = _movingBlockIndices(xs.length, blockLen, rnd);
      final sX = indices.map((i) => xs[i]).toList();
      final sY = indices.map((i) => ys[i]).toList();
      final sampleAngles = <double>[];

      final circle = AngleUtils.circleFit(sX, sY);
      final thetaCircle = AngleUtils.calculateCircleAngle(circle, baselineY);
      final circleRSq = circle.length > 3 ? circle[3] : 0.0;
      if (_isAnglePlausible(thetaCircle) && circleRSq >= _minCircleRSquared) {
        sampleAngles.add(thetaCircle);
      }

      if (sX.length >= 12) {
        final ellipse = AngleUtils.ellipseFit(sX, sY);
        final thetaEllipseLeft =
            AngleUtils.calculateEllipseAngle(ellipse, baselineY, leftX, true);
        final thetaEllipseRight =
            AngleUtils.calculateEllipseAngle(ellipse, baselineY, rightX, false);
        final thetaEllipse = (thetaEllipseLeft + thetaEllipseRight) / 2.0;
        final ellipseRSq = ellipse.length > 5 ? ellipse[5] : 0.0;
        if (_isAnglePlausible(thetaEllipse) &&
            ellipseRSq >= _minEllipseRSquared &&
            (thetaEllipseLeft - thetaEllipseRight).abs() <= 45.0) {
          sampleAngles.add(thetaEllipse);
        }
      }

      if (sampleAngles.isNotEmpty) {
        final theta =
            sampleAngles.reduce((a, b) => a + b) / sampleAngles.length;
        bootstrapAngles.add(theta);
      }
    } catch (_) {}
  }

  double bootstrapUncertainty = 0.0;
  if (bootstrapAngles.length >= 12) {
    bootstrapUncertainty = (_percentile(bootstrapAngles, 97.5) -
            _percentile(bootstrapAngles, 2.5)) /
        2.0;
  }

  // 2. Inter-method disagreement (robust MAD estimate).
  List<double> methodAngles = [];
  for (final entry in methodResults.values) {
    final angle = (entry['angle'] as num?)?.toDouble() ?? double.nan;
    if (_isMethodValid(entry) && angle.isFinite) methodAngles.add(angle);
  }

  double methodDisagreement = 0.0;
  if (methodAngles.length >= 2) {
    final median = _median(methodAngles);
    final absDev = methodAngles.map((v) => (v - median).abs()).toList();
    final mad = _median(absDev);
    methodDisagreement = 1.4826 * mad;
    if (methodDisagreement < 1e-8) {
      methodDisagreement = _sampleStdDev(methodAngles);
    }
  }

  // 3. Edge localization uncertainty from near-contact point spread.
  final leftBand = leftPoints
      .where((p) => (p.x - leftX).abs() <= 8.0)
      .map((p) => p.y.abs())
      .toList();
  final rightBand = rightPoints
      .where((p) => (p.x - rightX).abs() <= 8.0)
      .map((p) => p.y.abs())
      .toList();

  double edgeSpreadPx = 0.6;
  final spreads = <double>[];
  if (leftBand.length >= 3) spreads.add(_sampleStdDev(leftBand));
  if (rightBand.length >= 3) spreads.add(_sampleStdDev(rightBand));
  if (spreads.isNotEmpty) {
    edgeSpreadPx = spreads.reduce((a, b) => a + b) / spreads.length;
  }

  final dropRadius = math.max(5.0, (rightX - leftX).abs() / 2.0);
  double edgeUncertainty =
      math.atan(edgeSpreadPx / dropRadius) * 180.0 / math.pi;
  edgeUncertainty = edgeUncertainty.clamp(0.12, 1.5);

  // 4. Contact-line confidence penalty mapped to uncertainty.
  double bestContactConf = 0.0;
  for (final entry in methodResults.values) {
    if (!_isMethodValid(entry)) continue;
    final c = ((entry['contact_confidence'] as num?)?.toDouble() ?? 0.0)
        .clamp(0.0, 1.0);
    if (c > bestContactConf) bestContactConf = c;
  }
  final contactUncertainty =
      (0.15 + 1.65 * (1.0 - bestContactConf)).clamp(0.15, 1.8);

  // 5. Baseline-placement sensitivity — the dominant error source in
  // goniometry (Vuckovac et al., Soft Matter 2019: ±1 px of baseline ≈ 0.5°
  // for θ < 150°, growing to ~8° as θ → 180°). For a circular cap the
  // relation is exact: cos α = h/r with the contact half-width a = r·sin θ,
  // so dθ/d(baseline) = 1/(r·sin θ) = 1/a rad per pixel — reproducing both
  // the plateau and the θ→180° blow-up. σ_baseline comes from the baseline
  // fit quality (caller), floored at a conservative sub-pixel value.
  double baselineUncertainty = 0.3;
  if (methodAngles.isNotEmpty && dropRadius > 5.0) {
    final degPerPx = (1.0 / dropRadius) * 180.0 / math.pi;
    baselineUncertainty =
        (degPerPx * baselineSigmaPx.clamp(0.2, 2.0)).clamp(0.1, 12.0);
  }

  // 6. Combined uncertainty (quadrature).
  double combined = math.sqrt(
    bootstrapUncertainty * bootstrapUncertainty +
        methodDisagreement * methodDisagreement +
        edgeUncertainty * edgeUncertainty +
        contactUncertainty * contactUncertainty +
        baselineUncertainty * baselineUncertainty,
  );

  combined = combined.clamp(0.25, 20.0);

  return {
    'combined': combined,
    'bootstrap': bootstrapUncertainty,
    'method_disagreement': methodDisagreement,
    'edge': edgeUncertainty,
    'contact': contactUncertainty,
    'baseline': baselineUncertainty,
  };
}

/// Circular moving-block bootstrap index generator. Concatenates contiguous
/// (wrap-around) blocks of length [blockLen] until [n] indices are produced,
/// preserving the local correlation of ordered contour samples.
List<int> _movingBlockIndices(int n, int blockLen, math.Random rnd) {
  final out = <int>[];
  final len = blockLen.clamp(1, n);
  while (out.length < n) {
    final start = rnd.nextInt(n);
    for (int k = 0; k < len && out.length < n; k++) {
      out.add((start + k) % n);
    }
  }
  return out;
}

double _sampleStdDev(List<double> values) {
  if (values.length < 2) return 0.0;
  final mean = values.reduce((a, b) => a + b) / values.length;
  double sumSq = 0.0;
  for (final v in values) {
    final d = v - mean;
    sumSq += d * d;
  }
  return math.sqrt(sumSq / (values.length - 1));
}

double _median(List<double> values) {
  if (values.isEmpty) return 0.0;
  final sorted = List<double>.from(values)..sort();
  final mid = sorted.length ~/ 2;
  if (sorted.length.isOdd) return sorted[mid];
  return (sorted[mid - 1] + sorted[mid]) / 2.0;
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
