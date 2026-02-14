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

  /// Calculate R² for circle fit
  static double _calculateCircleRSquared(
      List<double> xs, List<double> ys, double cx, double cy, double r) {
    int n = xs.length;
    if (n < 3 || !r.isFinite || r <= 0) return 0.0;

    // For circular-arc data, classical variance-based R² is unstable because
    // radial distances have very low spread. Use normalized radial RMSE instead.
    double sumSqResidual = 0.0;
    for (int i = 0; i < n; i++) {
      final dist = math.sqrt(math.pow(xs[i] - cx, 2) + math.pow(ys[i] - cy, 2));
      final err = dist - r;
      sumSqResidual += err * err;
    }

    final rmse = math.sqrt(sumSqResidual / n);
    final normalizedRmse = rmse / math.max(1.0, r.abs());
    final rSq = math.exp(-25.0 * normalizedRmse * normalizedRmse);

    return math.max(0.0, math.min(1.0, rSq));
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

      // Find eigenvector for positive eigenvalue (power iteration)
      List<double> a1 = _powerIteration(constraintInvM);

      // Get a2 = T * a1
      List<double> a2 = [0.0, 0.0, 0.0];
      for (int i = 0; i < 3; i++) {
        for (int j = 0; j < 3; j++) {
          a2[i] += t[i][j] * a1[j];
        }
      }

      // Conic coefficients: [A, B, C, D, E, F]
      double aCoeff = a1[0], bCoeff = a1[1], cConic = a1[2];
      double dCoeff = a2[0], eCoeff = a2[1], fCoeff = a2[2];

      // Convert back from normalized coordinates
      aCoeff = aCoeff / (scale * scale);
      bCoeff = bCoeff / (scale * scale);
      cConic = cConic / (scale * scale);
      dCoeff = dCoeff / scale -
          2.0 * aCoeff * meanX / scale -
          bCoeff * meanY / scale;
      eCoeff = eCoeff / scale -
          2.0 * cConic * meanY / scale -
          bCoeff * meanX / scale;
      fCoeff = fCoeff +
          aCoeff * meanX * meanX +
          bCoeff * meanX * meanY +
          cConic * meanY * meanY -
          dCoeff * meanX -
          eCoeff * meanY;

      // Extract ellipse parameters from conic form
      var params = _conicToEllipse(
        aCoeff,
        bCoeff,
        cConic,
        dCoeff,
        eCoeff,
        fCoeff,
      );

      // Calculate R² for ellipse fit
      double rSquared = _calculateEllipseRSquared(
          xs, ys, params[0], params[1], params[2], params[3], params[4]);

      return [params[0], params[1], params[2], params[3], params[4], rSquared];
    } catch (e) {
      // Fallback to circle fit
      var circle = circleFit(xs, ys);
      return [circle[0], circle[1], circle[2], circle[2], 0.0, circle[3]];
    }
  }

  /// Convert conic form Ax² + Bxy + Cy² + Dx + Ey + F = 0 to ellipse parameters
  static List<double> _conicToEllipse(double aCoeff, double bCoeff,
      double cCoeff, double dCoeff, double eCoeff, double fCoeff) {
    // Center
    double denom = bCoeff * bCoeff - 4.0 * aCoeff * cCoeff;
    if (denom.abs() < 1e-12) denom = 1e-12;

    double cx = (2.0 * cCoeff * dCoeff - bCoeff * eCoeff) / (-denom);
    double cy = (2.0 * aCoeff * eCoeff - bCoeff * dCoeff) / (-denom);

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

  /// Calculate R² for ellipse fit
  static double _calculateEllipseRSquared(List<double> xs, List<double> ys,
      double cx, double cy, double a, double b, double theta) {
    int n = xs.length;
    if (n < 5 || a <= 0 || b <= 0) return 0.0;

    double cosT = math.cos(-theta);
    double sinT = math.sin(-theta);

    List<double> distances = [];
    for (int i = 0; i < n; i++) {
      // Rotate point to ellipse coordinate system
      double dx = xs[i] - cx;
      double dy = ys[i] - cy;
      double xr = dx * cosT - dy * sinT;
      double yr = dx * sinT + dy * cosT;

      // Distance from ellipse (approximate using scaling)
      double t = math.atan2(yr / b, xr / a);
      double ex = a * math.cos(t);
      double ey = b * math.sin(t);
      distances.add(math.sqrt(math.pow(xr - ex, 2) + math.pow(yr - ey, 2)));
    }

    double ssRes = 0.0;
    for (var d in distances) {
      ssRes += d * d;
    }

    // For a perfect fit, all distances should be zero
    // Use modified R² based on normalized residuals
    double avgRadius = (a + b) / 2.0;
    double normalizedRes = ssRes / (n * avgRadius * avgRadius);
    double rSq = math.exp(-normalizedRes * 10); // Exponential decay

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

    // Find point on ellipse closest to contact point
    // Using parametric form: x = a*cos(t), y = b*sin(t)
    double t = math.atan2(yr * a, xr * b);

    // Tangent at this point: dx/dt = -a*sin(t), dy/dt = b*cos(t)
    double dxdt = -a * math.sin(t);
    double dydt = b * math.cos(t);

    // Rotate tangent back
    double tanX = dxdt * math.cos(theta) - dydt * math.sin(theta);
    double tanY = dxdt * math.sin(theta) + dydt * math.cos(theta);

    // Angle of tangent with respect to horizontal
    double tangentAngle = math.atan2(-tanY, tanX) * 180.0 / math.pi;

    // Contact angle
    double contactAngle;
    if (isLeftSide) {
      contactAngle = 180.0 - tangentAngle;
    } else {
      contactAngle = tangentAngle;
    }

    return math.max(0.0, math.min(180.0, contactAngle));
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
          // Favor points close to the contact region for tangent estimation.
          weights.add(math.exp(-radialDistance / 28.0));
        } else {
          weights.add(1.0);
        }
      }

      int maxDegree = math.min(5, degree);
      int fitDegree = math.min(maxDegree, points.length - 2);
      fitDegree = math.max(2, fitDegree);

      final fit = _fitWeightedPolynomialNormalized(
        independent,
        dependent,
        weights,
        fitDegree,
      );
      final coeffs = fit['coeffs']! as List<double>;
      double xMean = fit['x_mean']! as double;
      double xScale = fit['x_scale']! as double;
      double fitRSquared = fit['r_squared']! as double;

      double contactIndependent = fitXasFunctionOfY ? contactY : contactX;
      double normalizedContact = (contactIndependent - xMean) / xScale;
      double slopeLocal =
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

      double angleRad = math.atan(dyDx.abs());
      double angleDeg = angleRad * 180.0 / math.pi;
      bool isInteriorAngle =
          (isLeftSide && dyDx > 0) || (!isLeftSide && dyDx < 0);

      double finalAngle = isInteriorAngle ? angleDeg : 180.0 - angleDeg;
      finalAngle = math.max(0.0, math.min(180.0, finalAngle));

      return {
        'angle': finalAngle,
        'r_squared': fitRSquared,
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
