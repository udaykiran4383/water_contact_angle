// lib/processing/angle_utils.dart
import 'dart:math' as math;

/// Utility methods for fitting and contact-angle calculation.
/// Uses dart:math Point (math.Point) to avoid binding-specific types.
class AngleUtils {
  /// Circle fitting using Kåsa least-squares method
  /// Fits points to equation: (x - cx)² + (y - cy)² = r²
  /// Returns [cx, cy, r, rSquared]
  static List<double> circleFit(List<double> xs, List<double> ys) {
    int n = xs.length;
    if (n < 3) throw Exception('Need at least 3 points for circle fitting');

    try {
      // Normalize coordinates to improve conditioning with large images.
      final meanX = xs.reduce((a, b) => a + b) / n;
      final meanY = ys.reduce((a, b) => a + b) / n;
      double scale = 0.0;
      for (int i = 0; i < n; i++) {
        scale = math.max(
          scale,
          math.sqrt(
            math.pow(xs[i] - meanX, 2) + math.pow(ys[i] - meanY, 2),
          ),
        );
      }
      if (scale < 1e-8) throw Exception('Degenerate point cloud');

      final xn = xs.map((x) => (x - meanX) / scale).toList();
      final yn = ys.map((y) => (y - meanY) / scale).toList();

      // Solve 2*cx*x + 2*cy*y + c = x^2 + y^2 in least-squares sense.
      final ata = List.generate(3, (_) => List<double>.filled(3, 0.0));
      final atb = List<double>.filled(3, 0.0);

      for (int i = 0; i < n; i++) {
        final row = [2.0 * xn[i], 2.0 * yn[i], 1.0];
        final rhs = xn[i] * xn[i] + yn[i] * yn[i];
        for (int r = 0; r < 3; r++) {
          atb[r] += row[r] * rhs;
          for (int c = 0; c < 3; c++) {
            ata[r][c] += row[r] * row[c];
          }
        }
      }

      final sol = solveLinearSystem(ata, atb);
      final cxNorm = sol[0];
      final cyNorm = sol[1];
      final cNorm = sol[2];
      final rNormSq = cxNorm * cxNorm + cyNorm * cyNorm + cNorm;
      if (rNormSq <= 1e-12 || !rNormSq.isFinite) {
        throw Exception('Invalid fitted radius');
      }

      final cx = cxNorm * scale + meanX;
      final cy = cyNorm * scale + meanY;
      final r = math.sqrt(rNormSq) * scale;

      if (!(r.isFinite && r > 0)) throw Exception('Invalid circle radius: $r');

      // Calculate R² (goodness of fit)
      double rSquared = _calculateCircleRSquared(xs, ys, cx, cy, r);

      return [cx, cy, r, rSquared];
    } catch (e) {
      // fallback: bounding-box-based approximate circle
      double minX = xs.reduce(math.min), maxX = xs.reduce(math.max);
      double minY = ys.reduce(math.min), maxY = ys.reduce(math.max);
      double cx = (minX + maxX) / 2.0;
      double cy = (minY + maxY) / 2.0;
      double r = math.sqrt(
          math.pow((maxX - minX) / 2.0, 2) + math.pow((maxY - minY) / 2.0, 2));
      return [cx, cy, r, 0.5]; // low R² for fallback
    }
  }

  /// Geometric R² for the circle fit: orthogonal (radial) residuals against the
  /// total spatial variance of the points about their centroid.
  ///
  ///   R² = 1 − Σ(dᵢ − r)² / Σ‖pᵢ − p̄‖²
  ///
  /// The previous implementation used a *radial-variance* ratio
  /// (SS_tot = Σ(dᵢ − d̄)²). For a clean, near-perfect arc every dᵢ ≈ r, so that
  /// SS_tot collapses toward zero and the ratio becomes numerically ill-posed —
  /// excellent circle fits scored ~0 and were rejected by the R² gate. That is
  /// exactly backwards: the cleaner the circle, the more it was penalised. The
  /// geometric form below is well-conditioned (SS_tot is the point cloud's
  /// spread, which is large for any real arc) and is directly comparable to the
  /// ellipse and Young–Laplace geometric R², so the ensemble weights all methods
  /// on the same scale.
  static double _calculateCircleRSquared(
      List<double> xs, List<double> ys, double cx, double cy, double r) {
    int n = xs.length;
    if (n < 3 || !r.isFinite || r <= 0) return 0.0;

    double meanX = 0.0, meanY = 0.0;
    for (int i = 0; i < n; i++) {
      meanX += xs[i];
      meanY += ys[i];
    }
    meanX /= n;
    meanY /= n;

    double ssRes = 0.0, ssTot = 0.0;
    for (int i = 0; i < n; i++) {
      final d = math.sqrt((xs[i] - cx) * (xs[i] - cx) +
          (ys[i] - cy) * (ys[i] - cy));
      final rr = d - r;
      ssRes += rr * rr;
      final dx = xs[i] - meanX, dy = ys[i] - meanY;
      ssTot += dx * dx + dy * dy;
    }

    if (ssTot < 1e-12) return 0.0;
    final rSq = 1.0 - (ssRes / ssTot);
    return rSq.clamp(0.0, 1.0);
  }

  /// Ellipse fitting using Direct Least Squares method (Fitzgibbon et al.)
  /// Fits points to: Ax² + Bxy + Cy² + Dx + Ey + F = 0
  /// with constraint 4AC - B² = 1 (ensures ellipse)
  /// Returns [cx, cy, a, b, theta, rSquared] where:
  ///   cx, cy = center, a = semi-major, b = semi-minor, theta = rotation
  static List<double> ellipseFit(List<double> xs, List<double> ys) {
    int n = xs.length;
    if (n < 5) throw Exception('Need at least 5 points for ellipse fitting');

    // Normalize points to improve numerical stability
    double meanX = xs.reduce((a, b) => a + b) / n;
    double meanY = ys.reduce((a, b) => a + b) / n;
    double scale = 0.0;
    for (int i = 0; i < n; i++) {
      scale +=
          math.sqrt(math.pow(xs[i] - meanX, 2) + math.pow(ys[i] - meanY, 2));
    }
    scale = scale / n;
    if (scale < 1e-10) scale = 1.0;

    List<double> xn = xs.map((x) => (x - meanX) / scale).toList();
    List<double> yn = ys.map((y) => (y - meanY) / scale).toList();

    // Build design matrix D = [x², xy, y², x, y, 1]
    // We use the constraint matrix approach: solve generalized eigenvalue problem
    List<List<double>> s1 = List.generate(3, (_) => List.filled(3, 0.0));
    List<List<double>> s2 = List.generate(3, (_) => List.filled(3, 0.0));
    List<List<double>> s3 = List.generate(3, (_) => List.filled(3, 0.0));

    for (int i = 0; i < n; i++) {
      double x = xn[i], y = yn[i];
      double x2 = x * x, y2 = y * y, xy = x * y;

      // D1 = [x², xy, y²], D2 = [x, y, 1]
      List<double> d1 = [x2, xy, y2];
      List<double> d2 = [x, y, 1.0];

      for (int j = 0; j < 3; j++) {
        for (int k = 0; k < 3; k++) {
          s1[j][k] += d1[j] * d1[k];
          s2[j][k] += d1[j] * d2[k];
          s3[j][k] += d2[j] * d2[k];
        }
      }
    }

    // Constraint matrix C for 4AC - B² = 1
    List<List<double>> constraint = [
      [0.0, 0.0, 2.0],
      [0.0, -1.0, 0.0],
      [2.0, 0.0, 0.0],
    ];

    // Solve using simplified approach: find eigenvector with positive eigenvalue
    try {
      // Compute S3^-1
      var s3Inv = _invert3x3(s3);

      // T = -S3^-1 * S2^T
      var s2T = _transpose3x3(s2);
      var t = _multiply3x3(s3Inv, s2T);
      for (int i = 0; i < 3; i++) {
        for (int j = 0; j < 3; j++) {
          t[i][j] = -t[i][j];
        }
      }

      // M = S1 + S2 * T = C^-1 * M
      var s2TimesT = _multiply3x3(s2, t);
      var m = List.generate(
          3, (i) => List.generate(3, (j) => s1[i][j] + s2TimesT[i][j]));

      // C^-1 * M
      var constraintInv = _invert3x3(constraint);
      var constraintInvM = _multiply3x3(constraintInv, m);

      // Halir–Flusser: the ellipse solution is the eigenvector of C⁻¹M that
      // satisfies the constraint 4AC − B² > 0 (i.e. aᵀ C a > 0). This is NOT in
      // general the dominant eigenvector, so a plain power iteration returns the
      // wrong conic (typically a hyperbola/saddle). Select by the constraint.
      List<double> a1 = _selectEllipseEigenvector(constraintInvM);

      // Get a2 = T * a1
      List<double> a2 = [0.0, 0.0, 0.0];
      for (int i = 0; i < 3; i++) {
        for (int j = 0; j < 3; j++) {
          a2[i] += t[i][j] * a1[j];
        }
      }

      // Conic coefficients in NORMALIZED coordinates: [A, B, C, D, E, F].
      final double aCoeff = a1[0], bCoeff = a1[1], cConic = a1[2];
      final double dCoeff = a2[0], eCoeff = a2[1], fCoeff = a2[2];

      // Extract ellipse geometry in normalized space, then map the parameters
      // (not the raw conic coefficients) back to image coordinates. Denormalizing
      // the conic algebraically is error-prone; transforming center/axes is exact
      // and robust: p = p_n·scale + mean, axes ·= scale, rotation unchanged.
      final pn = _conicToEllipse(
          aCoeff, bCoeff, cConic, dCoeff, eCoeff, fCoeff);
      final cx = pn[0] * scale + meanX;
      final cy = pn[1] * scale + meanY;
      final aAxis = pn[2] * scale;
      final bAxis = pn[3] * scale;
      final theta = pn[4];

      final double rSquared =
          _calculateEllipseRSquared(xs, ys, cx, cy, aAxis, bAxis, theta);

      return [cx, cy, aAxis, bAxis, theta, rSquared];
    } catch (e) {
      // Fallback to circle fit
      var circle = circleFit(xs, ys);
      return [circle[0], circle[1], circle[2], circle[2], 0.0, circle[3]];
    }
  }

  /// Convert conic form Ax² + Bxy + Cy² + Dx + Ey + F = 0 to ellipse parameters
  static List<double> _conicToEllipse(double aCoeff, double bCoeff,
      double cCoeff, double dCoeff, double eCoeff, double fCoeff) {
    // Center of the conic Ax²+Bxy+Cy²+Dx+Ey+F=0:
    //   x_c = (2CD − BE)/(B² − 4AC),  y_c = (2AE − BD)/(B² − 4AC).
    // The previous code divided by −(B²−4AC), reflecting the center through the
    // origin — every derived quantity (semi-axes via fPrime, rotation, R²,
    // contact tangent) was then computed at the wrong center, collapsing the
    // ellipse fit's R² so it was always rejected.
    double denom = bCoeff * bCoeff - 4.0 * aCoeff * cCoeff;
    if (denom.abs() < 1e-12) denom = denom < 0 ? -1e-12 : 1e-12;

    double cx = (2.0 * cCoeff * dCoeff - bCoeff * eCoeff) / denom;
    double cy = (2.0 * aCoeff * eCoeff - bCoeff * dCoeff) / denom;

    // Rotation angle
    double theta = 0.0;
    if (bCoeff.abs() > 1e-10) {
      theta = 0.5 * math.atan2(bCoeff, aCoeff - cCoeff);
    }

    // Semi-axes
    double fPrime = fCoeff +
        aCoeff * cx * cx +
        bCoeff * cx * cy +
        cCoeff * cy * cy +
        dCoeff * cx +
        eCoeff * cy;
    if (fPrime.abs() < 1e-12) fPrime = 1e-12;

    double cos2 = math.cos(theta) * math.cos(theta);
    double sin2 = math.sin(theta) * math.sin(theta);
    double sincos = math.sin(theta) * math.cos(theta);

    double aRot = aCoeff * cos2 + bCoeff * sincos + cCoeff * sin2;
    double cRot = aCoeff * sin2 - bCoeff * sincos + cCoeff * cos2;

    double a2 = -fPrime / aRot;
    double b2 = -fPrime / cRot;

    double a = a2 > 0 ? math.sqrt(a2) : 1.0;
    double b = b2 > 0 ? math.sqrt(b2) : 1.0;

    // Ensure a >= b (a is semi-major)
    if (b > a) {
      double tmp = a;
      a = b;
      b = tmp;
      theta += math.pi / 2.0;
    }

    return [cx, cy, a, b, theta];
  }

  /// Standard geometric R² for the ellipse fit:
  ///   R² = 1 − SS_res / SS_tot
  /// where SS_res is the sum of squared *orthogonal* (true closest-point)
  /// distances from each data point to the ellipse, and SS_tot is the total
  /// squared spread of the data about its centroid. This is the conventional
  /// coefficient of determination (replacing an ad-hoc exp(−res) surrogate
  /// that systematically inflated apparent fit quality).
  static double _calculateEllipseRSquared(List<double> xs, List<double> ys,
      double cx, double cy, double a, double b, double theta) {
    int n = xs.length;
    if (n < 5 || a <= 0 || b <= 0) return 0.0;

    final double cosT = math.cos(-theta);
    final double sinT = math.sin(-theta);

    // Data centroid (image frame) for SS_tot.
    double mx = 0.0, my = 0.0;
    for (int i = 0; i < n; i++) {
      mx += xs[i];
      my += ys[i];
    }
    mx /= n;
    my /= n;

    double ssRes = 0.0, ssTot = 0.0;
    for (int i = 0; i < n; i++) {
      // Rotate point into the ellipse-aligned frame.
      final dx = xs[i] - cx;
      final dy = ys[i] - cy;
      final xr = dx * cosT - dy * sinT;
      final yr = dx * sinT + dy * cosT;

      // True closest point on the ellipse via Newton on the parameter t.
      final t = _closestEllipseParameter(xr, yr, a, b);
      final ex = a * math.cos(t);
      final ey = b * math.sin(t);
      final rdx = xr - ex;
      final rdy = yr - ey;
      ssRes += rdx * rdx + rdy * rdy;

      final tdx = xs[i] - mx;
      final tdy = ys[i] - my;
      ssTot += tdx * tdx + tdy * tdy;
    }

    if (ssTot < 1e-12) return ssRes < 1e-12 ? 1.0 : 0.0;
    final rSq = 1.0 - (ssRes / ssTot);
    return math.max(0.0, math.min(1.0, rSq));
  }

  /// Calculate contact angle from ellipse geometry
  /// More accurate for gravitationally deformed drops
  static double calculateEllipseAngle(List<double> ellipse, double baselineY,
      double contactX, bool isLeftSide) {
    double cx = ellipse[0], cy = ellipse[1];
    double a = ellipse[2], b = ellipse[3];
    double theta = ellipse[4];

    // Transform contact point to ellipse coordinates
    double dx = contactX - cx;
    double dy = baselineY - cy;
    double cosT = math.cos(-theta);
    double sinT = math.sin(-theta);
    double xr = dx * cosT - dy * sinT;
    double yr = dx * sinT + dy * cosT;

    // Find the true closest point on the ellipse by minimizing squared
    // distance in the ellipse frame.
    double t = _closestEllipseParameter(xr, yr, a, b);

    // Tangent at this point: dx/dt = -a*sin(t), dy/dt = b*cos(t)
    double dxdt = -a * math.sin(t);
    double dydt = b * math.cos(t);

    // Rotate tangent back
    double tanX = dxdt * math.cos(theta) - dydt * math.sin(theta);
    double tanY = dxdt * math.sin(theta) + dydt * math.cos(theta);

    return _contactAngleFromTangentVector(tanX, tanY, isLeftSide);
  }

  /// Calculate contact angle from circle geometry.
  /// θ = 180° - α, where cos(α) = (baselineY - cy) / r
  static double calculateCircleAngle(List<double> circle, double baselineY) {
    double cy = circle[1], r = circle[2];
    double h = baselineY - cy; // positive if baseline below center
    double cosAlpha = h / r;
    cosAlpha = math.max(-1.0, math.min(1.0, cosAlpha));
    double alphaRad = math.acos(cosAlpha);
    double alphaDeg = alphaRad * 180.0 / math.pi;
    double contactAngle = 180.0 - alphaDeg;
    return math.max(0.0, math.min(180.0, contactAngle));
  }

  /// Local polynomial fitting for tangent calculation at contact point.
  /// Uses normalized coordinates to reduce numerical conditioning issues.
  static double polynomialAngle(
    List<math.Point<double>> points,
    double contactX,
    double contactY,
    bool isLeftSide, {
    int degree = 4,
    bool useWeighting = true,
  }) {
    return polynomialAngleDetailed(
      points,
      contactX,
      contactY,
      isLeftSide,
      degree: degree,
      useWeighting: useWeighting,
    )['angle']!;
  }

  /// Detailed polynomial-angle estimate with fit quality.
  /// Returns:
  /// - `angle`: contact angle in degrees
  /// - `r_squared`: weighted fit quality
  /// - `used_points`: number of points used in fit
  static Map<String, double> polynomialAngleDetailed(
    List<math.Point<double>> points,
    double contactX,
    double contactY,
    bool isLeftSide, {
    int degree = 4,
    bool useWeighting = true,
    double? contactSpan,
  }) {
    if (points.length < 4) {
      return {
        'angle': 90.0,
        'r_squared': 0.0,
        'used_points': points.length.toDouble(),
      };
    }

    try {
      double minX = points.map((p) => p.x).reduce(math.min);
      double maxX = points.map((p) => p.x).reduce(math.max);
      double minY = points.map((p) => p.y).reduce(math.min);
      double maxY = points.map((p) => p.y).reduce(math.max);

      double deltaX = maxX - minX;
      double deltaY = maxY - minY;
      bool fitXasFunctionOfY = deltaY > 1.2 * deltaX;

      List<double> independent = [];
      List<double> dependent = [];
      List<double> weights = [];
      final radialScale =
          ((contactSpan?.abs() ?? math.max(deltaX, deltaY)) * 0.25)
              .clamp(8.0, 72.0);

      for (final p in points) {
        if (fitXasFunctionOfY) {
          independent.add(p.y);
          dependent.add(p.x);
        } else {
          independent.add(p.x);
          dependent.add(p.y);
        }

        if (useWeighting) {
          double dx = p.x - contactX;
          double dy = p.y - contactY;
          double radialDistance = math.sqrt(dx * dx + dy * dy);
          // Scale the decay with the observed contact span so small drops do not
          // get over-smoothed and large drops do not overfit the contact noise.
          weights.add(math.exp(-radialDistance / radialScale));
        } else {
          weights.add(1.0);
        }
      }

      int maxDegree = math.min(5, degree);
      int fitDegree = math.max(2, math.min(maxDegree, points.length - 2));

      Map<String, double> evaluateFit(int requestedDegree) {
        final fit = _fitWeightedPolynomialNormalized(
          independent,
          dependent,
          weights,
          requestedDegree,
        );
        final coeffs = fit['coeffs']! as List<double>;
        final xMean = fit['x_mean']! as double;
        final xScale = fit['x_scale']! as double;
        final fitRSquared = fit['r_squared']! as double;

        final contactIndependent = fitXasFunctionOfY ? contactY : contactX;
        final normalizedContact = (contactIndependent - xMean) / xScale;
        final slopeLocal =
            _evaluatePolynomialDerivative(coeffs, normalizedContact) / xScale;

        double dyDx;
        if (fitXasFunctionOfY) {
          if (slopeLocal.abs() < 1e-8) {
            dyDx = slopeLocal >= 0 ? 1e8 : -1e8;
          } else {
            dyDx = 1.0 / slopeLocal;
          }
        } else {
          dyDx = slopeLocal;
        }

        return {
          'angle': _contactAngleFromSlope(dyDx, isLeftSide),
          'r_squared': fitRSquared,
          'fit_degree': requestedDegree.toDouble(),
        };
      }

      final lowOrder = evaluateFit(2);
      Map<String, double> chosen = lowOrder;
      if (fitDegree > 2) {
        final highOrder = evaluateFit(fitDegree);
        final lowAngle = lowOrder['angle']!;
        final highAngle = highOrder['angle']!;
        if (!lowAngle.isFinite && highAngle.isFinite) {
          chosen = highOrder;
        } else if (lowAngle.isFinite && highAngle.isFinite) {
          if ((highAngle - lowAngle).abs() <= 3.0) {
            chosen = {
              'angle': (lowAngle + highAngle) * 0.5,
              'r_squared':
                  ((lowOrder['r_squared']! + highOrder['r_squared']!) * 0.5)
                      .clamp(0.0, 1.0),
              'fit_degree': fitDegree.toDouble(),
            };
          } else {
            chosen = lowOrder;
          }
        }
      }

      return {
        'angle': chosen['angle']!,
        'r_squared': chosen['r_squared']!,
        'used_points': points.length.toDouble(),
      };
    } catch (_) {
      return {
        'angle': 90.0,
        'r_squared': 0.0,
        'used_points': points.length.toDouble(),
      };
    }
  }

  /// Robust local tangent estimate using weighted orthogonal regression (PCA).
  ///
  /// This method is less sensitive to global contour contamination and serves as
  /// a reliable fallback when higher-order polynomial fits become unstable.
  ///
  /// Returns:
  /// - `angle`: contact angle in degrees
  /// - `r_squared`: local linearity score (0..1)
  /// - `used_points`: number of points used
  /// - `slope`: tangent slope dy/dx (can be +/-infinity)
  static Map<String, double> localTangentAngleDetailed(
    List<math.Point<double>> points,
    double contactX,
    double contactY,
    bool isLeftSide, {
    int maxPoints = 34,
  }) {
    if (points.length < 4) {
      return {
        'angle': 90.0,
        'r_squared': 0.0,
        'used_points': points.length.toDouble(),
        'slope': double.nan,
      };
    }

    var source = points.where((p) => p.y <= contactY - 0.6).toList();
    if (source.length < 4) {
      source = points.where((p) => p.y <= contactY + 0.2).toList();
    }
    if (source.length < 4) {
      source = points;
    }

    final scored = source.map((p) {
      final dx = p.x - contactX;
      final dy = p.y - contactY;
      final radial = math.sqrt(dx * dx + dy * dy);
      return {'p': p, 'dist': radial};
    }).toList()
      ..sort((a, b) => (a['dist'] as double).compareTo(b['dist'] as double));

    final takeN =
        math.min(maxPoints, math.max(8, (source.length * 0.70).round()));
    final local =
        scored.take(takeN).map((e) => e['p'] as math.Point<double>).toList();
    if (local.length < 4) {
      return {
        'angle': 90.0,
        'r_squared': 0.0,
        'used_points': local.length.toDouble(),
        'slope': double.nan,
      };
    }

    // Weighted centroid around the contact region.
    double wSum = 0.0;
    double meanX = 0.0;
    double meanY = 0.0;
    final weights = <double>[];
    for (final p in local) {
      final dx = p.x - contactX;
      final dy = p.y - contactY;
      final radial = math.sqrt(dx * dx + dy * dy);
      final baselineClearance = (contactY - p.y).clamp(0.0, 18.0);
      final clearanceWeight = 0.55 + 0.45 * (baselineClearance / 18.0);
      final w = math.exp(-radial / 24.0) *
          math.exp(-p.y.abs() / 42.0) *
          clearanceWeight;
      weights.add(w);
      wSum += w;
      meanX += w * p.x;
      meanY += w * p.y;
    }
    if (wSum <= 1e-10) {
      return {
        'angle': 90.0,
        'r_squared': 0.0,
        'used_points': local.length.toDouble(),
        'slope': double.nan,
      };
    }
    meanX /= wSum;
    meanY /= wSum;

    // Weighted covariance matrix.
    double sxx = 0.0;
    double syy = 0.0;
    double sxy = 0.0;
    for (int i = 0; i < local.length; i++) {
      final p = local[i];
      final w = weights[i];
      final dx = p.x - meanX;
      final dy = p.y - meanY;
      sxx += w * dx * dx;
      syy += w * dy * dy;
      sxy += w * dx * dy;
    }
    if (!sxx.isFinite || !syy.isFinite || !sxy.isFinite) {
      return {
        'angle': 90.0,
        'r_squared': 0.0,
        'used_points': local.length.toDouble(),
        'slope': double.nan,
      };
    }

    final trace = sxx + syy;
    final det = sxx * syy - sxy * sxy;
    final disc = ((trace * trace) * 0.25 - det).clamp(0.0, double.infinity);
    final root = math.sqrt(disc);
    final lambda = trace * 0.5 + root; // principal eigenvalue

    double vx;
    double vy;
    if (sxy.abs() > 1e-12) {
      vx = lambda - syy;
      vy = sxy;
    } else if (sxx >= syy) {
      vx = 1.0;
      vy = 0.0;
    } else {
      vx = 0.0;
      vy = 1.0;
    }

    final norm = math.sqrt(vx * vx + vy * vy);
    if (!norm.isFinite || norm <= 1e-12) {
      return {
        'angle': 90.0,
        'r_squared': 0.0,
        'used_points': local.length.toDouble(),
        'slope': double.nan,
      };
    }
    vx /= norm;
    vy /= norm;

    double slope;
    if (vx.abs() < 1e-6) {
      slope = vy >= 0 ? double.infinity : double.negativeInfinity;
    } else {
      slope = vy / vx;
    }

    final finalAngle =
        _contactAngleFromTangentVector(vx, vy, isLeftSide).clamp(0.0, 180.0);

    // Local linearity score using orthogonal residual energy.
    double ssOrth = 0.0;
    double ssTot = 0.0;
    for (int i = 0; i < local.length; i++) {
      final p = local[i];
      final w = weights[i];
      final dx = p.x - meanX;
      final dy = p.y - meanY;
      final orth = (vx * dy - vy * dx);
      ssOrth += w * orth * orth;
      ssTot += w * (dx * dx + dy * dy);
    }
    final rSquared =
        (ssTot > 1e-10) ? (1.0 - (ssOrth / ssTot)).clamp(0.0, 1.0) : 0.0;

    return {
      'angle': finalAngle.toDouble(),
      'r_squared': rSquared.toDouble(),
      'used_points': local.length.toDouble(),
      'slope': slope,
    };
  }

  static Map<String, Object> _fitWeightedPolynomialNormalized(
    List<double> x,
    List<double> y,
    List<double> weights,
    int degree,
  ) {
    int n = x.length;
    int m = degree + 1;
    if (n < m) {
      throw Exception('Need at least $m points for degree $degree polynomial');
    }

    double xMean = x.reduce((a, b) => a + b) / n;
    double maxAbsDeviation = 0.0;
    for (final xi in x) {
      maxAbsDeviation = math.max(maxAbsDeviation, (xi - xMean).abs());
    }
    double xScale = maxAbsDeviation > 1e-8 ? maxAbsDeviation : 1.0;
    List<double> xn = x.map((xi) => (xi - xMean) / xScale).toList();

    double wSum = weights.reduce((a, b) => a + b);
    if (wSum < 1e-10) wSum = 1.0;
    List<double> w = weights.map((wi) => wi / wSum * n).toList();

    List<List<double>> ata = List.generate(m, (_) => List.filled(m, 0.0));
    List<double> aty = List.filled(m, 0.0);

    for (int k = 0; k < n; k++) {
      List<double> basis = List.filled(m, 0.0);
      basis[0] = 1.0;
      for (int i = 1; i < m; i++) {
        basis[i] = basis[i - 1] * xn[k];
      }

      for (int i = 0; i < m; i++) {
        aty[i] += w[k] * basis[i] * y[k];
        for (int j = 0; j < m; j++) {
          ata[i][j] += w[k] * basis[i] * basis[j];
        }
      }
    }

    List<double> coeffs = solveLinearSystem(ata, aty);

    double weightedMeanY = 0.0;
    for (int i = 0; i < n; i++) {
      weightedMeanY += w[i] * y[i];
    }
    weightedMeanY /= n;

    double ssRes = 0.0;
    double ssTot = 0.0;
    for (int i = 0; i < n; i++) {
      double yPred = _evaluatePolynomial(coeffs, xn[i]);
      double err = y[i] - yPred;
      ssRes += w[i] * err * err;
      double centered = y[i] - weightedMeanY;
      ssTot += w[i] * centered * centered;
    }

    double rSquared = ssTot > 1e-12 ? 1.0 - (ssRes / ssTot) : 1.0;
    rSquared = math.max(0.0, math.min(1.0, rSquared));

    return {
      'coeffs': coeffs,
      'x_mean': xMean,
      'x_scale': xScale,
      'r_squared': rSquared,
    };
  }

  static double _evaluatePolynomial(List<double> coeffs, double x) {
    double acc = 0.0;
    double xPow = 1.0;
    for (final c in coeffs) {
      acc += c * xPow;
      xPow *= x;
    }
    return acc;
  }

  static double _evaluatePolynomialDerivative(List<double> coeffs, double x) {
    double acc = 0.0;
    double xPow = 1.0;
    for (int i = 1; i < coeffs.length; i++) {
      acc += i * coeffs[i] * xPow;
      xPow *= x;
    }
    return acc;
  }

  static double _contactAngleFromSlope(double dyDx, bool isLeftSide) {
    if (!dyDx.isFinite) {
      return 90.0;
    }
    return _contactAngleFromTangentVector(1.0, dyDx, isLeftSide);
  }

  static double _contactAngleFromTangentVector(
    double tx,
    double ty,
    bool isLeftSide,
  ) {
    if (!tx.isFinite || !ty.isFinite) {
      return 90.0;
    }

    double vx = tx;
    double vy = ty;

    // In the baseline-aligned frame the droplet lies above the substrate
    // (negative y), so the physically relevant tangent ray must point upward.
    if (vy > 0.0) {
      vx = -vx;
      vy = -vy;
    }

    final norm = math.sqrt(vx * vx + vy * vy);
    if (!norm.isFinite || norm <= 1e-10) {
      return 90.0;
    }
    vx /= norm;
    vy /= norm;

    final substrateX = isLeftSide ? 1.0 : -1.0;
    final dot = (substrateX * vx).clamp(-1.0, 1.0);
    return math.acos(dot) * 180.0 / math.pi;
  }

  static double _closestEllipseParameter(
    double xr,
    double yr,
    double a,
    double b,
  ) {
    double t = math.atan2(yr * a, xr * b);
    for (int iter = 0; iter < 16; iter++) {
      final sinT = math.sin(t);
      final cosT = math.cos(t);
      final f = (b * b - a * a) * sinT * cosT + a * xr * sinT - b * yr * cosT;
      final fp = (b * b - a * a) * (cosT * cosT - sinT * sinT) +
          a * xr * cosT +
          b * yr * sinT;
      if (!f.isFinite || !fp.isFinite || fp.abs() < 1e-10) {
        break;
      }
      final step = (f / fp).clamp(-0.5, 0.5);
      t -= step;
      if (step.abs() < 1e-10) {
        break;
      }
    }
    return t;
  }

  /// Weighted least-squares polynomial fitting
  static List<double> polynomialFitWeighted(
      List<double> x, List<double> y, List<double> weights, int degree) {
    int n = x.length;
    int m = degree + 1;
    if (n < m) {
      throw Exception('Need at least $m points for degree $degree polynomial');
    }

    // Normalize weights
    double wSum = weights.reduce((a, b) => a + b);
    if (wSum < 1e-10) wSum = 1.0;
    List<double> w = weights.map((wi) => wi / wSum * n).toList();

    List<List<double>> ata = List.generate(m, (_) => List.filled(m, 0.0));
    List<double> aty = List.filled(m, 0.0);

    for (int k = 0; k < n; k++) {
      double xPow = 1.0;
      for (int i = 0; i < m; i++) {
        double xi = xPow;
        double yk = y[k];
        aty[i] += w[k] * xi * yk;

        double xPowJ = 1.0;
        for (int j = 0; j < m; j++) {
          ata[i][j] += w[k] * xi * xPowJ;
          xPowJ *= x[k];
        }
        xPow *= x[k];
      }
    }

    return solveLinearSystem(ata, aty);
  }

  /// Calculate polynomial fit R² with given coefficients
  static double polynomialRSquared(
      List<double> x, List<double> y, List<double> coeffs) {
    int n = x.length;
    if (n < 2) return 0.0;

    double meanY = y.reduce((a, b) => a + b) / n;
    double ssRes = 0.0, ssTot = 0.0;

    for (int i = 0; i < n; i++) {
      double yPred = 0.0;
      double xPow = 1.0;
      for (int j = 0; j < coeffs.length; j++) {
        yPred += coeffs[j] * xPow;
        xPow *= x[i];
      }
      ssRes += math.pow(y[i] - yPred, 2);
      ssTot += math.pow(y[i] - meanY, 2);
    }

    if (ssTot < 1e-10) return 1.0;
    return math.max(0.0, math.min(1.0, 1.0 - ssRes / ssTot));
  }

  /// Helper: 3x3 matrix inversion
  static List<List<double>> _invert3x3(List<List<double>> m) {
    double det = m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1]) -
        m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0]) +
        m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0]);

    if (det.abs() < 1e-12) throw Exception('Singular matrix');

    return [
      [
        (m[1][1] * m[2][2] - m[1][2] * m[2][1]) / det,
        (m[0][2] * m[2][1] - m[0][1] * m[2][2]) / det,
        (m[0][1] * m[1][2] - m[0][2] * m[1][1]) / det
      ],
      [
        (m[1][2] * m[2][0] - m[1][0] * m[2][2]) / det,
        (m[0][0] * m[2][2] - m[0][2] * m[2][0]) / det,
        (m[0][2] * m[1][0] - m[0][0] * m[1][2]) / det
      ],
      [
        (m[1][0] * m[2][1] - m[1][1] * m[2][0]) / det,
        (m[0][1] * m[2][0] - m[0][0] * m[2][1]) / det,
        (m[0][0] * m[1][1] - m[0][1] * m[1][0]) / det
      ],
    ];
  }

  /// Helper: 3x3 matrix transpose
  static List<List<double>> _transpose3x3(List<List<double>> m) {
    return [
      [m[0][0], m[1][0], m[2][0]],
      [m[0][1], m[1][1], m[2][1]],
      [m[0][2], m[1][2], m[2][2]],
    ];
  }

  /// Helper: 3x3 matrix multiplication
  static List<List<double>> _multiply3x3(
      List<List<double>> a, List<List<double>> b) {
    var result = List.generate(3, (_) => List.filled(3, 0.0));
    for (int i = 0; i < 3; i++) {
      for (int j = 0; j < 3; j++) {
        for (int k = 0; k < 3; k++) {
          result[i][j] += a[i][k] * b[k][j];
        }
      }
    }
    return result;
  }

  /// Helper: Power iteration to find dominant eigenvector
  static List<double> _powerIteration(List<List<double>> m,
      {int maxIter = 100}) {
    List<double> v = [1.0, 1.0, 1.0];

    for (int iter = 0; iter < maxIter; iter++) {
      // Multiply: v_new = M * v
      List<double> vNew = [0.0, 0.0, 0.0];
      for (int i = 0; i < 3; i++) {
        for (int j = 0; j < 3; j++) {
          vNew[i] += m[i][j] * v[j];
        }
      }

      // Normalize
      double norm = math.sqrt(vNew.map((x) => x * x).reduce((a, b) => a + b));
      if (norm < 1e-12) break;

      v = vNew.map((x) => x / norm).toList();
    }

    return v;
  }

  /// Select the Halir–Flusser ellipse eigenvector of the 3×3 matrix [m]:
  /// among the (up to three) real eigenvectors, the ellipse solution is the one
  /// satisfying the constraint 4·a₀·a₂ − a₁² > 0. Computes eigenvalues from the
  /// characteristic cubic and each eigenvector as the null space of (M − λI).
  static List<double> _selectEllipseEigenvector(List<List<double>> m) {
    final eigvals = _eigenvalues3x3(m);
    List<double>? best;
    double bestConstraint = 0.0;
    for (final lambda in eigvals) {
      final v = _nullVector3x3(m, lambda);
      if (v == null) continue;
      final constraint = 4.0 * v[0] * v[2] - v[1] * v[1];
      if (constraint > 0 && constraint > bestConstraint) {
        bestConstraint = constraint;
        best = v;
      }
    }
    // Fallback (degenerate data): dominant eigenvector, as before.
    return best ?? _powerIteration(m);
  }

  /// Real eigenvalues of a general 3×3 matrix via its characteristic cubic
  /// det(M − λI) = 0  ⇒  λ³ − c₂λ² + c₁λ − c₀ = 0, solved in closed form.
  static List<double> _eigenvalues3x3(List<List<double>> m) {
    final a = m[0][0], b = m[0][1], c = m[0][2];
    final d = m[1][0], e = m[1][1], f = m[1][2];
    final g = m[2][0], h = m[2][1], i = m[2][2];
    // Characteristic polynomial: λ³ − trace·λ² + c1·λ − det = 0.
    final trace = a + e + i;
    final c1 = (a * e - b * d) + (a * i - c * g) + (e * i - f * h);
    final det = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g);
    // Monic form λ³ + a₂λ² + a₁λ + a₀ with a₂=−trace, a₁=c1, a₀=−det.
    // Depress to t³ + p·t + q = 0 via λ = t − a₂/3 = t + trace/3.
    final shift = trace / 3.0;
    final p = c1 - trace * trace / 3.0;
    final q =
        -2.0 * trace * trace * trace / 27.0 + trace * c1 / 3.0 - det;
    final roots = <double>[];
    final disc = (q * q) / 4.0 + (p * p * p) / 27.0;
    if (disc > 1e-12) {
      // One real root (Cardano).
      final sq = math.sqrt(disc);
      roots.add(_cbrt(-q / 2.0 + sq) + _cbrt(-q / 2.0 - sq) + shift);
    } else {
      // Three real roots (trigonometric form).
      final r = math.sqrt(-(p * p * p) / 27.0);
      final phi =
          r.abs() < 1e-18 ? 0.0 : math.acos((-q / 2.0 / r).clamp(-1.0, 1.0));
      final mBase = 2.0 * math.sqrt(-p / 3.0);
      for (int k = 0; k < 3; k++) {
        roots.add(mBase * math.cos((phi + 2.0 * math.pi * k) / 3.0) + shift);
      }
    }
    return roots;
  }

  static double _cbrt(double x) =>
      x < 0 ? -math.pow(-x, 1.0 / 3.0).toDouble() : math.pow(x, 1.0 / 3.0)
          .toDouble();

  /// Unit null-space vector of (M − λI) for an eigenvalue [lambda], via the
  /// largest-magnitude cross product of the rows of (M − λI).
  static List<double>? _nullVector3x3(List<List<double>> m, double lambda) {
    final a = [
      [m[0][0] - lambda, m[0][1], m[0][2]],
      [m[1][0], m[1][1] - lambda, m[1][2]],
      [m[2][0], m[2][1], m[2][2] - lambda],
    ];
    List<double> cross(List<double> u, List<double> v) => [
          u[1] * v[2] - u[2] * v[1],
          u[2] * v[0] - u[0] * v[2],
          u[0] * v[1] - u[1] * v[0],
        ];
    final candidates = [
      cross(a[0], a[1]),
      cross(a[0], a[2]),
      cross(a[1], a[2]),
    ];
    List<double>? best;
    double bestNorm = 0.0;
    for (final v in candidates) {
      final n = math.sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
      if (n > bestNorm) {
        bestNorm = n;
        best = [v[0] / n, v[1] / n, v[2] / n];
      }
    }
    return bestNorm > 1e-9 ? best : null;
  }

  /// Solve linear system Ax = b via Gaussian elimination with partial pivoting
  /// Made public for use by other utilities
  static List<double> solveLinearSystem(List<List<double>> A, List<double> b) {
    int n = A.length;
    if (A.any((row) => row.length != n) || b.length != n) {
      throw Exception('Matrix dimension mismatch');
    }

    List<List<double>> M = List.generate(n, (i) => List.from(A[i])..add(b[i]));

    for (int i = 0; i < n; i++) {
      int pivot = i;
      for (int r = i + 1; r < n; r++) {
        if (M[r][i].abs() > M[pivot][i].abs()) pivot = r;
      }
      if (pivot != i) {
        var tmp = M[i];
        M[i] = M[pivot];
        M[pivot] = tmp;
      }
      if (M[i][i].abs() < 1e-12) throw Exception('Singular matrix');

      for (int r = i + 1; r < n; r++) {
        double factor = M[r][i] / M[i][i];
        for (int c = i; c <= n; c++) {
          M[r][c] -= factor * M[i][c];
        }
      }
    }

    List<double> x = List.filled(n, 0.0);
    for (int i = n - 1; i >= 0; i--) {
      double s = 0.0;
      for (int j = i + 1; j < n; j++) {
        s += M[i][j] * x[j];
      }
      x[i] = (M[i][n] - s) / M[i][i];
    }
    return x;
  }
}
