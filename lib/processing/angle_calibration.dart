import 'dart:math' as math;

/// Instrument-level angle calibration profile.
///
/// Supports two correction modes:
///
/// 1. **Affine** (legacy): `theta_cal = slope * theta_raw + intercept`
///    Bounded by [maxCorrectionDeg] to prevent uncontrolled extrapolation.
///
/// 2. **Piecewise-linear**: linearly interpolates between sorted (raw, ref)
///    knot pairs for non-linear systematic bias correction.  Falls back to
///    affine when knots are absent.
class AngleCalibrationProfile {
  final double slope;
  final double intercept;
  final double maxCorrectionDeg;
  final double residualStdDeg;
  final String source;

  /// Sorted raw-angle knots for piecewise-linear interpolation.
  final List<double>? knots;

  /// Corresponding corrected-angle values at each knot.
  final List<double>? values;

  const AngleCalibrationProfile({
    required this.slope,
    required this.intercept,
    this.maxCorrectionDeg = 25.0,
    this.residualStdDeg = 0.0,
    this.source = 'manual_profile',
    this.knots,
    this.values,
  });

  /// Whether this profile uses piecewise-linear interpolation.
  bool get isPiecewiseLinear =>
      knots != null &&
      values != null &&
      knots!.length >= 2 &&
      knots!.length == values!.length;

  factory AngleCalibrationProfile.identity({String source = 'identity'}) {
    return AngleCalibrationProfile(
      slope: 1.0,
      intercept: 0.0,
      maxCorrectionDeg: 0.0,
      residualStdDeg: 0.0,
      source: source,
    );
  }

  /// Create a piecewise-linear profile from sorted (raw, reference) pairs.
  factory AngleCalibrationProfile.piecewiseLinear({
    required List<double> knots,
    required List<double> values,
    double maxCorrectionDeg = 25.0,
    double residualStdDeg = 0.0,
    String source = 'piecewise_linear',
    double slope = 1.0,
    double intercept = 0.0,
  }) {
    assert(knots.length == values.length && knots.length >= 2);
    return AngleCalibrationProfile(
      slope: slope,
      intercept: intercept,
      maxCorrectionDeg: maxCorrectionDeg,
      residualStdDeg: residualStdDeg,
      source: source,
      knots: List<double>.unmodifiable(knots),
      values: List<double>.unmodifiable(values),
    );
  }

  factory AngleCalibrationProfile.fromJson(Map<String, dynamic> json) {
    final slope = (json['slope'] as num?)?.toDouble() ?? 1.0;
    final intercept = (json['intercept'] as num?)?.toDouble() ?? 0.0;
    final maxCorrectionDeg =
        (json['max_correction_deg'] as num?)?.toDouble() ?? 25.0;
    final residualStdDeg =
        (json['residual_std_deg'] as num?)?.toDouble() ?? 0.0;
    final source = (json['source'] as String?) ?? 'profile_json';

    List<double>? knots;
    List<double>? values;
    if (json['knots'] is List && json['values'] is List) {
      knots = (json['knots'] as List)
          .map((e) => (e as num).toDouble())
          .toList(growable: false);
      values = (json['values'] as List)
          .map((e) => (e as num).toDouble())
          .toList(growable: false);
      if (knots.length != values.length || knots.length < 2) {
        knots = null;
        values = null;
      }
    }

    return AngleCalibrationProfile(
      slope: slope,
      intercept: intercept,
      maxCorrectionDeg: maxCorrectionDeg,
      residualStdDeg: residualStdDeg,
      source: source,
      knots: knots,
      values: values,
    );
  }

  Map<String, dynamic> toJson() {
    final map = <String, dynamic>{
      'model': isPiecewiseLinear ? 'piecewise_linear_v1' : 'affine_bounded_v1',
      'slope': slope,
      'intercept': intercept,
      'max_correction_deg': maxCorrectionDeg,
      'residual_std_deg': residualStdDeg,
      'source': source,
    };
    if (knots != null && values != null) {
      map['knots'] = knots;
      map['values'] = values;
    }
    return map;
  }

  /// Apply the calibration to a raw measured angle.
  ///
  /// Uses piecewise-linear interpolation when available, otherwise affine.
  /// Result is always clamped to [0, 180]°.
  double apply(double rawAngleDeg) {
    if (!rawAngleDeg.isFinite) return rawAngleDeg;
    final raw = rawAngleDeg.clamp(0.0, 180.0).toDouble();

    if (isPiecewiseLinear) {
      return _applyPiecewiseLinear(raw);
    }
    return _applyAffine(raw);
  }

  double _applyAffine(double raw) {
    final target = slope * raw + intercept;
    double corrected = target;
    if (maxCorrectionDeg > 0) {
      final delta = (target - raw).clamp(-maxCorrectionDeg, maxCorrectionDeg);
      corrected = raw + delta;
    }
    return math.max(0.0, math.min(180.0, corrected));
  }

  double _applyPiecewiseLinear(double raw) {
    final k = knots!;
    final v = values!;

    // Below first knot: extrapolate with first segment slope, bounded.
    if (raw <= k.first) {
      final segSlope =
          k.length >= 2 ? (v[1] - v[0]) / (k[1] - k[0]) : 1.0;
      final target = v.first + segSlope * (raw - k.first);
      return _bounded(raw, target);
    }

    // Above last knot: extrapolate with last segment slope, bounded.
    if (raw >= k.last) {
      final n = k.length;
      final segSlope =
          n >= 2 ? (v[n - 1] - v[n - 2]) / (k[n - 1] - k[n - 2]) : 1.0;
      final target = v.last + segSlope * (raw - k.last);
      return _bounded(raw, target);
    }

    // Interior: linear interpolation between bracketing knots.
    for (int i = 0; i < k.length - 1; i++) {
      if (raw >= k[i] && raw <= k[i + 1]) {
        final t = (raw - k[i]) / (k[i + 1] - k[i]);
        final target = v[i] + t * (v[i + 1] - v[i]);
        return _bounded(raw, target);
      }
    }

    // Fallback (shouldn't reach here).
    return _applyAffine(raw);
  }

  /// Bound the correction so it never exceeds [maxCorrectionDeg].
  double _bounded(double raw, double target) {
    double corrected = target;
    if (maxCorrectionDeg > 0) {
      final delta =
          (target - raw).clamp(-maxCorrectionDeg, maxCorrectionDeg);
      corrected = raw + delta;
    }
    return math.max(0.0, math.min(180.0, corrected));
  }
}
