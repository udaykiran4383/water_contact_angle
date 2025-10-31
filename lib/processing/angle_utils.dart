import 'dart:math' as math;

/// Result class for circle fitting
class CircleFitResult {
  final double centerX;
  final double centerY;
  final double radius;

  CircleFitResult({
    required this.centerX,
    required this.centerY,
    required this.radius,
  });

  /// Convert to List<double> for compatibility
  List<double> toList() => [centerX, centerY, radius];
}

/// Result class for angle calculation
class AngleResult {
  final double angle;
  final double slope;
  final double intercept;

  AngleResult({
    required this.angle,
    required this.slope,
    required this.intercept,
  });
}

/// Unified angle utilities for contact angle measurement
class AngleUtils {
  /// Fit circle to droplet contour using least squares (Kåsa method)
  /// Returns single consistent radius (average of all points)
  /// Returns List<double> [cx, cy, radius] for compatibility with image_processor
  static List<double> circleFit(List<double> xs, List<double> ys) {
    if (xs.length < 3 || ys.length < 3) {
      return [0.0, 0.0, 0.0];
    }

    int n = xs.length;
    double sumX = 0, sumY = 0, sumX2 = 0, sumY2 = 0;
    double sumXY = 0, sumX3 = 0, sumY3 = 0, sumX2Y = 0, sumXY2 = 0;

    for (int i = 0; i < n; i++) {
      double x = xs[i];
      double y = ys[i];
      sumX += x;
      sumY += y;
      sumX2 += x * x;
      sumY2 += y * y;
      sumXY += x * y;
      sumX3 += x * x * x;
      sumY3 += y * y * y;
      sumX2Y += x * x * y;
      sumXY2 += x * y * y;
    }

    double A = n * sumX2 - sumX * sumX;
    double B = n * sumXY - sumX * sumY;
    double C = n * sumY2 - sumY * sumY;
    double D = 0.5 * (n * sumX3 + n * sumXY2 - sumX * sumX2 - sumX * sumY2);
    double E = 0.5 * (n * sumX2Y + n * sumY3 - sumY * sumX2 - sumY * sumY2);

    double denom = A * C - B * B;
    if (denom.abs() < 1e-10) {
      return [0.0, 0.0, 0.0];
    }

    double centerX = (D * C - B * E) / denom;
    double centerY = (A * E - B * D) / denom;

    // This ensures ONE consistent radius value, not different values per side
    double radiusSum = 0;
    for (int i = 0; i < n; i++) {
      double dx = xs[i] - centerX;
      double dy = ys[i] - centerY;
      radiusSum += math.sqrt(dx * dx + dy * dy);
    }
    double radius = radiusSum / n;

    if (!radius.isFinite || radius <= 0) {
      return [0.0, 0.0, 0.0];
    }

    return [centerX, centerY, radius];
  }

  /// Calculate contact angle from circle geometry
  /// Fixed tangent calculation at baseline contact points
  static double calculateCircleAngle(List<double> circle, double baselineY) {
    double cx = circle[0], cy = circle[1], r = circle[2];
    
    if (r == 0 || !r.isFinite) return 0;

    // Distance from circle center to baseline
    double h = baselineY - cy;

    // Check if circle intersects baseline
    if (h.abs() >= r) {
      return 0;
    }

    // Calculate contact points where circle meets baseline
    // Circle: (x - cx)² + (y - cy)² = r²
    // At baseline: (x - cx)² + h² = r²
    double discriminant = r * r - h * h;
    if (discriminant < 0) return 0;

    double sqrtDisc = math.sqrt(discriminant);
    double leftContactX = cx - sqrtDisc;
    double rightContactX = cx + sqrtDisc;

    // Radius vector at left contact: (leftContactX - cx, baselineY - cy) = (-sqrtDisc, h)
    // Tangent perpendicular to radius: slope = -(-sqrtDisc) / h = sqrtDisc / h
    double leftSlope = sqrtDisc / (h + 1e-8);
    
    // Radius vector at right contact: (rightContactX - cx, baselineY - cy) = (sqrtDisc, h)
    // Tangent perpendicular to radius: slope = -(sqrtDisc) / h = -sqrtDisc / h
    double rightSlope = -sqrtDisc / (h + 1e-8);

    // Convert slope to contact angle
    double leftAngle = _slopeToContactAngle(leftSlope, true);
    double rightAngle = _slopeToContactAngle(rightSlope, false);

    // Return average angle
    double avgAngle = (leftAngle + rightAngle) / 2.0;
    return math.max(0.0, math.min(180.0, avgAngle));
  }

  /// Fixed slope to contact angle conversion
  /// Interior contact angle is measured from the baseline upward
  /// For a tangent line with slope m, the angle from horizontal is atan(|m|)
  /// Interior contact angle = 180° - angle_from_horizontal for left side
  /// Interior contact angle = angle_from_horizontal for right side
  static double _slopeToContactAngle(double slope, bool isLeftSide) {
    if (!slope.isFinite) return 90.0;
    
    // Angle from horizontal (always positive)
    double angleFromHorizontal = math.atan(slope.abs()) * 180.0 / math.pi;
    
    // Interior contact angle measured from baseline
    // Left side: angle increases as we go up-left (180° - angle_from_horizontal)
    // Right side: angle increases as we go up-right (angle_from_horizontal)
    double contactAngle = isLeftSide 
        ? 180.0 - angleFromHorizontal 
        : angleFromHorizontal;
    
    return math.max(0.0, math.min(180.0, contactAngle));
  }

  /// Fit polynomial to contour and calculate angle at contact point
  /// Improved to ensure tangent is drawn exactly at baseline
  static Map<String, double> polynomialAngle(
    List<math.Point<double>> points,
    double contactX,
    double baselineY,
    bool isLeftSide,
  ) {
    if (points.length < 4) {
      return {'angle': 90.0, 'slope': 0.0, 'intercept': 0.0};
    }

    try {
      // Extract coordinates
      List<double> xs = points.map((p) => p.x).toList();
      List<double> ys = points.map((p) => p.y).toList();

      double minX = xs.reduce(math.min);
      double maxX = xs.reduce(math.max);
      double minY = ys.reduce(math.min);
      double maxY = ys.reduce(math.max);

      double deltaX = maxX - minX;
      double deltaY = maxY - minY;

      // Decide whether to fit x(y) or y(x) based on contour orientation
      bool fitXasFunctionOfY = deltaY > 1.2 * deltaX;

      List<double> independent = [];
      List<double> dependent = [];

      for (int i = 0; i < points.length; i++) {
        double x = xs[i];
        double y = ys[i];
        if (fitXasFunctionOfY) {
          independent.add(y);
          dependent.add(x);
        } else {
          independent.add(x);
          dependent.add(y);
        }
      }

      // Fit cubic polynomial
      List<double> coeffs = _polynomialFit(independent, dependent, 3);

      // Calculate slope at contact point
      double contactIndependent = fitXasFunctionOfY ? baselineY : contactX;
      
      double b = coeffs.length > 1 ? coeffs[1] : 0.0;
      double c = coeffs.length > 2 ? coeffs[2] : 0.0;
      double d = coeffs.length > 3 ? coeffs[3] : 0.0;

      double slopeIndependent = b + 2.0 * c * contactIndependent + 3.0 * d * contactIndependent * contactIndependent;

      double dy_dx;
      if (fitXasFunctionOfY) {
        dy_dx = 1.0 / (slopeIndependent + 1e-8);
      } else {
        dy_dx = slopeIndependent;
      }

      double finalAngle = _slopeToContactAngle(dy_dx, isLeftSide);
      return {'angle': finalAngle, 'slope': dy_dx, 'intercept': 0.0};
    } catch (e) {
      return {'angle': 90.0, 'slope': 0.0, 'intercept': 0.0};
    }
  }

  /// Fit polynomial using least squares method
  /// Solves normal equations for polynomial coefficients
  static List<double> _polynomialFit(List<double> x, List<double> y, int degree) {
    int n = x.length;
    if (n < degree + 1) return List.filled(degree + 1, 0.0);

    // Build Vandermonde matrix and solve normal equations
    List<List<double>> A = List.generate(degree + 1, (_) => List.filled(degree + 1, 0.0));
    List<double> b = List.filled(degree + 1, 0.0);

    for (int i = 0; i <= degree; i++) {
      for (int j = 0; j <= degree; j++) {
        double sum = 0;
        for (int k = 0; k < n; k++) {
          sum += math.pow(x[k], i + j).toDouble();
        }
        A[i][j] = sum;
      }
      double sum = 0;
      for (int k = 0; k < n; k++) {
        sum += y[k] * math.pow(x[k], i).toDouble();
      }
      b[i] = sum;
    }

    // Solve using Gaussian elimination
    return _gaussianElimination(A, b);
  }

  /// Gaussian elimination for solving linear systems
  /// Improved numerical stability with partial pivoting
  static List<double> _gaussianElimination(List<List<double>> A, List<double> b) {
    int n = A.length;
    List<List<double>> aug = List.generate(n, (i) => [...A[i], b[i]]);

    // Forward elimination with partial pivoting
    for (int i = 0; i < n; i++) {
      // Find pivot
      int maxRow = i;
      for (int k = i + 1; k < n; k++) {
        if (aug[k][i].abs() > aug[maxRow][i].abs()) {
          maxRow = k;
        }
      }

      // Swap rows
      var temp = aug[i];
      aug[i] = aug[maxRow];
      aug[maxRow] = temp;

      // Check for singular matrix
      if (aug[i][i].abs() < 1e-10) {
        return List.filled(n, 0.0);
      }

      // Eliminate column
      for (int k = i + 1; k < n; k++) {
        double factor = aug[k][i] / aug[i][i];
        for (int j = i; j <= n; j++) {
          aug[k][j] -= factor * aug[i][j];
        }
      }
    }

    // Back substitution
    List<double> x = List.filled(n, 0.0);
    for (int i = n - 1; i >= 0; i--) {
      x[i] = aug[i][n];
      for (int j = i + 1; j < n; j++) {
        x[i] -= aug[i][j] * x[j];
      }
      x[i] /= aug[i][i];
    }

    return x;
  }

  /// Get circle arc points constrained to above baseline
  /// Only shows the arc portion that's relevant for contact angle
  static List<math.Point<double>> getConstrainedCircleArc(
    List<double> circle,
    double baselineY,
    {int numPoints = 100}
  ) {
    List<math.Point<double>> arcPoints = [];
    
    double cx = circle[0], cy = circle[1], r = circle[2];
    if (r == 0 || !r.isFinite) return arcPoints;

    // Find contact points where circle meets baseline
    double h = baselineY - cy;
    if (h.abs() >= r) return arcPoints;

    double discriminant = r * r - h * h;
    if (discriminant < 0) return arcPoints;

    double sqrtDisc = math.sqrt(discriminant);
    double leftContactX = cx - sqrtDisc;
    double rightContactX = cx + sqrtDisc;

    // Calculate angles for contact points
    double leftAngle = math.atan2(baselineY - cy, leftContactX - cx);
    double rightAngle = math.atan2(baselineY - cy, rightContactX - cx);

    // Ensure we go counterclockwise from left to right
    if (rightAngle < leftAngle) rightAngle += 2 * math.pi;

    // Generate arc points from left contact to right contact (above baseline)
    for (int i = 0; i <= numPoints; i++) {
      double t = i / numPoints;
      double angle = leftAngle + t * (rightAngle - leftAngle);
      double x = cx + r * math.cos(angle);
      double y = cy + r * math.sin(angle);

      // Only include points above baseline
      if (y <= baselineY + 1.0) {
        arcPoints.add(math.Point(x, y));
      }
    }

    return arcPoints;
  }

  /// Get tangent line at exact baseline contact point
  /// Ensures tangent starts and ends at correct positions
  static Map<String, double> getTangentLine(
    double contactX,
    double slope,
    double baselineY,
    double lineLength,
  ) {
    // Normalize direction vector
    double dx = 1.0;
    double dy = slope;
    double len = math.sqrt(dx * dx + dy * dy);
    if (len < 1e-6 || !len.isFinite) {
      dx = 1.0;
      dy = 0.0;
      len = 1.0;
    }
    double dx_norm = dx / len;
    double dy_norm = dy / len;

    double half = lineLength / 2.0;
    double startX = contactX - dx_norm * half;
    double startY = baselineY - dy_norm * half;
    double endX = contactX + dx_norm * half;
    double endY = baselineY + dy_norm * half;

    return {
      'startX': startX,
      'startY': startY,
      'endX': endX,
      'endY': endY,
      'contactX': contactX,
      'contactY': baselineY,
    };
  }

  /// Validate contact angle measurement
  static bool isValidAngle(double angle) {
    return angle > 0 && angle < 180 && angle.isFinite;
  }

  /// Calculate measurement confidence (0-1)
  static double calculateConfidence(
    List<double> xs,
    List<double> ys,
    double baselineY,
  ) {
    if (xs.isEmpty) return 0;

    // Check contour span
    double minX = xs.reduce((a, b) => a < b ? a : b);
    double maxX = xs.reduce((a, b) => a > b ? a : b);
    double span = maxX - minX;

    // Check baseline proximity
    int nearBaseline = 0;
    for (double y in ys) {
      if ((y - baselineY).abs() < 5) {
        nearBaseline++;
      }
    }

    double baselineProximity = nearBaseline / ys.length;
    double spanConfidence = math.min(1.0, span / 100);
    double confidence = (spanConfidence + baselineProximity) / 2;

    return confidence;
  }

  /// Get circle-baseline intersection points (contact points)
  /// Added method to find exact contact points where circle meets baseline
  static List<math.Point<double>> getCircleBaselineIntersections(
    List<double> circle,
    double baselineY,
  ) {
    List<math.Point<double>> intersections = [];
    
    double cx = circle[0], cy = circle[1], r = circle[2];
    if (r == 0 || !r.isFinite) return intersections;

    // Distance from circle center to baseline
    double h = baselineY - cy;

    // Check if circle intersects baseline
    if (h.abs() >= r) return intersections;

    double discriminant = r * r - h * h;
    if (discriminant < 0) return intersections;

    double sqrtDisc = math.sqrt(discriminant);
    double leftContactX = cx - sqrtDisc;
    double rightContactX = cx + sqrtDisc;

    intersections.add(math.Point(leftContactX, baselineY));
    intersections.add(math.Point(rightContactX, baselineY));

    return intersections;
  }

  /// Fixed tangent slope calculation at circle-baseline contact point
  /// Tangent is perpendicular to the radius vector at the contact point
  static double getTangentSlopeAtContact(
    List<double> circle,
    double contactX,
    double baselineY,
  ) {
    double cx = circle[0], cy = circle[1], r = circle[2];
    
    if (r == 0 || !r.isFinite) return 0.0;

    // Vector from center to contact point (radius vector)
    double radiusX = contactX - cx;
    double radiusY = baselineY - cy;

    // Tangent is perpendicular to radius
    // If radius vector is (rx, ry), perpendicular vector is (-ry, rx)
    // Radius slope = ry/rx, so tangent slope = -rx/ry (perpendicular)
    if (radiusY.abs() < 1e-8) {
      return 0.0; // Horizontal radius -> vertical tangent (infinite slope)
    }

    // Tangent slope = -radiusX / radiusY (perpendicular to radius)
    double tangentSlope = -radiusX / radiusY;
    return tangentSlope;
  }
}
