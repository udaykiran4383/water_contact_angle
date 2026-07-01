part of '../image_processor.dart';

Map<String, double> _detectContactPoints(
    List<math.Point<double>> dropContourAligned, {
    List<math.Point<double>>? fallbackContourAligned,
  }) {
    final preferConsensus = dropContourAligned.length < 180;
    if (preferConsensus) {
      // The consensus branch is more stable for sparse, low-angle, and
      // reflection-heavy captures where side-line extrapolation drifts inward.
      return _fallbackContactPoints(fallbackContourAligned ?? dropContourAligned);
    }

    double adaptiveSurfaceClearance(List<math.Point<double>> pts) {
      final near = pts
          .where((p) => p.y < 0.0 && p.y > -3.0)
          .map((p) => -p.y)
          .toList()
        ..sort();
      if (near.length < 8) return 0.10;
      final idx = (near.length * 0.30).floor().clamp(0, near.length - 1);
      return near[idx].clamp(0.05, 1.10);
    }

    final clearance = adaptiveSurfaceClearance(dropContourAligned);
    final upper = dropContourAligned.where((p) => p.y <= -clearance).toList();
    if (upper.length < 10) {
      return _fallbackContactPoints(fallbackContourAligned ?? dropContourAligned);
    }

    final apex = upper.reduce((a, b) => a.y < b.y ? a : b);
    final apexX = apex.x;
    final dropHeight = (-apex.y).clamp(8.0, 220.0);
    final sideBandDepth = (dropHeight * 0.45).clamp(12.0, 60.0);
    final leftUpper = upper.where((p) => p.x < apexX - 0.8).toList();
    final rightUpper = upper.where((p) => p.x > apexX + 0.8).toList();
    if (leftUpper.length < 6 || rightUpper.length < 6) {
      return _fallbackContactPoints(fallbackContourAligned ?? dropContourAligned);
    }

    Map<String, double> fitSide(List<math.Point<double>> sidePoints, bool isLeft) {
      var band = sidePoints
          .where((p) => p.y <= -clearance && p.y >= -sideBandDepth)
          .toList();
      if (band.length < 8) {
        band = sidePoints.where((p) => p.y <= -clearance).toList();
      }
      if (band.length < 6) {
        return {'x': double.nan, 'confidence': 0.0, 'slope': double.nan};
      }

      // Keep only the outer droplet silhouette branch to reject cavity/shadow points.
      final outerByY = <int, double>{};
      for (final p in band) {
        final yKey = p.y.round();
        final existing = outerByY[yKey];
        if (existing == null) {
          outerByY[yKey] = p.x;
        } else {
          outerByY[yKey] = isLeft ? math.min(existing, p.x) : math.max(existing, p.x);
        }
      }
      final profile = outerByY.entries
          .map((e) => math.Point<double>(e.value, e.key.toDouble()))
          .toList()
        ..sort((a, b) => b.y.compareTo(a.y)); // closest to baseline first
      if (profile.length < 5) {
        return {'x': double.nan, 'confidence': 0.0, 'slope': double.nan};
      }

      final useN = math.min(24, math.max(8, (profile.length * 0.60).round()));
      final local = profile.take(useN).toList();

      // Fit x = a*y + c (stable for near-vertical sidewalls).
      double sw = 0.0, sy = 0.0, sx = 0.0, syy = 0.0, syx = 0.0;
      for (final p in local) {
        final clearance = (-p.y).clamp(0.0, 28.0);
        final w = 0.35 + 0.65 * (1.0 - (clearance / 28.0));
        sw += w;
        sy += w * p.y;
        sx += w * p.x;
        syy += w * p.y * p.y;
        syx += w * p.y * p.x;
      }
      if (sw <= 1e-9) {
        return {'x': double.nan, 'confidence': 0.0, 'slope': double.nan};
      }
      final denom = sw * syy - sy * sy;
      double a = 0.0;
      if (denom.abs() > 1e-8) {
        a = (sw * syx - sy * sx) / denom;
      }
      final c = (sx - a * sy) / sw; // x at y=0 => true contact on baseline

      double ss = 0.0;
      for (final p in local) {
        final xPred = a * p.y + c;
        final e = p.x - xPred;
        ss += e * e;
      }
      final rms = math.sqrt(ss / math.max(1.0, local.length.toDouble()));
      final confidence = (math.exp(-rms / 2.2) *
              (local.length / 12.0).clamp(0.0, 1.0))
          .clamp(0.0, 1.0);

      double slope;
      if (a.abs() < 1e-6) {
        slope = isLeft ? double.negativeInfinity : double.infinity;
      } else {
        slope = 1.0 / a; // dy/dx
      }
      return {'x': c, 'confidence': confidence, 'slope': slope};
    }

    final leftFit = fitSide(leftUpper, true);
    final rightFit = fitSide(rightUpper, false);
    final leftX = leftFit['x']!;
    final rightX = rightFit['x']!;
    final leftConfidence = leftFit['confidence']!;
    final rightConfidence = rightFit['confidence']!;

    final xMin = upper.map((p) => p.x).reduce(math.min);
    final xMax = upper.map((p) => p.x).reduce(math.max);
    final minSpan = math.max(8.0, (xMax - xMin) * 0.24);
    final straddlesApex = leftX < apexX - 1.0 && rightX > apexX + 1.0;

    int supportAt(double x) => upper
        .where((p) => (p.x - x).abs() <= 2.8 && p.y <= -0.8)
        .length;

    final leftSupport = leftX.isFinite ? supportAt(leftX) : 0;
    final rightSupport = rightX.isFinite ? supportAt(rightX) : 0;

    final valid = leftX.isFinite &&
        rightX.isFinite &&
        rightX > leftX + minSpan &&
        straddlesApex &&
        leftSupport >= 1 &&
        rightSupport >= 1;
    if (!valid) {
      return _fallbackContactPoints(fallbackContourAligned ?? dropContourAligned);
    }

    return {
      'leftX': leftX,
      'rightX': rightX,
      'left_confidence': leftConfidence,
      'right_confidence': rightConfidence,
      'left_slope': leftFit['slope']!,
      'right_slope': rightFit['slope']!,
      'on_surface': 1.0,
    };
  }

Map<String, double> _fallbackContactPoints(
    List<math.Point<double>> contourAligned,
  ) {
    if (contourAligned.length < 2) {
      return {
        'leftX': double.nan,
        'rightX': double.nan,
        'left_confidence': 0.0,
        'right_confidence': 0.0,
      };
    }

    final apex = contourAligned.reduce((a, b) => a.y < b.y ? a : b);
    final apexX = apex.x;
    var left = contourAligned.where((p) => p.x < apexX - 0.6).toList();
    var right = contourAligned.where((p) => p.x > apexX + 0.6).toList();

    if (left.length < 3 || right.length < 3) {
      final sorted = List<math.Point<double>>.from(contourAligned)
        ..sort((a, b) => a.x.compareTo(b.x));
      final mid = sorted.length ~/ 2;
      left = sorted.take(math.max(1, mid)).toList();
      right = sorted.skip(mid).toList();
    }

    List<math.Point<double>> nearBaseline(List<math.Point<double>> points) {
      var primary = points.where((p) => p.y >= -8.0 && p.y <= 0.8).toList();
      if (primary.length >= 2) return primary;
      primary = points.where((p) => p.y >= -15.0 && p.y <= 1.2).toList();
      if (primary.length >= 2) return primary;
      primary = points.where((p) => p.y >= -25.0 && p.y <= 1.8).toList();
      if (primary.length >= 2) return primary;
      final bounded = points.where((p) => p.y <= 2.2).toList();
      return bounded.isNotEmpty ? bounded : points;
    }

    final leftCandidates = nearBaseline(left);
    final rightCandidates = nearBaseline(right);
    final leftXGeom = _estimateContactX(leftCandidates, isLeft: true);
    final rightXGeom = _estimateContactX(rightCandidates, isLeft: false);
    final leftXZero =
        _estimateContactXByZeroCrossing(leftCandidates, isLeft: true);
    final rightXZero =
        _estimateContactXByZeroCrossing(rightCandidates, isLeft: false);
    final leftXLine =
        _estimateContactXByLineIntersection(leftCandidates, isLeft: true);
    final rightXLine =
        _estimateContactXByLineIntersection(rightCandidates, isLeft: false);
    final leftXMedian = _estimateContactXByMedian(leftCandidates, isLeft: true);
    final rightXMedian =
        _estimateContactXByMedian(rightCandidates, isLeft: false);

    final leftConsensus = _selectConsensusContactX(
      <double>[
        leftXGeom,
        leftXZero,
        leftXLine,
        leftXMedian,
        if (leftXZero.isFinite && leftXGeom.isFinite) 0.65 * leftXZero + 0.35 * leftXGeom,
      ],
      leftCandidates,
      contourAligned,
      isLeft: true,
    );
    final rightConsensus = _selectConsensusContactX(
      <double>[
        rightXGeom,
        rightXZero,
        rightXLine,
        rightXMedian,
        if (rightXZero.isFinite && rightXGeom.isFinite)
          0.65 * rightXZero + 0.35 * rightXGeom,
      ],
      rightCandidates,
      contourAligned,
      isLeft: false,
    );

    double leftX = leftConsensus['x']!;
    double rightX = rightConsensus['x']!;
    if (!leftX.isFinite || !rightX.isFinite || rightX <= leftX + 4.0) {
      final leftOuter = leftCandidates.map((p) => p.x).reduce(math.min);
      final rightOuter = rightCandidates.map((p) => p.x).reduce(math.max);
      if (rightOuter > leftOuter + 4.0) {
        leftX = leftOuter;
        rightX = rightOuter;
      }
    }

    return {
      'leftX': leftX,
      'rightX': rightX,
      'left_confidence': math.max(0.10, leftConsensus['confidence'] ?? 0.0),
      'right_confidence': math.max(0.10, rightConsensus['confidence'] ?? 0.0),
      'left_slope': double.nan,
      'right_slope': double.nan,
      'on_surface': 1.0,
    };
  }

double _estimateContactX(
    List<math.Point<double>> sidePoints, {
    required bool isLeft,
  }) {
    if (sidePoints.isEmpty) return double.nan;
    final byBaseline = List<math.Point<double>>.from(sidePoints)
      ..sort((a, b) => b.y.compareTo(a.y));
    final topCount =
        math.min(20, math.max(6, (byBaseline.length * 0.35).round()));
    final top = byBaseline.take(topCount).toList();

    // Use the outer flank as the raw contact prior.
    // Waist-based inflection logic later overrides this inward when
    // reflection flare is detected.
    top.sort((a, b) => isLeft ? a.x.compareTo(b.x) : b.x.compareTo(a.x));
    final coreCount = math.min(10, math.max(3, (top.length * 0.60).round()));
    final core = top.take(coreCount).toList();

    double sumWX = 0.0;
    double sumW = 0.0;
    for (int i = 0; i < core.length; i++) {
      final p = core[i];
      final baselineWeight = 1.0 / (0.35 + p.y.abs());
      final rankWeight = 1.0 + (core.length - i) / core.length;
      final w = baselineWeight * rankWeight;
      sumWX += w * p.x;
      sumW += w;
    }
    if (sumW <= 0.0) {
      return core.first.x;
    }
    return sumWX / sumW;
  }

double _estimateContactXByZeroCrossing(
    List<math.Point<double>> sidePoints, {
    required bool isLeft,
  }) {
    if (sidePoints.length < 2) return double.nan;

    // Sort by y to ensure we cross the baseline from bottom up
    final sorted = List<math.Point<double>>.from(sidePoints)
      ..sort((a, b) => a.y.compareTo(b.y));

    // Look for the point sequence crossing y = 0
    for (int i = 0; i < sorted.length - 1; i++) {
      final p1 = sorted[i];
      final p2 = sorted[i + 1];
      if (p1.y <= 0 && p2.y >= 0) {
        // Linear interpolation to find x where y=0
        if (p1.y == p2.y) return (p1.x + p2.x) / 2.0;
        final t = (0 - p1.y) / (p2.y - p1.y);
        return p1.x + t * (p2.x - p1.x);
      }
    }

    // If no zero crossing, return the point closest to y=0
    return sorted.reduce((a, b) => a.y.abs() < b.y.abs() ? a : b).x;
  }

double _estimateContactXByMedian(
    List<math.Point<double>> sidePoints, {
    required bool isLeft,
  }) {
    if (sidePoints.isEmpty) return double.nan;
    final byAbsY = List<math.Point<double>>.from(sidePoints)
      ..sort((a, b) => a.y.abs().compareTo(b.y.abs()));
    final takeN = math.min(12, math.max(4, (byAbsY.length * 0.45).round()));
    final top = byAbsY.take(takeN).toList();
    if (top.isEmpty) return double.nan;
    final xs = top.map((p) => p.x).toList()..sort();
    final mid = xs.length ~/ 2;
    final median =
        xs.length.isOdd ? xs[mid] : (xs[mid - 1] + xs[mid]) / 2.0;
    if (!isLeft) return median;
    return median;
  }

double _estimateContactXByLineIntersection(
    List<math.Point<double>> sidePoints, {
    required bool isLeft,
  }) {
    if (sidePoints.length < 4) return double.nan;
    final near = sidePoints.where((p) => p.y >= -24.0 && p.y <= 2.5).toList();
    if (near.length < 4) return double.nan;

    // Fit y = m*x + c by least squares.
    double sumX = 0.0;
    double sumY = 0.0;
    for (final p in near) {
      sumX += p.x;
      sumY += p.y;
    }
    final meanX = sumX / near.length;
    final meanY = sumY / near.length;
    double num = 0.0;
    double den = 0.0;
    for (final p in near) {
      final dx = p.x - meanX;
      num += dx * (p.y - meanY);
      den += dx * dx;
    }
    if (den.abs() < 1e-8) return double.nan;
    final slope = num / den;
    if (!slope.isFinite || slope.abs() < 0.02) return double.nan;
    final intercept = meanY - slope * meanX;
    final xAtBaseline = -intercept / slope;
    if (!xAtBaseline.isFinite) return double.nan;

    // Enforce expected side behavior to avoid branch swaps.
    if (isLeft && slope < -2.5) return double.nan;
    if (!isLeft && slope > 2.5) return double.nan;
    return xAtBaseline;
  }

Map<String, double> _selectConsensusContactX(
    List<double> hypotheses,
    List<math.Point<double>> sideCandidates,
    List<math.Point<double>> fullContour, {
    required bool isLeft,
  }) {
    final valid = <double>[];
    for (final x in hypotheses) {
      if (!x.isFinite) continue;
      if (valid.any((v) => (v - x).abs() < 0.25)) continue;
      valid.add(x);
    }
    if (valid.isEmpty) {
      return {'x': double.nan, 'confidence': 0.0};
    }

    double bestX = valid.first;
    double bestScore = double.negativeInfinity;
    double secondBest = double.negativeInfinity;
    final outerBand = sideCandidates
        .where((p) => p.y >= -10.0 && p.y <= 1.0)
        .toList();
    final outerAnchor = outerBand.isNotEmpty
        ? (isLeft
            ? outerBand.map((p) => p.x).reduce(math.min)
            : outerBand.map((p) => p.x).reduce(math.max))
        : (isLeft
            ? sideCandidates.map((p) => p.x).reduce(math.min)
            : sideCandidates.map((p) => p.x).reduce(math.max));
    final candidateScores = <double, double>{};

    for (final candidateX in valid) {
      final nearPoints = sideCandidates
          .where((p) => (p.x - candidateX).abs() <= 10.0 && p.y <= 2.2)
          .toList();
      final localPoints = fullContour
          .where((p) => (p.x - candidateX).abs() <= 10.0 && p.y < -1.0)
          .toList();

      double support = nearPoints.length.toDouble();
      if (localPoints.length >= 2) {
        support += 0.8 * localPoints.length;
      }

      double yPenalty = 0.0;
      if (nearPoints.isNotEmpty) {
        final meanAbsY = nearPoints
                .map((p) => p.y.abs())
                .reduce((a, b) => a + b) /
            nearPoints.length;
        yPenalty = 0.65 * meanAbsY;
      } else {
        yPenalty = 3.0;
      }

      double slopeReward = 0.0;
      if (localPoints.length >= 3) {
        localPoints.sort((a, b) => a.y.compareTo(b.y));
        final p1 = localPoints.first;
        final p2 = localPoints.last;
        final dx = (p2.x - p1.x);
        final dy = (p2.y - p1.y);
        if (dx.abs() > 1e-6) {
          final slope = dy / dx;
          final expectedSignOk = isLeft ? slope < 0.0 : slope > 0.0;
          slopeReward = expectedSignOk ? 2.0 : -2.0;
        }
      }

      double consensusReward = 0.0;
      for (final other in valid) {
        final dist = (other - candidateX).abs();
        if (dist < 1.0) {
          consensusReward += 1.2;
        } else if (dist < 2.0) {
          consensusReward += 0.6;
        } else if (dist > 6.0) {
          consensusReward -= 0.4;
        }
      }

      final outerDist = (candidateX - outerAnchor).abs();
      final outerReward = 3.0 * math.exp(-outerDist / 2.6);
      final inwardPenalty = outerDist > 5.5 ? 1.8 : 0.0;

      final score =
          support + slopeReward + consensusReward + outerReward - yPenalty - inwardPenalty;
      candidateScores[candidateX] = score;
      if (score > bestScore) {
        secondBest = bestScore;
        bestScore = score;
        bestX = candidateX;
      } else if (score > secondBest) {
        secondBest = score;
      }
    }

    // Favor the physically correct outer intersection when it has comparable
    // support to an inner alternative.
    double? outerCandidate;
    double outerCandidateScore = double.negativeInfinity;
    for (final x in valid) {
      final dist = (x - outerAnchor).abs();
      if (dist < 2.5) {
        final s = candidateScores[x] ?? double.negativeInfinity;
        if (s > outerCandidateScore) {
          outerCandidateScore = s;
          outerCandidate = x;
        }
      }
    }
    if (outerCandidate != null &&
        outerCandidateScore.isFinite &&
        outerCandidateScore >= bestScore - 1.4) {
      bestX = outerCandidate;
      bestScore = outerCandidateScore;
    }

    final separation = bestScore.isFinite && secondBest.isFinite
        ? (bestScore - secondBest).clamp(0.0, 20.0)
        : 0.0;
    final confidence = (0.08 +
            0.42 * (bestScore / (bestScore.abs() + 8.0)).clamp(0.0, 1.0) +
            0.35 * (separation / 6.0).clamp(0.0, 1.0))
        .clamp(0.0, 1.0);

    return {'x': bestX, 'confidence': confidence};
  }
