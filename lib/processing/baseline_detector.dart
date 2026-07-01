part of '../image_processor.dart';

/// Detect baseline using two-pass robust RANSAC + least-squares.
Map<String, dynamic> _detectBaseline(List<math.Point<double>> contour) {
  if (contour.isEmpty) {
    return {
      'slope': 0.0,
      'intercept': 0.0,
      'angle': 0.0,
      'angle_rad': 0.0,
      'rms': 0.0,
      'span_fraction': 0.0,
      'inlier_fraction': 0.0,
      'tilt_penalty': 1.0,
      'confidence': 0.0,
    };
  }

  final double maxY = contour.map((p) => p.y).reduce(math.max);
  final double minY = contour.map((p) => p.y).reduce(math.min);
  final double yRange = (maxY - minY).abs();
  final double xRange = (contour.map((p) => p.x).reduce(math.max) -
          contour.map((p) => p.x).reduce(math.min))
      .abs();
  final double contourDiag = math.sqrt(xRange * xRange + yRange * yRange);
  final double coarseThreshold = (contourDiag * 0.006).clamp(1.8, 4.2);
  final double fineThreshold = (coarseThreshold * 0.55).clamp(0.9, 2.3);

  // Pass 1: Wide band to catch true baseline even if reflections exist below drop
  final double bottomBand1 = (yRange * 0.20).clamp(10.0, 40.0);
  final bottomPoints = contour.where((p) => p.y >= maxY - bottomBand1).toList();
  if (bottomPoints.length < 6) {
    return {
      'slope': 0.0,
      'intercept': maxY,
      'angle': 0.0,
      'angle_rad': 0.0,
      'rms': 0.0,
      'span_fraction': 0.0,
      'inlier_fraction': 0.0,
      'tilt_penalty': 1.0,
      'confidence': 0.0,
    };
  }

  final rnd = math.Random(42);
  final double minDx = ((bottomPoints.map((p) => p.x).reduce(math.max) -
              bottomPoints.map((p) => p.x).reduce(math.min)) *
          0.05)
      .clamp(6.0, 30.0);

  double bestSlope = 0.0;
  double bestIntercept = maxY;
  double bestScore = double.negativeInfinity;
  List<math.Point<double>> bestInliers = [];

  // Pass 1: RANSAC with resolution-aware inlier threshold.
  for (int iter = 0; iter < 300; iter++) {
    final p1 = bottomPoints[rnd.nextInt(bottomPoints.length)];
    final p2 = bottomPoints[rnd.nextInt(bottomPoints.length)];
    final dx = p2.x - p1.x;
    if (dx.abs() < minDx) continue;

    final slope = (p2.y - p1.y) / dx;
    final angleDeg = math.atan(slope) * 180.0 / math.pi;
    if (angleDeg.abs() > _maxBaselineTiltDeg) continue;

    final intercept = p1.y - slope * p1.x;
    final denom = math.sqrt(1.0 + slope * slope);
    final inliers = <math.Point<double>>[];
    double errSum = 0.0;

    for (final p in bottomPoints) {
      final dist = ((slope * p.x - p.y + intercept).abs()) / denom;
      if (dist < coarseThreshold) {
        inliers.add(p);
        errSum += dist;
      }
    }

    if (inliers.length < 5) continue;
    final meanErr = errSum / inliers.length;

    // Reward lines with wide horizontal span.
    // The true surface spans the full image, reflections span only the drop.
    final inlierMinX = inliers.map((p) => p.x).reduce(math.min);
    final inlierMaxX = inliers.map((p) => p.x).reduce(math.max);
    final spanBonus = (inlierMaxX - inlierMinX) * 0.30;

    // Heavily penalize baseline tilt and mean error
    final score =
        inliers.length + spanBonus - 0.50 * meanErr - 2.0 * angleDeg.abs();

    if (score > bestScore) {
      bestScore = score;
      bestSlope = slope;
      bestIntercept = intercept;
      bestInliers = inliers;
    }
  }

  if (bestInliers.length >= 5) {
    final refined = _fitLineLeastSquaresRobust(bestInliers);
    bestSlope = refined['slope']!;
    bestIntercept = refined['intercept']!;
  } else {
    bestSlope = 0.0;
    bestIntercept = maxY;
  }

  // Pass 2: Refine using points tightly clustered near the coarse baseline
  final pass2Inliers = <math.Point<double>>[];
  final denomFinal = math.sqrt(1.0 + bestSlope * bestSlope);
  for (final p in bottomPoints) {
    final dist = ((bestSlope * p.x - p.y + bestIntercept).abs()) / denomFinal;
    if (dist < fineThreshold) {
      pass2Inliers.add(p);
    }
  }

  if (pass2Inliers.length >= 5) {
    final pass2Refined = _fitLineLeastSquaresRobust(pass2Inliers);
    bestSlope = pass2Refined['slope']!;
    bestIntercept = pass2Refined['intercept']!;
    bestInliers = pass2Inliers;
  }

  double angleRad = math.atan(bestSlope);
  double angleDeg = angleRad * 180.0 / math.pi;
  if (angleDeg.abs() > _maxBaselineTiltDeg) {
    bestSlope = 0.0;
    angleRad = 0.0;
    angleDeg = 0.0;
    bestIntercept = maxY;
  }

  double rms = 0.0;
  if (bestInliers.isNotEmpty) {
    double sumSq = 0.0;
    for (final p in bestInliers) {
      final d = _lineDistance(p, bestSlope, bestIntercept);
      sumSq += d * d;
    }
    rms = math.sqrt(sumSq / bestInliers.length);
  }

  final minContourX = contour.map((p) => p.x).reduce(math.min);
  final maxContourX = contour.map((p) => p.x).reduce(math.max);
  final contourSpan = math.max(1.0, maxContourX - minContourX);
  double inlierMinX = double.infinity;
  double inlierMaxX = double.negativeInfinity;
  for (final p in bestInliers) {
    inlierMinX = math.min(inlierMinX, p.x);
    inlierMaxX = math.max(inlierMaxX, p.x);
  }
  final inlierSpan =
      bestInliers.isEmpty ? 0.0 : math.max(0.0, inlierMaxX - inlierMinX);
  final spanFraction = (inlierSpan / contourSpan).clamp(0.0, 1.0);
  final inlierFraction =
      (bestInliers.length / math.max(1, bottomPoints.length)).clamp(0.0, 1.0);
  final tiltPenalty = (angleDeg.abs() / _maxBaselineTiltDeg).clamp(0.0, 1.0);
  final confidence = (math.exp(-rms / 1.8) *
          math.pow(inlierFraction, 0.8) *
          math.pow(spanFraction, 1.2) *
          (1.0 - 0.55 * tiltPenalty))
      .clamp(0.0, 1.0);

  return {
    'slope': bestSlope,
    'intercept': bestIntercept,
    'angle': angleDeg,
    'angle_rad': angleRad,
    'rms': rms,
    'span_fraction': spanFraction,
    'inlier_fraction': inlierFraction,
    'tilt_penalty': tiltPenalty,
    'confidence': confidence,
  };
}

Map<String, double> _fitLineLeastSquares(List<math.Point<double>> points) {
  if (points.length < 2) return {'slope': 0.0, 'intercept': 0.0};

  double meanX = points.map((p) => p.x).reduce((a, b) => a + b) / points.length;
  double meanY = points.map((p) => p.y).reduce((a, b) => a + b) / points.length;

  double num = 0.0;
  double den = 0.0;
  for (final p in points) {
    final dx = p.x - meanX;
    num += dx * (p.y - meanY);
    den += dx * dx;
  }

  final slope = den.abs() > 1e-10 ? num / den : 0.0;
  final intercept = meanY - slope * meanX;
  return {'slope': slope, 'intercept': intercept};
}

Map<String, double> _fitLineLeastSquaresRobust(
    List<math.Point<double>> points) {
  if (points.length < 2) return {'slope': 0.0, 'intercept': 0.0};

  var fit = _fitLineLeastSquares(points);
  for (int iter = 0; iter < 3; iter++) {
    final residuals = points
        .map((p) => _lineDistance(p, fit['slope']!, fit['intercept']!))
        .toList();
    final scale = math.max(0.8, 1.4826 * _median(residuals));
    final weighted = <math.Point<double>>[];
    final weights = <double>[];
    for (int i = 0; i < points.length; i++) {
      final u = residuals[i] / (4.685 * scale);
      if (u.abs() >= 1.0) continue;
      final w = math.pow(1.0 - u * u, 2).toDouble();
      if (w <= 1e-6) continue;
      weighted.add(points[i]);
      weights.add(w);
    }
    if (weighted.length < 2) break;
    fit = _fitLineWeightedLeastSquares(weighted, weights);
  }
  return fit;
}

Map<String, double> _fitLineWeightedLeastSquares(
    List<math.Point<double>> points, List<double> weights) {
  if (points.length < 2 || points.length != weights.length) {
    return _fitLineLeastSquares(points);
  }

  double sumW = 0.0;
  double meanX = 0.0;
  double meanY = 0.0;
  for (int i = 0; i < points.length; i++) {
    final w = weights[i];
    sumW += w;
    meanX += w * points[i].x;
    meanY += w * points[i].y;
  }
  if (sumW <= 1e-10) {
    return _fitLineLeastSquares(points);
  }
  meanX /= sumW;
  meanY /= sumW;

  double num = 0.0;
  double den = 0.0;
  for (int i = 0; i < points.length; i++) {
    final dx = points[i].x - meanX;
    num += weights[i] * dx * (points[i].y - meanY);
    den += weights[i] * dx * dx;
  }

  final slope = den.abs() > 1e-10 ? num / den : 0.0;
  final intercept = meanY - slope * meanX;
  return {'slope': slope, 'intercept': intercept};
}

double _lineDistance(
  math.Point<double> point,
  double slope,
  double intercept,
) {
  return (slope * point.x - point.y + intercept).abs() /
      math.sqrt(1.0 + slope * slope);
}

math.Point<double> _toBaselineFrame(
  math.Point<double> p,
  Map<String, dynamic> baseline,
) {
  final double slope = (baseline['slope'] as num).toDouble();
  final double intercept = (baseline['intercept'] as num).toDouble();
  final double angle = math.atan(slope);
  final double cosA = math.cos(angle);
  final double sinA = math.sin(angle);

  final double dx = p.x;
  final double dy = p.y - intercept;
  final double xAligned = dx * cosA + dy * sinA;
  final double yAligned = -dx * sinA + dy * cosA;
  return math.Point(xAligned, yAligned);
}

math.Point<double> _fromBaselineFrame(
  math.Point<double> pAligned,
  Map<String, dynamic> baseline,
) {
  final double slope = (baseline['slope'] as num).toDouble();
  final double intercept = (baseline['intercept'] as num).toDouble();
  final double angle = math.atan(slope);
  final double cosA = math.cos(angle);
  final double sinA = math.sin(angle);

  final double x = pAligned.x * cosA - pAligned.y * sinA;
  final double y = intercept + pAligned.x * sinA + pAligned.y * cosA;
  return math.Point(x, y);
}

double _baselineYAtX(Map<String, dynamic> baseline, double x) {
  final slope = (baseline['slope'] as num).toDouble();
  final intercept = (baseline['intercept'] as num).toDouble();
  return slope * x + intercept;
}
