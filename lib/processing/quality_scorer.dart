// lib/processing/quality_scorer.dart
import 'dart:math' as math;

/// Quality report containing individual scores and overall assessment.
class QualityReport {
  /// Overall quality score (0.0 = poor, 1.0 = excellent).
  final double overallScore;

  /// Individual component scores (0.0–1.0 each).
  final double baselineConfidence;
  final double slopeStability;
  final double blurScore;
  final double contourSmoothness;
  final double symmetry;
  final double interFrameVariance;

  /// Warning messages for the user.
  final List<String> warnings;

  const QualityReport({
    required this.overallScore,
    required this.baselineConfidence,
    required this.slopeStability,
    required this.blurScore,
    required this.contourSmoothness,
    required this.symmetry,
    required this.interFrameVariance,
    this.warnings = const [],
  });

  Map<String, dynamic> toMap() => {
        'overall_score': overallScore,
        'baseline_confidence': baselineConfidence,
        'slope_stability': slopeStability,
        'blur_score': blurScore,
        'contour_smoothness': contourSmoothness,
        'symmetry': symmetry,
        'inter_frame_variance': interFrameVariance,
        'warnings': warnings,
      };

  @override
  String toString() =>
      'QualityReport(score=${(overallScore * 100).toStringAsFixed(0)}%, '
      'warnings=${warnings.length})';
}

/// Enhanced quality scoring for contact angle measurements.
///
/// Combines multiple quality indicators into an overall score,
/// and emits actionable warnings for borderline measurements.
class QualityScorer {
  /// Compute overall quality from processing results.
  ///
  /// [results] is the map returned by ImageProcessor.processImage().
  /// [burstBlurScores] (optional) is a list of blur scores from burst mode.
  static QualityReport score({
    required Map<String, dynamic> results,
    List<double>? burstBlurScores,
  }) {
    final warnings = <String>[];

    // 1. Baseline confidence (from enhanced baseline detection)
    final baselineConf = _clamp01(
      _safeNum(results, 'baseline_confidence', fallback: 0.5),
    );
    if (baselineConf < 0.4) {
      warnings.add('⚠️ Low baseline confidence — substrate edge may be unclear.');
    }

    // 2. Slope stability
    // After rotation, baseline tilt should be near zero. Large residual = suspect.
    final residualTilt = _safeNum(results, 'baseline_tilt', fallback: 0.0).abs();
    final slopeStability = _clamp01(1.0 - residualTilt / 5.0);
    if (residualTilt > 2.0) {
      warnings.add('⚠️ Residual tilt after correction — '
          'surface may be curved or non-planar.');
    }

    // 3. Blur score (from burst mode if available)
    double blurQuality = 1.0;
    if (burstBlurScores != null && burstBlurScores.isNotEmpty) {
      final bestBlur = burstBlurScores.reduce(math.max);
      blurQuality = _clamp01(bestBlur / 300.0);
      if (bestBlur < 80.0) {
        warnings.add('⚠️ Low sharpness — image may be out of focus.');
      }
    }

    // 4. Contour smoothness near contact points
    // Use left/right angle mismatch as a proxy for contact-region noise.
    final angleLeft = _safeNum(results, 'angle_left', fallback: double.nan);
    final angleRight = _safeNum(results, 'angle_right', fallback: double.nan);
    double contourSmoothness = 1.0;
    if (angleLeft.isFinite && angleRight.isFinite) {
      final mismatch = (angleLeft - angleRight).abs();
      contourSmoothness = _clamp01(1.0 - mismatch / 30.0);
      if (mismatch > 15.0) {
        warnings.add('⚠️ Left/right angle asymmetry '
            '(${mismatch.toStringAsFixed(1)}°) — '
            'may indicate pinning or artifacts.');
      }
    }

    // 5. Method symmetry
    // Count valid fitting methods; more = higher confidence.
    int validCount = 0;
    final methodQuality = results['method_quality'];
    if (methodQuality is Map) {
      for (final entry in methodQuality.values) {
        if (entry is Map && entry['is_valid'] == true) validCount++;
      }
    }
    final symmetryScore = _clamp01(validCount / 3.0);
    if (validCount < 2) {
      warnings.add('⚠️ Few valid fitting methods — '
          'consider higher resolution or better contrast.');
    }

    // Check for polynomial-only fit
    bool polyOnly = false;
    if (methodQuality is Map && methodQuality.containsKey('polynomial')) {
      bool isMethodValid(String key) {
        final m = methodQuality[key];
        return m is Map && m['is_valid'] == true;
      }
      polyOnly = isMethodValid('polynomial') &&
          !isMethodValid('circle') &&
          !isMethodValid('ellipse') &&
          !isMethodValid('young_laplace');
    }
    if (polyOnly) {
      warnings.add('⚠️ Only polynomial fit succeeded — '
          'physics-based fits unavailable. Results may be less reliable.');
    }

    // 6. Inter-frame variance (burst mode)
    double interFrameVar = 1.0;
    if (burstBlurScores != null && burstBlurScores.length >= 2) {
      final mean =
          burstBlurScores.reduce((a, b) => a + b) / burstBlurScores.length;
      double sumSq = 0.0;
      for (final s in burstBlurScores) {
        sumSq += (s - mean) * (s - mean);
      }
      final cv = mean > 0
          ? math.sqrt(sumSq / (burstBlurScores.length - 1)) / mean
          : 0.0;
      interFrameVar = _clamp01(1.0 - cv);
      if (cv > 0.3) {
        warnings.add('⚠️ High inter-frame variability — '
            'acquisition may be unstable.');
      }
    }

    // Overall weighted score
    final overall = _clamp01(
      0.25 * baselineConf +
          0.15 * slopeStability +
          0.15 * blurQuality +
          0.20 * contourSmoothness +
          0.15 * symmetryScore +
          0.10 * interFrameVar,
    );

    return QualityReport(
      overallScore: overall,
      baselineConfidence: baselineConf,
      slopeStability: slopeStability,
      blurScore: blurQuality,
      contourSmoothness: contourSmoothness,
      symmetry: symmetryScore,
      interFrameVariance: interFrameVar,
      warnings: warnings,
    );
  }

  /// Safely extract a numeric value from the results map.
  static double _safeNum(
    Map<String, dynamic> map,
    String key, {
    double fallback = 0.0,
  }) {
    final v = map[key];
    if (v is num) return v.toDouble();
    return fallback;
  }

  static double _clamp01(double v) => v.clamp(0.0, 1.0);
}
