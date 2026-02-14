// lib/processing/young_laplace.dart
import 'dart:math' as math;

/// Young-Laplace equation solver for precise contact angle measurement.
/// Implements numerical integration of the Laplace pressure equation:
///   ΔP = γ(1/R₁ + 1/R₂)
/// For axisymmetric sessile drops, this becomes the classical ODE system.
class YoungLaplaceSolver {
  // Physical constants (SI units by default, but normalized internally)
  static const double _defaultSurfaceTension = 0.0728; // N/m for water at 20°C
  static const double _defaultDensityDiff = 998.0; // kg/m³ (water-air)
  static const double _gravity = 9.81; // m/s²

  /// Calculate Bond number: Bo = ρgR²/γ
  /// Indicates importance of gravity vs surface tension
  /// Bo << 1: surface tension dominates (spherical drop)
  /// Bo >> 1: gravity dominates (flattened drop)
  static double bondNumber(double radiusM, {double? gamma, double? deltaRho}) {
    gamma ??= _defaultSurfaceTension;
    deltaRho ??= _defaultDensityDiff;
    return (deltaRho * _gravity * radiusM * radiusM) / gamma;
  }

  /// Integrate Young-Laplace equation using RK4 to generate theoretical profile.
  ///
  /// The system of ODEs (in normalized coordinates):
  ///   dx/ds = cos(φ)
  ///   dz/ds = sin(φ)
  ///   dφ/ds = 2/b - Bo·z - sin(φ)/x
  ///
  /// Where s = arc length, b = apex curvature radius, Bo = Bond number.
  ///
  /// Returns list of (x, z) points describing the drop profile.
  static List<List<double>> integrateProfile({
    required double apexCurvature, // b = R₀ (radius at apex)
    required double bondNumber, // Bo = ρgR₀²/γ
    int numSteps = 500,
    double maxArcLength = 3.0, // in units of apex radius
  }) {
    List<List<double>> profile = [];

    // Initial conditions at apex (s = 0)
    double x = 1e-8; // avoid singularity at x=0
    double z = 0.0;
    double phi = 0.0; // horizontal tangent at apex

    double ds = maxArcLength / numSteps;
    double b = apexCurvature;
    double bo = bondNumber;

    profile.add([0.0, 0.0]); // apex point

    for (int step = 0; step < numSteps; step++) {
      // RK4 integration
      var k1 = _derivatives(x, z, phi, b, bo);
      var k2 = _derivatives(x + 0.5 * ds * k1[0], z + 0.5 * ds * k1[1],
          phi + 0.5 * ds * k1[2], b, bo);
      var k3 = _derivatives(x + 0.5 * ds * k2[0], z + 0.5 * ds * k2[1],
          phi + 0.5 * ds * k2[2], b, bo);
      var k4 =
          _derivatives(x + ds * k3[0], z + ds * k3[1], phi + ds * k3[2], b, bo);

      x += (ds / 6.0) * (k1[0] + 2 * k2[0] + 2 * k3[0] + k4[0]);
      z += (ds / 6.0) * (k1[1] + 2 * k2[1] + 2 * k3[1] + k4[1]);
      phi += (ds / 6.0) * (k1[2] + 2 * k2[2] + 2 * k3[2] + k4[2]);

      // Stop if profile becomes unphysical
      if (x <= 0 || !x.isFinite || !z.isFinite) break;

      profile.add([x, z]);

      // Stop if we've reached past π/2 contact angle region
      if (phi > math.pi) break;
    }

    return profile;
  }

  /// Compute derivatives for RK4 integration
  static List<double> _derivatives(
      double x, double z, double phi, double b, double bo) {
    double dxds = math.cos(phi);
    double dzds = math.sin(phi);

    // Handle singularity at x→0 using L'Hôpital's rule
    double sinPhiOverX = x.abs() < 1e-10 ? math.cos(phi) : math.sin(phi) / x;
    double dphids = (2.0 / b) - bo * z - sinPhiOverX;

    return [dxds, dzds, dphids];
  }

  /// Fit experimental contour to Young-Laplace solution.
  /// Uses optimization to find best-fit parameters.
  ///
  /// Returns map with:
  /// - 'contact_angle': fitted contact angle in degrees
  /// - 'apex_curvature': apex radius of curvature
  /// - 'bond_number': effective Bond number
  /// - 'residual': RMS fitting residual
  /// - 'r_squared': coefficient of determination
  static Map<String, double> fitContour(
      List<math.Point<double>> contour, double baselineY,
      {double? dropRadiusPixels}) {
    if (contour.length < 10) {
      return {
        'contact_angle': double.nan,
        'apex_curvature': double.nan,
        'bond_number': double.nan,
        'residual': double.infinity,
        'r_squared': 0.0,
      };
    }

    // Extract points above baseline
    List<math.Point<double>> dropPoints =
        contour.where((p) => p.y < baselineY - 2).toList();

    if (dropPoints.length < 8) {
      return {
        'contact_angle': double.nan,
        'apex_curvature': double.nan,
        'bond_number': double.nan,
        'residual': double.infinity,
        'r_squared': 0.0,
      };
    }

    // Find drop center x and apex
    double minY = dropPoints.map((p) => p.y).reduce(math.min);
    double leftX = dropPoints.map((p) => p.x).reduce(math.min);
    double rightX = dropPoints.map((p) => p.x).reduce(math.max);

    // Estimate apex center from upper cap (less affected by contact-line noise).
    final apexBand = dropPoints
        .where((p) => p.y <= minY + (baselineY - minY) * 0.18)
        .toList();
    double centerX = apexBand.isNotEmpty
        ? apexBand.map((p) => p.x).reduce((a, b) => a + b) / apexBand.length
        : (leftX + rightX) / 2.0;
    double dropHeight = baselineY - minY;
    double dropWidth = rightX - leftX;

    if (dropWidth <= 1e-6 || dropHeight <= 1e-6) {
      return {
        'contact_angle': double.nan,
        'apex_curvature': double.nan,
        'bond_number': double.nan,
        'residual': double.infinity,
        'r_squared': 0.0,
      };
    }

    // Estimate apex curvature from geometry
    double apexRadius = dropRadiusPixels ?? (dropWidth / 2.0);
    if (apexRadius < 5) apexRadius = 5.0;

    // Estimate Bond number based on aspect ratio
    // For small Bond numbers, drop is nearly spherical
    double aspectRatio = dropHeight / (dropWidth / 2.0);
    double estimatedBo = _estimateBondNumber(aspectRatio);

    // Height ratio of baseline in normalized coordinates.
    final targetHeightRatio = (dropHeight / apexRadius).clamp(0.05, 4.0);
    final maxArcLength = (targetHeightRatio * 2.4 + 0.8).clamp(2.6, 8.0);

    // Coarse-to-fine search for better parameter precision.
    double bestResidual = double.infinity;
    double bestAngle = 90.0;
    double bestBo = estimatedBo;
    double bestApex = 1.0;

    final boMin = math.max(0.01, estimatedBo * 0.25);
    final boMax = math.max(boMin + 0.05, estimatedBo * 3.0);
    final coarse = _searchBestParameters(
      dropPoints: dropPoints,
      centerX: centerX,
      baselineY: baselineY,
      scale: apexRadius,
      targetHeightRatio: targetHeightRatio,
      maxArcLength: maxArcLength,
      boMin: boMin,
      boMax: boMax,
      boSteps: 12,
      apexMin: 0.65,
      apexMax: 1.75,
      apexSteps: 12,
    );

    bestResidual = coarse['residual']!;
    bestAngle = coarse['angle']!;
    bestBo = coarse['bo']!;
    bestApex = coarse['apex']!;

    for (int pass = 0; pass < 2; pass++) {
      final boHalfRange = (pass == 0 ? 0.45 : 0.20) * math.max(0.05, bestBo);
      final refine = _searchBestParameters(
        dropPoints: dropPoints,
        centerX: centerX,
        baselineY: baselineY,
        scale: apexRadius,
        targetHeightRatio: targetHeightRatio,
        maxArcLength: maxArcLength,
        boMin: math.max(0.005, bestBo - boHalfRange),
        boMax: bestBo + boHalfRange,
        boSteps: 8,
        apexMin: math.max(0.45, bestApex - (pass == 0 ? 0.20 : 0.08)),
        apexMax: bestApex + (pass == 0 ? 0.20 : 0.08),
        apexSteps: 8,
      );

      if (refine['residual']! < bestResidual) {
        bestResidual = refine['residual']!;
        bestAngle = refine['angle']!;
        bestBo = refine['bo']!;
        bestApex = refine['apex']!;
      }
    }

    final bestProfile = integrateProfile(
      apexCurvature: bestApex,
      bondNumber: bestBo,
      numSteps: 550,
      maxArcLength: maxArcLength,
    );
    final stats = _calculateProfileResidualStats(
      bestProfile,
      dropPoints,
      centerX,
      baselineY,
      apexRadius,
    );

    final expXs =
        dropPoints.map((p) => (p.x - centerX).abs() / apexRadius).toList();
    final meanExpX = expXs.reduce((a, b) => a + b) / expXs.length;
    double ssTot = 0.0;
    for (final x in expXs) {
      final d = x - meanExpX;
      ssTot += d * d;
    }

    double rSquared = ssTot > 1e-12 ? 1.0 - (stats['ss_res']! / ssTot) : 0.0;
    rSquared = math.max(0.0, math.min(1.0, rSquared));

    return {
      'contact_angle': bestAngle,
      'apex_curvature': bestApex,
      'bond_number': bestBo,
      'residual': stats['rms'] ?? bestResidual,
      'r_squared': rSquared,
    };
  }

  static Map<String, double> _searchBestParameters({
    required List<math.Point<double>> dropPoints,
    required double centerX,
    required double baselineY,
    required double scale,
    required double targetHeightRatio,
    required double maxArcLength,
    required double boMin,
    required double boMax,
    required int boSteps,
    required double apexMin,
    required double apexMax,
    required int apexSteps,
  }) {
    double bestResidual = double.infinity;
    double bestAngle = 90.0;
    double bestBo = (boMin + boMax) / 2.0;
    double bestApex = (apexMin + apexMax) / 2.0;

    final boStep = boSteps <= 1 ? 0.0 : (boMax - boMin) / (boSteps - 1);
    final apexStep =
        apexSteps <= 1 ? 0.0 : (apexMax - apexMin) / (apexSteps - 1);

    for (int i = 0; i < boSteps; i++) {
      final bo = boMin + i * boStep;
      for (int j = 0; j < apexSteps; j++) {
        final apex = apexMin + j * apexStep;

        final profile = integrateProfile(
          apexCurvature: apex,
          bondNumber: bo,
          numSteps: 420,
          maxArcLength: maxArcLength,
        );
        if (profile.length < 10) continue;

        final maxZ = profile.map((p) => p[1]).reduce(math.max);
        if (maxZ < targetHeightRatio * 0.75) {
          continue;
        }

        final residual = _calculateProfileResidual(
          profile,
          dropPoints,
          centerX,
          baselineY,
          scale,
        );
        if (!residual.isFinite) continue;

        final angle =
            _extractContactAngleFromProfile(profile, targetHeightRatio);
        if (!angle.isFinite) continue;

        if (residual < bestResidual) {
          bestResidual = residual;
          bestAngle = angle;
          bestBo = bo;
          bestApex = apex;
        }
      }
    }

    return {
      'residual': bestResidual,
      'angle': bestAngle,
      'bo': bestBo,
      'apex': bestApex,
    };
  }

  /// Estimate Bond number from aspect ratio
  static double _estimateBondNumber(double aspectRatio) {
    // Empirical relationship: higher aspect ratio → lower Bond number
    if (aspectRatio > 1.5) return 0.1; // near spherical
    if (aspectRatio > 1.0) return 0.5;
    if (aspectRatio > 0.5) return 1.0;
    return 2.0; // very flat
  }

  /// Extract contact angle from theoretical profile
  static double _extractContactAngleFromProfile(
      List<List<double>> profile, double targetHeightRatio) {
    if (profile.length < 3) return 90.0;

    final profileByZ = List<List<double>>.from(profile)
      ..sort((a, b) => a[1].compareTo(b[1]));
    final maxZ = profileByZ.map((p) => p[1]).reduce(math.max);
    if (maxZ < 0.01) return 90.0;

    final targetZ = targetHeightRatio.clamp(1e-4, maxZ - 1e-4);
    int idx = -1;
    for (int i = 0; i < profileByZ.length - 1; i++) {
      if (profileByZ[i][1] <= targetZ && targetZ <= profileByZ[i + 1][1]) {
        idx = i;
        break;
      }
    }
    if (idx < 0) {
      idx = profileByZ.length - 2;
    }

    final i1 = math.max(0, idx - 1);
    final i2 = math.min(profileByZ.length - 1, idx + 2);
    double dx = profileByZ[i2][0] - profileByZ[i1][0];
    double dz = profileByZ[i2][1] - profileByZ[i1][1];
    if (dx.abs() < 1e-10 && dz.abs() < 1e-10) return 90.0;

    // Contact angle = atan(dz/dx) relative to baseline
    double slopeAngle = math.atan2(dz.abs(), dx.abs()) * 180.0 / math.pi;
    double contactAngle = 90.0 + slopeAngle;

    return math.max(0.0, math.min(180.0, contactAngle));
  }

  /// Calculate RMS residual between profile and experimental points
  static double _calculateProfileResidual(
      List<List<double>> profile,
      List<math.Point<double>> expPoints,
      double centerX,
      double baselineY,
      double scale) {
    final stats = _calculateProfileResidualStats(
      profile,
      expPoints,
      centerX,
      baselineY,
      scale,
    );
    return stats['rms'] ?? double.infinity;
  }

  static Map<String, double> _calculateProfileResidualStats(
    List<List<double>> profile,
    List<math.Point<double>> expPoints,
    double centerX,
    double baselineY,
    double scale,
  ) {
    if (profile.isEmpty || expPoints.isEmpty || scale <= 0) {
      return {'rms': double.infinity, 'ss_res': double.infinity, 'count': 0.0};
    }

    final profileByZ = List<List<double>>.from(profile)
      ..sort((a, b) => a[1].compareTo(b[1]));
    final minZ = profileByZ.first[1];
    final maxZ = profileByZ.last[1];

    double sumSq = 0.0;
    int count = 0;
    for (final exp in expPoints) {
      final expX = (exp.x - centerX).abs() / scale;
      final expZ = (baselineY - exp.y) / scale;

      if (!expX.isFinite || !expZ.isFinite || expZ < minZ || expZ > maxZ) {
        continue;
      }

      final predX = _interpolateXAtZ(profileByZ, expZ);
      if (!predX.isFinite) continue;
      final dx = predX - expX;
      sumSq += dx * dx;
      count++;
    }

    if (count == 0) {
      return {'rms': double.infinity, 'ss_res': double.infinity, 'count': 0.0};
    }
    return {
      'rms': math.sqrt(sumSq / count),
      'ss_res': sumSq,
      'count': count.toDouble(),
    };
  }

  static double _interpolateXAtZ(List<List<double>> profileByZ, double z) {
    int lo = 0;
    int hi = profileByZ.length - 1;
    if (z < profileByZ[lo][1] || z > profileByZ[hi][1]) return double.nan;

    while (hi - lo > 1) {
      final mid = (lo + hi) ~/ 2;
      if (profileByZ[mid][1] <= z) {
        lo = mid;
      } else {
        hi = mid;
      }
    }

    final z0 = profileByZ[lo][1];
    final z1 = profileByZ[hi][1];
    final x0 = profileByZ[lo][0];
    final x1 = profileByZ[hi][0];
    if ((z1 - z0).abs() < 1e-12) return (x0 + x1) / 2.0;
    final t = (z - z0) / (z1 - z0);
    return x0 * (1.0 - t) + x1 * t;
  }
}
