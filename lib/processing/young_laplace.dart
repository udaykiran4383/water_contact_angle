// lib/processing/young_laplace.dart
import 'dart:math' as math;

/// Axisymmetric Drop Shape Analysis (ADSA) based on the Young–Laplace equation.
///
/// This is the reference method for sessile-drop contact-angle metrology. The
/// drop meridian profile is the solution of the Bashforth–Adams form of the
/// Young–Laplace equation, written in dimensionless arc length s (scaled by the
/// apex radius of curvature b):
///
///   dx/ds   = cos(phi)
///   dz/ds   = sin(phi)
///   dphi/ds = 2 - beta*z - sin(phi)/x
///
/// where:
///   x, z   : dimensionless coordinates (x outward, z downward from the apex),
///   phi    : tangent angle measured from the horizontal (0 at the apex),
///   beta   : Bond number = Δρ·g·b² / γ  (the only shape parameter),
///   b      : apex radius of curvature (pixels) — the physical length scale.
///
/// The fit minimises the true geometric (orthogonal) distance from every
/// detected contour point to the theoretical meridian, over the parameter
/// vector p = [beta, b, x0, z0] (apex position x0,z0 in pixels). Optimisation
/// uses a multi-start Nelder–Mead simplex with robust (trimmed) residuals. The
/// contact angle is read directly as phi at the baseline crossing of the
/// best-fit profile — no linear interpolation of the raw data.
class YoungLaplaceSolver {
  // Physical constants (SI) used only for the *absolute* Bond number helper.
  static const double _defaultSurfaceTension = 0.0728; // N/m, water @20°C
  static const double _defaultDensityDiff = 998.0; // kg/m³ (water-air)
  static const double _gravity = 9.81; // m/s²

  /// Absolute physical Bond number Bo = Δρ·g·R² / γ (R in metres).
  static double bondNumber(double radiusM, {double? gamma, double? deltaRho}) {
    gamma ??= _defaultSurfaceTension;
    deltaRho ??= _defaultDensityDiff;
    return (deltaRho * _gravity * radiusM * radiusM) / gamma;
  }

  // --- ODE integration ----------------------------------------------------

  /// Integrate the dimensionless Young–Laplace profile from the apex with a
  /// fixed-step RK4 integrator. The step is small relative to the unit apex
  /// curvature, giving local error ~O(ds⁵) ≈ 1e-9 — well below pixel noise.
  ///
  /// Integration proceeds until z reaches [zStop] (plus a margin), the tangent
  /// turns past π, or the step budget is exhausted. Returns parallel lists of
  /// the right-flank profile (xs ≥ 0), heights zs and tangent angles phis.
  static _Profile _integrate(double beta, double zStop) {
    const double ds = 0.02;
    const int maxSteps = 1200;

    final xs = <double>[0.0];
    final zs = <double>[0.0];
    final phis = <double>[0.0];

    // Apex series start to step off the x→0 singularity cleanly.
    double x = ds;
    double z = 0.5 * ds * ds; // z ≈ s²/2 near the apex (dphi/ds ≈ 1)
    double phi = ds; // phi ≈ s near the apex
    xs.add(x);
    zs.add(z);
    phis.add(phi);

    final zTarget = zStop + 0.15;
    for (int i = 0; i < maxSteps; i++) {
      final k1 = _deriv(x, z, phi, beta);
      final k2 = _deriv(x + 0.5 * ds * k1[0], z + 0.5 * ds * k1[1],
          phi + 0.5 * ds * k1[2], beta);
      final k3 = _deriv(x + 0.5 * ds * k2[0], z + 0.5 * ds * k2[1],
          phi + 0.5 * ds * k2[2], beta);
      final k4 = _deriv(
          x + ds * k3[0], z + ds * k3[1], phi + ds * k3[2], beta);

      x += (ds / 6.0) * (k1[0] + 2 * k2[0] + 2 * k3[0] + k4[0]);
      z += (ds / 6.0) * (k1[1] + 2 * k2[1] + 2 * k3[1] + k4[1]);
      phi += (ds / 6.0) * (k1[2] + 2 * k2[2] + 2 * k3[2] + k4[2]);

      if (!x.isFinite || !z.isFinite || !phi.isFinite || x <= 0) break;
      xs.add(x);
      zs.add(z);
      phis.add(phi);

      if (z >= zTarget || phi >= math.pi) break;
    }

    return _Profile(xs, zs, phis);
  }

  static List<double> _deriv(double x, double z, double phi, double beta) {
    final dxds = math.cos(phi);
    final dzds = math.sin(phi);
    // Near the apex sin(phi)/x → dphi/ds, giving dphi/ds = (2 - beta·z)/2.
    final double dphids;
    if (x < 1e-6) {
      dphids = (2.0 - beta * z) / 2.0;
    } else {
      dphids = 2.0 - beta * z - math.sin(phi) / x;
    }
    return [dxds, dzds, dphids];
  }

  // --- Public fit ---------------------------------------------------------

  /// Fit the Young–Laplace profile to [contour] (points above [baselineY],
  /// in a baseline-aligned frame where the baseline is horizontal).
  ///
  /// Returns:
  ///   contact_angle  : fitted contact angle (deg), read at the baseline,
  ///   angle_left/right: same value (the model is axisymmetric),
  ///   apex_curvature : dimensionless apex radius (=1 by construction kept for
  ///                    API compatibility) — the physical scale is bond-coupled,
  ///   bond_number    : fitted shape Bond number beta,
  ///   residual       : normalised RMS orthogonal residual (fraction of b),
  ///   r_squared      : geometric coefficient of determination.
  static Map<String, double> fitContour(
      List<math.Point<double>> contour, double baselineY,
      {double? dropRadiusPixels}) {
    final fail = {
      'contact_angle': double.nan,
      'angle_left': double.nan,
      'angle_right': double.nan,
      'apex_curvature': double.nan,
      'bond_number': double.nan,
      'residual': double.infinity,
      'r_squared': 0.0,
    };
    if (contour.length < 10) return fail;

    // Drop points strictly above the baseline.
    var pts = contour.where((p) => p.y < baselineY - 1.0).toList();
    if (pts.length < 8) return fail;

    // Subsample to bound the optimisation cost while preserving both flanks.
    pts = _subsample(pts, 180);

    final minY = pts.map((p) => p.y).reduce(math.min);
    final leftX = pts.map((p) => p.x).reduce(math.min);
    final rightX = pts.map((p) => p.x).reduce(math.max);
    final dropHeight = baselineY - minY;
    final dropWidth = rightX - leftX;
    if (dropWidth <= 1e-6 || dropHeight <= 1e-6) return fail;

    // Apex x from the upper cap (least contaminated by the contact line).
    final apexBand =
        pts.where((p) => p.y <= minY + 0.18 * dropHeight).toList();
    final x0Init = apexBand.isNotEmpty
        ? apexBand.map((p) => p.x).reduce((a, b) => a + b) / apexBand.length
        : 0.5 * (leftX + rightX);
    final z0Init = minY;
    final bInit = (dropRadiusPixels ?? dropWidth / 2.0).clamp(5.0, 1e6);

    final ex = pts.map((p) => p.x).toList(growable: false);
    final ey = pts.map((p) => p.y).toList(growable: false);

    // Multi-start over physically-spaced Bond seeds to avoid local minima.
    const betaSeeds = [0.03, 0.15, 0.5, 1.2, 3.0];
    List<double>? best;
    double bestCost = double.infinity;
    for (final beta0 in betaSeeds) {
      final start = [math.log(beta0), bInit, x0Init, z0Init];
      final step = [0.5, 0.08 * bInit, 0.04 * bInit, 0.04 * bInit];
      final res = _nelderMead(
        start,
        step,
        (p) => _cost(p, ex, ey, baselineY),
        maxIter: 160,
      );
      if (res.cost < bestCost) {
        bestCost = res.cost;
        best = res.params;
      }
    }
    if (best == null || !bestCost.isFinite) return fail;

    final beta = math.exp(best[0]).clamp(1e-4, 50.0);
    final b = best[1];
    final x0 = best[2];
    final z0 = best[3];
    if (!(b.isFinite && b > 0)) return fail;

    final zContact = (baselineY - z0) / b;
    final profile = _integrate(beta, math.max(zContact, 0.05));
    final theta = _angleAtHeight(profile, zContact);
    if (!theta.isFinite) return fail;

    // Goodness of fit: geometric R² from orthogonal residuals.
    final stats = _residualStats(profile, ex, ey, b, x0, z0);
    final rmsPx = stats.rms;
    final residualNorm = (rmsPx / b);

    double ssTot = 0.0;
    final cxData = ex.reduce((a, c) => a + c) / ex.length;
    final cyData = ey.reduce((a, c) => a + c) / ey.length;
    for (int i = 0; i < ex.length; i++) {
      final dx = ex[i] - cxData;
      final dy = ey[i] - cyData;
      ssTot += dx * dx + dy * dy;
    }
    double rSquared =
        ssTot > 1e-9 ? 1.0 - (stats.ssRes / ssTot) : 0.0;
    rSquared = rSquared.clamp(0.0, 1.0);

    return {
      'contact_angle': theta,
      'angle_left': theta,
      'angle_right': theta,
      'apex_curvature': 1.0,
      'bond_number': beta,
      'residual': residualNorm.isFinite ? residualNorm : double.infinity,
      'r_squared': rSquared,
    };
  }

  // --- Objective ----------------------------------------------------------

  /// Robust (trimmed) sum of squared orthogonal residuals in pixel² units,
  /// normalised so the optimiser sees a well-scaled cost.
  static double _cost(
      List<double> p, List<double> ex, List<double> ey, double baselineY) {
    final beta = math.exp(p[0]);
    final b = p[1];
    final x0 = p[2];
    final z0 = p[3];
    if (!beta.isFinite || beta <= 0 || beta > 60.0) return 1e18;
    if (!b.isFinite || b < 3.0 || b > 5e5) return 1e18;

    // Required dimensionless height to cover the lowest data point.
    double maxZneed = 0.0;
    for (int i = 0; i < ey.length; i++) {
      final zz = (ey[i] - z0) / b;
      if (zz > maxZneed) maxZneed = zz;
    }
    if (maxZneed <= 0) return 1e18;

    final profile = _integrate(beta, maxZneed);
    if (profile.xs.length < 8) return 1e18;
    // Reject profiles that cannot reach the data extent (under-curved).
    if (profile.zs.last < maxZneed * 0.85) return 1e17;

    final stats = _residualStats(profile, ex, ey, b, x0, z0);
    return stats.cost;
  }

  // --- Residual / nearest-distance machinery ------------------------------

  static _ResStats _residualStats(_Profile prof, List<double> ex,
      List<double> ey, double b, double x0, double z0) {
    final n = ex.length;
    if (n == 0 || b <= 0) {
      return _ResStats(double.infinity, double.infinity, double.infinity);
    }
    // Trim distance cap (dimensionless): residuals beyond 0.30·b are outliers
    // and contribute a constant, bounding their leverage (robust fitting).
    const double cap = 0.30;
    const double cap2 = cap * cap;

    double ssRes = 0.0; // squared geometric residual (px²) for R²
    double cost = 0.0; // robust trimmed cost (dimensionless²)
    for (int i = 0; i < n; i++) {
      final qx = (ex[i] - x0).abs() / b; // fold to right flank by symmetry
      final qz = (ey[i] - z0) / b;
      final d2 = _distToProfile2(prof, qx, qz); // dimensionless²
      ssRes += d2 * b * b;
      cost += d2 < cap2 ? d2 : cap2;
    }
    final rms = math.sqrt(ssRes / n);
    return _ResStats(cost / n, ssRes, rms);
  }

  /// Minimum squared distance (dimensionless) from query (qx,qz) to the
  /// right-flank meridian polyline.
  static double _distToProfile2(_Profile prof, double qx, double qz) {
    final xs = prof.xs;
    final zs = prof.zs;
    double best = double.infinity;
    for (int i = 0; i < xs.length - 1; i++) {
      final d2 = _segDist2(qx, qz, xs[i], zs[i], xs[i + 1], zs[i + 1]);
      if (d2 < best) best = d2;
    }
    return best;
  }

  static double _segDist2(double px, double pz, double ax, double az,
      double bx, double bz) {
    final dx = bx - ax;
    final dz = bz - az;
    final len2 = dx * dx + dz * dz;
    double t = len2 > 1e-18 ? ((px - ax) * dx + (pz - az) * dz) / len2 : 0.0;
    if (t < 0.0) t = 0.0;
    if (t > 1.0) t = 1.0;
    final cx = ax + t * dx;
    final cz = az + t * dz;
    final ex = px - cx;
    final ez = pz - cz;
    return ex * ex + ez * ez;
  }

  /// Tangent angle phi (deg) at dimensionless height z, by interpolation on
  /// the monotone-z profile. This is the contact angle at the baseline.
  static double _angleAtHeight(_Profile prof, double z) {
    final zs = prof.zs;
    final phis = prof.phis;
    if (zs.length < 2) return double.nan;
    final zClamped = z.clamp(zs.first, zs.last);
    int idx = zs.length - 2;
    for (int i = 0; i < zs.length - 1; i++) {
      if (zs[i] <= zClamped && zClamped <= zs[i + 1]) {
        idx = i;
        break;
      }
    }
    final z0 = zs[idx];
    final z1 = zs[idx + 1];
    final p0 = phis[idx];
    final p1 = phis[idx + 1];
    final t = (z1 - z0).abs() < 1e-12 ? 0.0 : (zClamped - z0) / (z1 - z0);
    final phi = p0 + (p1 - p0) * t;
    return (phi * 180.0 / math.pi).clamp(0.0, 180.0);
  }

  // --- Nelder–Mead simplex optimiser --------------------------------------

  static _NMResult _nelderMead(
    List<double> start,
    List<double> initialStep,
    double Function(List<double>) f, {
    int maxIter = 200,
    double tol = 1e-7,
  }) {
    final n = start.length;
    const alpha = 1.0, gamma = 2.0, rho = 0.5, sigma = 0.5;

    // Build initial simplex.
    final simplex = <List<double>>[];
    final fvals = <double>[];
    simplex.add(List<double>.from(start));
    fvals.add(f(start));
    for (int i = 0; i < n; i++) {
      final pt = List<double>.from(start);
      pt[i] += initialStep[i];
      simplex.add(pt);
      fvals.add(f(pt));
    }

    List<int> order() {
      final idx = List<int>.generate(n + 1, (i) => i);
      idx.sort((a, b) => fvals[a].compareTo(fvals[b]));
      return idx;
    }

    for (int iter = 0; iter < maxIter; iter++) {
      final idx = order();
      final best = idx.first;
      final worst = idx.last;
      final secondWorst = idx[idx.length - 2];

      // Convergence: spread of function values is tiny.
      if ((fvals[worst] - fvals[best]).abs() <=
          tol * (fvals[best].abs() + tol)) {
        break;
      }

      // Centroid of all but the worst.
      final centroid = List<double>.filled(n, 0.0);
      for (int i = 0; i < simplex.length; i++) {
        if (i == worst) continue;
        for (int j = 0; j < n; j++) {
          centroid[j] += simplex[i][j];
        }
      }
      for (int j = 0; j < n; j++) {
        centroid[j] /= n;
      }

      List<double> reflect(double coef) => List<double>.generate(
          n, (j) => centroid[j] + coef * (centroid[j] - simplex[worst][j]));

      final xr = reflect(alpha);
      final fr = f(xr);

      if (fr < fvals[best]) {
        // Expansion.
        final xe = reflect(gamma);
        final fe = f(xe);
        if (fe < fr) {
          simplex[worst] = xe;
          fvals[worst] = fe;
        } else {
          simplex[worst] = xr;
          fvals[worst] = fr;
        }
      } else if (fr < fvals[secondWorst]) {
        simplex[worst] = xr;
        fvals[worst] = fr;
      } else {
        // Contraction.
        final xc = reflect(rho);
        final fc = f(xc);
        if (fc < fvals[worst]) {
          simplex[worst] = xc;
          fvals[worst] = fc;
        } else {
          // Shrink toward the best.
          for (int i = 0; i < simplex.length; i++) {
            if (i == best) continue;
            for (int j = 0; j < n; j++) {
              simplex[i][j] =
                  simplex[best][j] + sigma * (simplex[i][j] - simplex[best][j]);
            }
            fvals[i] = f(simplex[i]);
          }
        }
      }
    }

    final idx = order();
    return _NMResult(simplex[idx.first], fvals[idx.first]);
  }

  // --- helpers ------------------------------------------------------------

  static List<math.Point<double>> _subsample(
      List<math.Point<double>> pts, int target) {
    if (pts.length <= target) return pts;
    final step = pts.length / target;
    final out = <math.Point<double>>[];
    for (double i = 0; i < pts.length; i += step) {
      out.add(pts[i.floor()]);
    }
    return out;
  }
}

class _Profile {
  final List<double> xs;
  final List<double> zs;
  final List<double> phis;
  _Profile(this.xs, this.zs, this.phis);
}

class _ResStats {
  final double cost; // robust mean trimmed dimensionless cost
  final double ssRes; // sum of squared geometric residuals (px²)
  final double rms; // RMS geometric residual (px)
  _ResStats(this.cost, this.ssRes, this.rms);
}

class _NMResult {
  final List<double> params;
  final double cost;
  _NMResult(this.params, this.cost);
}
