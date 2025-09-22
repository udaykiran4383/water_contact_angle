// lib/processing/angle_utils.dart
import 'dart:math' as math;

/// Utility methods for fitting and contact-angle calculation.
/// Uses dart:math Point (math.Point) to avoid binding-specific types.
class AngleUtils {
  /// Circle fitting using Kåsa least-squares method
  /// Fits points to equation: (x - cx)² + (y - cy)² = r²
  static List<double> circleFit(List<double> xs, List<double> ys) {
    int n = xs.length;
    if (n < 3) throw Exception('Need at least 3 points for circle fitting');

    // Initialize sums
    double sumX = 0, sumY = 0, sumX2 = 0, sumY2 = 0, sumXY = 0;
    double sumX3 = 0, sumY3 = 0, sumX2Y = 0, sumXY2 = 0;
    double sumZ = 0, sumXZ = 0, sumYZ = 0;

    for (int i = 0; i < n; i++) {
      double x = xs[i], y = ys[i];
      double x2 = x * x, y2 = y * y;
      double z = x2 + y2;
      sumX += x;
      sumY += y;
      sumX2 += x2;
      sumY2 += y2;
      sumXY += x * y;
      sumX3 += x * x2;
      sumY3 += y * y2;
      sumX2Y += x2 * y;
      sumXY2 += x * y2;
      sumZ += z;
      sumXZ += x * z;
      sumYZ += y * z;
    }

    // Build normal equations matrix A and vector b
    List<List<double>> A = [
      [sumX2, sumXY, sumX],
      [sumXY, sumY2, sumY],
      [sumX, sumY, n.toDouble()],
    ];
    List<double> b = [sumXZ, sumYZ, sumZ];

    try {
      List<double> sol = _solveLinearSystem(A, b);
      double a = sol[0], bParam = sol[1], c = sol[2];

      double cx = -a / 2.0;
      double cy = -bParam / 2.0;
      double r = math.sqrt((a * a / 4.0) + (bParam * bParam / 4.0) - c);

      if (!(r.isFinite && r > 0)) throw Exception('Invalid circle radius: $r');

      return [cx, cy, r];
    } catch (e) {
      // fallback: bounding-box-based approximate circle
      double minX = xs.reduce(math.min), maxX = xs.reduce(math.max);
      double minY = ys.reduce(math.min), maxY = ys.reduce(math.max);
      double cx = (minX + maxX) / 2.0;
      double cy = (minY + maxY) / 2.0;
      double r = math.sqrt(math.pow((maxX - minX) / 2.0, 2) + math.pow((maxY - minY) / 2.0, 2));
      return [cx, cy, r];
    }
  }

  /// Calculate contact angle from circle geometry.
  /// θ = 180° - α, where cos(α) = (baselineY - cy) / r
  static double calculateCircleAngle(List<double> circle, double baselineY) {
    double cx = circle[0], cy = circle[1], r = circle[2];
    double h = baselineY - cy; // positive if baseline below center
    double cosAlpha = h / r;
    cosAlpha = math.max(-1.0, math.min(1.0, cosAlpha));
    double alphaRad = math.acos(cosAlpha);
    double alphaDeg = alphaRad * 180.0 / math.pi;
    double contactAngle = 180.0 - alphaDeg;
    return math.max(0.0, math.min(180.0, contactAngle));
  }

  /// Local polynomial fitting for tangent calculation at contact point.
  /// Accepts dart:math Points.
  static double polynomialAngle(List<math.Point> points, double contactX, double contactY, bool isLeftSide) {
    if (points.length < 4) {
      // Not enough points -> return default 90°
      return 90.0;
    }

    try {
      double minX = points.map((p) => p.x.toDouble()).reduce(math.min);
      double maxX = points.map((p) => p.x.toDouble()).reduce(math.max);
      double minY = points.map((p) => p.y.toDouble()).reduce(math.min);
      double maxY = points.map((p) => p.y.toDouble()).reduce(math.max);

      double deltaX = maxX - minX;
      double deltaY = maxY - minY;

      bool fitXasFunctionOfY = deltaY > 1.2 * deltaX;

      List<double> independent = [];
      List<double> dependent = [];

      for (var p in points) {
        double x = p.x.toDouble();
        double y = p.y.toDouble();
        if (fitXasFunctionOfY) {
          independent.add(y);
          dependent.add(x);
        } else {
          independent.add(x);
          dependent.add(y);
        }
      }

      // cubic polynomial fit
      List<double> coeffs = _polynomialFit(independent, dependent, 3);

      double contactIndependent = fitXasFunctionOfY ? contactY : contactX;

      double b = coeffs.length > 1 ? coeffs[1] : 0.0;
      double c = coeffs.length > 2 ? coeffs[2] : 0.0;
      double d = coeffs.length > 3 ? coeffs[3] : 0.0;

      double slope = b + 2.0 * c * contactIndependent + 3.0 * d * contactIndependent * contactIndependent;

      double dy_dx;
      if (fitXasFunctionOfY) {
        dy_dx = 1.0 / (slope + 1e-8);
      } else {
        dy_dx = slope;
      }

      double angleRad = math.atan(dy_dx.abs());
      double angleDeg = angleRad * 180.0 / math.pi;

      bool isInteriorAngle = (isLeftSide && dy_dx > 0) || (!isLeftSide && dy_dx < 0);

      double finalAngle = isInteriorAngle ? angleDeg : 180.0 - angleDeg;
      finalAngle = math.max(0.0, math.min(180.0, finalAngle));
      return finalAngle;
    } catch (e) {
      return 90.0;
    }
  }

  /// Least-squares polynomial fitting using normal equations
  static List<double> _polynomialFit(List<double> x, List<double> y, int degree) {
    int n = x.length;
    int m = degree + 1;
    if (n < m) throw Exception('Need at least $m points for degree $degree polynomial');

    List<List<double>> ATA = List.generate(m, (_) => List.filled(m, 0.0));
    List<double> ATy = List.filled(m, 0.0);

    for (int k = 0; k < n; k++) {
      double xPow = 1.0;
      for (int i = 0; i < m; i++) {
        double xi = xPow;
        double yk = y[k];
        ATy[i] += xi * yk;

        double xPowJ = 1.0;
        for (int j = 0; j < m; j++) {
          ATA[i][j] += xi * xPowJ;
          xPowJ *= x[k];
        }
        xPow *= x[k];
      }
    }

    return _solveLinearSystem(ATA, ATy);
  }

  /// Solve linear system Ax = b via Gaussian elimination with partial pivoting
  static List<double> _solveLinearSystem(List<List<double>> A, List<double> b) {
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
        for (int c = i; c <= n; c++) M[r][c] -= factor * M[i][c];
      }
    }

    List<double> x = List.filled(n, 0.0);
    for (int i = n - 1; i >= 0; i--) {
      double s = 0.0;
      for (int j = i + 1; j < n; j++) s += M[i][j] * x[j];
      x[i] = (M[i][n] - s) / M[i][i];
    }
    return x;
  }
}
