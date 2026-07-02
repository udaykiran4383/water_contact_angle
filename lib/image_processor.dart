import 'dart:io';
import 'dart:developer' as developer;
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:convert' as convert;

import 'package:flutter/services.dart' show rootBundle;
import 'package:image/image.dart' as imglib;
import 'package:path_provider/path_provider.dart';

import 'processing/angle_calibration.dart';
import 'processing/angle_utils.dart';
import 'processing/sub_pixel_edge.dart';
import 'processing/silhouette_extractor.dart';
import 'processing/young_laplace.dart';
part 'processing/contour_extractor.dart';
part 'processing/baseline_detector.dart';
part 'processing/contact_point_detector.dart';
part 'processing/ensemble_calculator.dart';
part 'processing/image_annotator.dart';

/// Pixel-to-length calibration metadata for physical-unit reporting.
class ScaleCalibration {
  final double metersPerPixel;
  final double relativeUncertainty;
  final String source;

  const ScaleCalibration({
    required this.metersPerPixel,
    this.relativeUncertainty = 0.0,
    this.source = 'manual',
  })  : assert(metersPerPixel > 0),
        assert(relativeUncertainty >= 0);
}

/// Scientific-level image processor for sessile drop contact angle measurement.
/// Implements multi-method ensemble analysis with proper uncertainty quantification.
// Maximum plausible baseline tilt for sessile-drop capture setup
const double _maxBaselineTiltDeg = 20.0;

const double _minCircleRSquared = 0.72;

const double _minEllipseRSquared = 0.72;

const double _minPolynomialRSquared = 0.70;

// Minimum R² to consider a fit valid
const double _minRSquared = 0.85;

// Max normalised RMS orthogonal residual (fraction of apex radius) for a
// valid ADSA Young-Laplace fit. A genuine drop fit is ~0.01–0.03; 0.10 leaves
// generous headroom for sub-pixel/contact-line noise while rejecting non-drops.
const double _maxYoungLaplaceResidual = 0.10;

// Bootstrap iterations for uncertainty estimation
const int _bootstrapIterations = 100;

void _log(String message) {
  developer.log(message, name: 'ImageProcessor');
}

bool _isAnglePlausible(double angle) {
  return angle.isFinite && angle >= 0.5 && angle <= 179.5;
}

bool _isMethodValid(Map<String, dynamic>? methodResult) {
  if (methodResult == null) return false;
  return methodResult['is_valid'] == true &&
      _isAnglePlausible(
        (methodResult['angle'] as num?)?.toDouble() ?? double.nan,
      );
}

/// True when the ADSA (Young-Laplace) fit is good enough to be the physical
/// reference: a near-perfect geometric R² is itself proof the meridian matches
/// the data, so it should anchor the ensemble rather than be averaged with
/// geometrically cruder circle/polynomial fits. Shared by the ensemble weight,
/// the leave-one-out penalty, and the cross-method outlier filter.
bool _isYoungLaplaceAuthoritative(Map<String, dynamic>? yl) {
  if (yl == null || !_isMethodValid(yl)) return false;
  final r2 = (yl['r_squared'] as num?)?.toDouble() ?? 0.0;
  final res = (yl['residual'] as num?)?.toDouble() ?? double.infinity;
  return r2 >= 0.985 || (r2 >= 0.97 && res <= 0.06);
}

Map<String, dynamic> _validateMethodResult(
  String method,
  Map<String, dynamic> rawResult,
) {
  final result = Map<String, dynamic>.from(rawResult);
  final angle = (result['angle'] as num?)?.toDouble() ?? double.nan;
  final rSq =
      ((result['r_squared'] as num?)?.toDouble() ?? 0.0).clamp(0.0, 1.0);
  final contactConfidence =
      ((result['contact_confidence'] as num?)?.toDouble() ?? 1.0)
          .clamp(0.0, 1.0);
  final baselineConfidence =
      ((result['baseline_confidence'] as num?)?.toDouble() ?? 1.0)
          .clamp(0.0, 1.0);
  result['r_squared'] = rSq;

  String? reason;
  if (!_isAnglePlausible(angle)) {
    reason = 'angle_out_of_range';
  } else {
    switch (method) {
      case 'circle':
        final params = result['params'];
        final cx = (params is List && params.length > 2)
            ? (params[0] as num?)?.toDouble() ?? double.nan
            : double.nan;
        final cy = (params is List && params.length > 2)
            ? (params[1] as num?)?.toDouble() ?? double.nan
            : double.nan;
        final radius = (params is List && params.length > 2)
            ? (params[2] as num?)?.toDouble() ?? double.nan
            : double.nan;
        final leftX =
            (result['left_contact_x'] as num?)?.toDouble() ?? double.nan;
        final rightX =
            (result['right_contact_x'] as num?)?.toDouble() ?? double.nan;
        final baselineY = (result['baseline_y'] as num?)?.toDouble() ?? 0.0;
        if (contactConfidence < 0.08) {
          reason = 'contact_low_confidence';
        } else if (!radius.isFinite || radius <= 2.0) {
          reason = 'invalid_radius';
        } else if (!cy.isFinite ||
            // For θ<90° (hydrophilic cap) the circle CENTER correctly lies
            // below the baseline — what must hold for any sessile cap is that
            // the circle's TOP rises meaningfully above it. (The old
            // center-above-baseline gate silently rejected every hydrophilic
            // drop.)
            cy - radius >= baselineY - 4.0) {
          reason = 'center_below_baseline';
        } else if (leftX.isFinite && rightX.isFinite) {
          final radicand =
              radius * radius - (baselineY - cy) * (baselineY - cy);
          if (!radicand.isFinite || radicand <= 0.0) {
            reason = 'contact_mismatch';
          } else {
            final dx = math.sqrt(radicand);
            final predLeft = cx - dx;
            final predRight = cx + dx;
            final span = (rightX - leftX).abs();
            final tolerance = math.max(
              5.0,
              span *
                  (0.16 + 0.30 * (1.0 - contactConfidence)) *
                  (1.0 + 0.35 * (1.0 - baselineConfidence)),
            );
            final mismatch = math.max(
              (predLeft - leftX).abs(),
              (predRight - rightX).abs(),
            );
            if (mismatch > tolerance &&
                (rSq < 0.94 || contactConfidence < 0.28)) {
              reason = 'contact_mismatch';
            }
          }
        } else if (rSq < _minCircleRSquared) {
          reason = 'low_r_squared';
        }
        if (reason == null && rSq < _minCircleRSquared) {
          reason = 'low_r_squared';
        }
        break;
      case 'ellipse':
        final params = result['params'];
        final a = (params is List && params.length > 3)
            ? (params[2] as num?)?.toDouble() ?? double.nan
            : double.nan;
        final b = (params is List && params.length > 3)
            ? (params[3] as num?)?.toDouble() ?? double.nan
            : double.nan;
        final symmetryScore =
            ((result['symmetry_score'] as num?)?.toDouble() ?? 0.5)
                .clamp(0.0, 1.0);
        final axisRatio = (a.isFinite && b.isFinite && a > 0 && b > 0)
            ? math.max(a, b) / math.min(a, b)
            : double.infinity;
        if (contactConfidence < 0.10) {
          reason = 'contact_low_confidence';
        } else if (!a.isFinite || !b.isFinite || a <= 0 || b <= 0) {
          reason = 'invalid_axes';
        } else if (axisRatio > 7.5 && rSq < 0.95) {
          reason = 'aspect_ratio_outlier';
        } else if (symmetryScore < 0.06 && rSq < 0.90) {
          reason = 'poor_symmetry';
        } else if (rSq < 0.58) {
          reason = 'low_r_squared';
        }
        break;
      case 'polynomial':
        final fitVariant = (result['fit_variant'] as String?) ?? 'polynomial';
        final usedPoints = (result['used_points'] as num?)?.toDouble() ?? 0.0;
        final leftAngle =
            (result['angle_left'] as num?)?.toDouble() ?? double.nan;
        final rightAngle =
            (result['angle_right'] as num?)?.toDouble() ?? double.nan;
        final mismatch = leftAngle.isFinite && rightAngle.isFinite
            ? (leftAngle - rightAngle).abs()
            : 999.0;
        final isLocal = fitVariant == 'local_tangent';
        final isSilhouette = fitVariant == 'silhouette_cap';
        final minPointsRequired = isSilhouette ? 4.0 : (isLocal ? 4.0 : 10.0);
        final maxMismatchAllowed =
            isSilhouette ? 80.0 : (isLocal ? 85.0 : 55.0);
        final minRequiredRSq =
            isSilhouette ? 0.35 : (isLocal ? 0.55 : _minPolynomialRSquared);
        final minContactConfidence =
            isSilhouette ? 0.05 : (isLocal ? 0.08 : 0.12);
        if (contactConfidence <= minContactConfidence) {
          reason = 'contact_low_confidence';
        } else if (usedPoints < minPointsRequired) {
          reason = 'insufficient_points';
        } else if (mismatch > maxMismatchAllowed) {
          reason = 'left_right_mismatch';
        } else if (rSq < minRequiredRSq) {
          reason = 'low_r_squared';
        }
        break;
      case 'young_laplace':
        final residual =
            (result['residual'] as num?)?.toDouble() ?? double.infinity;
        final bo = (result['bond_number'] as num?)?.toDouble() ?? double.nan;
        final baselineConfidence =
            ((result['baseline_confidence'] as num?)?.toDouble() ?? 0.5)
                .clamp(0.0, 1.0);
        final symmetryScore =
            ((result['symmetry_score'] as num?)?.toDouble() ?? 0.5)
                .clamp(0.0, 1.0);
        final residualLimit =
            _maxYoungLaplaceResidual + 0.10 * (1.0 - contactConfidence);
        if (contactConfidence < 0.08 || baselineConfidence < 0.08) {
          reason = 'contact_low_confidence';
        } else if (symmetryScore < 0.05 && rSq < 0.85) {
          reason = 'poor_symmetry';
        } else if (!bo.isFinite || bo <= 0) {
          reason = 'invalid_bond_number';
        } else if (residual > residualLimit) {
          reason = 'high_residual';
        } else if (rSq < 0.90) {
          // ADSA reports a *true* geometric R²; a genuine drop fit is ≥0.95.
          // Anything below ~0.90 is not a Young-Laplace shape and is rejected.
          reason = 'low_r_squared';
        }
        break;
    }
  }

  if (reason == null) {
    result['is_valid'] = true;
    result.remove('invalid_reason');
  } else {
    result['is_valid'] = false;
    result['invalid_reason'] = reason;
  }

  return result;
}

Map<String, dynamic> _invalidMethodResult(String reason) {
  return {
    'angle': double.nan,
    'r_squared': 0.0,
    'is_valid': false,
    'invalid_reason': reason,
  };
}

String _humanizeInvalidReason(String? reason) {
  switch (reason) {
    case 'fit_failed':
      return 'fit failed';
    case 'angle_out_of_range':
      return 'angle out of range';
    case 'invalid_radius':
      return 'invalid radius';
    case 'center_below_baseline':
      return 'circle cap below baseline';
    case 'contact_mismatch':
      return 'circle/contact mismatch';
    case 'invalid_axes':
      return 'invalid ellipse axes';
    case 'aspect_ratio_outlier':
      return 'ellipse aspect ratio outlier';
    case 'insufficient_points':
      return 'insufficient points';
    case 'left_right_mismatch':
      return 'left/right mismatch';
    case 'high_residual':
      return 'high residual';
    case 'invalid_bond_number':
      return 'invalid Bond number';
    case 'low_r_squared':
      return 'low R²';
    case 'contact_low_confidence':
      return 'low contact confidence';
    case 'poor_symmetry':
      return 'poor symmetry';
    case 'cross_method_outlier':
      return 'cross-method outlier';
    default:
      return 'invalid';
  }
}

String _formatMethodSummary(
  String methodName,
  Map<String, Map<String, dynamic>> methodResults,
) {
  final result = methodResults[methodName];
  if (result == null) return 'N/A';

  final angle = (result['angle'] as num?)?.toDouble() ?? double.nan;
  final rSq = (result['r_squared'] as num?)?.toDouble() ?? double.nan;
  if (!_isMethodValid(result)) {
    final reason = _humanizeInvalidReason(result['invalid_reason'] as String?);
    if (rSq.isFinite) {
      return 'Rejected ($reason; R²=${rSq.toStringAsFixed(3)})';
    }
    return 'Rejected ($reason)';
  }

  if (methodName == 'young_laplace') {
    final bo = (result['bond_number'] as num?)?.toDouble() ?? double.nan;
    final residual = (result['residual'] as num?)?.toDouble() ?? double.nan;
    final boText = bo.isFinite ? bo.toStringAsExponential(2) : 'N/A';
    final residualText = residual.isFinite ? residual.toStringAsFixed(3) : '';
    final residualSuffix =
        residualText.isNotEmpty ? ', residual=$residualText' : '';
    return '${angle.toStringAsFixed(1)}° (R²=${rSq.toStringAsFixed(3)}, Bo=$boText$residualSuffix)';
  }

  return '${angle.toStringAsFixed(1)}° (R²=${rSq.toStringAsFixed(3)})';
}

double _methodMetricOrNaN(
  Map<String, Map<String, dynamic>> methodResults,
  String methodName,
  String key,
) {
  final result = methodResults[methodName];
  if (!_isMethodValid(result)) return double.nan;
  final value = (result![key] as num?)?.toDouble() ?? double.nan;
  return value.isFinite ? value : double.nan;
}

Map<String, double> _computeSymmetryScore(
  List<math.Point<double>> contourAligned,
  double leftX,
  double rightX,
) {
  if (contourAligned.length < 16 || !leftX.isFinite || !rightX.isFinite) {
    return {'score': 0.0, 'residual': double.infinity, 'coverage': 0.0};
  }
  final centerX = (leftX + rightX) * 0.5;
  final halfSpan = ((rightX - leftX).abs() * 0.5).clamp(1.0, 1e9);
  final apexY = contourAligned.map((p) => p.y).reduce(math.min);

  final byRow = <int, List<math.Point<double>>>{};
  for (final p in contourAligned) {
    // Ignore very close-to-baseline points where reflection noise dominates.
    if (p.y > -1.5) continue;
    final yKey = p.y.round();
    byRow.putIfAbsent(yKey, () => <math.Point<double>>[]).add(p);
  }

  if (byRow.length < 6) {
    return {'score': 0.0, 'residual': double.infinity, 'coverage': 0.0};
  }

  final residuals = <double>[];
  int usedRows = 0;
  final keys = byRow.keys.toList()..sort();
  for (final key in keys) {
    final y = key.toDouble();
    // Stay in the physically useful band: not too near baseline, not too near apex tip.
    if (y > -2.0 || y < apexY + 2.0) continue;
    final row = byRow[key]!;
    double? leftRow;
    double? rightRow;
    for (final p in row) {
      if (p.x < centerX) {
        leftRow = leftRow == null ? p.x : math.max(leftRow, p.x);
      } else if (p.x > centerX) {
        rightRow = rightRow == null ? p.x : math.min(rightRow, p.x);
      }
    }
    if (leftRow == null || rightRow == null) continue;
    final leftHalf = centerX - leftRow;
    final rightHalf = rightRow - centerX;
    if (leftHalf <= 0 || rightHalf <= 0) continue;
    final rowResidual = (leftHalf - rightHalf).abs() / halfSpan;
    residuals.add(rowResidual);
    usedRows++;
  }

  if (residuals.length < 4) {
    return {'score': 0.0, 'residual': double.infinity, 'coverage': 0.0};
  }

  final meanResidual = residuals.reduce((a, b) => a + b) / residuals.length;
  final coverage =
      (usedRows / math.max(1.0, byRow.length.toDouble())).clamp(0.0, 1.0);
  final score = (math.exp(-meanResidual / 0.11) * math.pow(coverage, 0.65))
      .clamp(0.0, 1.0);
  return {
    'score': score,
    'residual': meanResidual,
    'coverage': coverage,
  };
}

class ImageProcessor {
  /// Filter out edge points that border bright reflection/gap regions
  /// rather than the dark droplet silhouette.
  ///
  /// For edge points in the lower portion of the contour, sample pixels
  /// a few pixels above.  True droplet edges have dark pixels above
  /// (the droplet body).  Reflection/gap edges have bright pixels above
  /// (light passing through or reflecting under the droplet).
  static List<math.Point<double>> _filterReflectionEdges(
    List<math.Point<double>> contour,
    List<int> grayValues,
    int width,
    int height, {
    bool inverted = false,
  }) {
    if (contour.length < 20) return contour;

    // When the image was inverted (dark background → bright droplet body),
    // the "bright pixels above = reflection" heuristic is reversed:
    // the droplet body itself becomes bright after inversion, so the filter
    // would incorrectly strip ALL near-contact edges.  Skip the filter
    // entirely for inverted images — the downstream pipeline (connected-
    // component selection, baseline RANSAC, contact detection) is robust
    // enough to handle a few reflection points.
    if (inverted) {
      _log('🔍 Reflection filter: SKIPPED (image was inverted)');
      return contour;
    }

    final minY = contour.map((p) => p.y).reduce(math.min);
    final maxY = contour.map((p) => p.y).reduce(math.max);
    final yRange = (maxY - minY).abs();
    if (yRange < 10.0) return contour;

    // Only filter points in the bottom ~35% of the contour.
    final filterBelowY = minY + yRange * 0.65;

    // Learn how dark the droplet body is by sampling pixels inward from
    // edges in the upper portion of the contour.
    final upperPoints =
        contour.where((p) => p.y < minY + yRange * 0.4).toList();
    if (upperPoints.length < 5) return contour;

    double sumDark = 0.0;
    int darkN = 0;
    for (final p in upperPoints) {
      final ix = p.x.round().clamp(1, width - 2);
      final iy = p.y.round().clamp(1, height - 2);
      for (int dy = -3; dy <= -1; dy++) {
        final sy = (iy + dy).clamp(0, height - 1);
        sumDark += grayValues[sy * width + ix];
        darkN++;
      }
    }
    if (darkN == 0) return contour;
    final avgDark = sumDark / darkN;
    // Threshold: anything significantly brighter than the droplet interior.
    final brightThr = avgDark + (255.0 - avgDark) * 0.40;

    final filtered = <math.Point<double>>[];
    for (final p in contour) {
      if (p.y < filterBelowY) {
        filtered.add(p);
        continue;
      }

      final ix = p.x.round().clamp(1, width - 2);
      final iy = p.y.round().clamp(2, height - 1);
      double aboveSum = 0.0;
      int aboveN = 0;
      for (int dy = -5; dy <= -1; dy++) {
        final sy = (iy + dy).clamp(0, height - 1);
        aboveSum += grayValues[sy * width + ix];
        aboveN++;
      }
      if (aboveN > 0 && aboveSum / aboveN > brightThr) {
        continue; // bright above ⇒ reflection edge ⇒ skip
      }
      filtered.add(p);
    }

    _log('🔍 Reflection filter: ${contour.length} → ${filtered.length} '
        '(removed ${contour.length - filtered.length} reflection edges)');

    if (filtered.length < contour.length * 0.40 || filtered.length < 20) {
      _log('⚠️ Reflection filter too aggressive, keeping original');
      return contour;
    }
    return filtered;
  }

  // Fallback calibration used when no explicit scale is provided.
  static const double _defaultMetersPerPixelApprox = 10e-6;

  static AngleCalibrationProfile? _cachedAngleCalibrationProfile;
  static bool _angleCalibrationLoadAttempted = false;

  static Future<AngleCalibrationProfile> _loadAngleCalibrationProfile() async {
    if (_angleCalibrationLoadAttempted) {
      return _cachedAngleCalibrationProfile ??
          AngleCalibrationProfile.identity(source: 'missing');
    }
    _angleCalibrationLoadAttempted = true;
    try {
      final text = await rootBundle
          .loadString('assets/calibration/angle_calibration_profile.json');
      final decoded = convert.jsonDecode(text);
      if (decoded is Map<String, dynamic>) {
        _cachedAngleCalibrationProfile =
            AngleCalibrationProfile.fromJson(decoded);
      } else if (decoded is Map) {
        _cachedAngleCalibrationProfile = AngleCalibrationProfile.fromJson(
          decoded.map((k, v) => MapEntry(k.toString(), v)),
        );
      }
    } catch (e) {
      _log('⚠️ Angle calibration profile load failed: $e');
      _cachedAngleCalibrationProfile =
          AngleCalibrationProfile.identity(source: 'missing');
    }
    return _cachedAngleCalibrationProfile ??
        AngleCalibrationProfile.identity(source: 'missing');
  }

  static Map<String, dynamic> _applyAngleCalibration(
    Map<String, dynamic> methodResult,
    AngleCalibrationProfile profile,
  ) {
    final out = Map<String, dynamic>.from(methodResult);
    double? applyIfFinite(dynamic v) {
      if (v is! num) return null;
      final d = v.toDouble();
      if (!d.isFinite) return null;
      return profile.apply(d);
    }

    final raw = (out['angle'] as num?)?.toDouble();
    if (raw != null && raw.isFinite) {
      out['angle_raw'] = raw;
      out['angle'] = profile.apply(raw);
    }

    final left = applyIfFinite(out['angle_left']);
    if (left != null) {
      out['angle_left_raw'] = (out['angle_left'] as num).toDouble();
      out['angle_left'] = left;
    }

    final right = applyIfFinite(out['angle_right']);
    if (right != null) {
      out['angle_right_raw'] = (out['angle_right'] as num).toDouble();
      out['angle_right'] = right;
    }

    out['angle_calibration_source'] = profile.source;
    out['angle_calibration_residual_std'] = profile.residualStdDeg;
    return out;
  }

  static bool _isCalibrationProfileUsable(AngleCalibrationProfile profile) {
    if (profile.source == 'missing') return false;
    if (profile.residualStdDeg.isFinite && profile.residualStdDeg > 3.0) {
      return false;
    }
    if (profile.maxCorrectionDeg > 12.0) {
      return false;
    }
    if (profile.isPiecewiseLinear &&
        profile.knots != null &&
        profile.values != null) {
      double maxCorr = 0.0;
      for (int i = 0; i < profile.knots!.length; i++) {
        maxCorr = math.max(
          maxCorr,
          (profile.values![i] - profile.knots![i]).abs(),
        );
      }
      if (maxCorr > 10.0) return false;
    }
    return true;
  }

  /// Extract red channel robustly across `image` package versions
  static int _getRed(dynamic pixel) {
    if (pixel is int) return (pixel >> 16) & 0xFF;
    try {
      final r = (pixel as dynamic).r;
      if (r is int) return r;
    } catch (_) {}
    try {
      final r2 = (pixel as dynamic).red;
      if (r2 is int) return r2;
    } catch (_) {}
    try {
      return ((pixel as int) >> 16) & 0xFF;
    } catch (_) {
      return 0;
    }
  }

  /// Trim uniform near-black borders (e.g. the letterbox bars in a phone
  /// screenshot, or dark margins around a cropped capture). Such bars otherwise
  /// fool the bright/dark polarity test and the baseline detector, producing a
  /// "0 points" failure on an otherwise valid back-lit drop. Only trims when the
  /// remaining content is still a large fraction of the frame (so real images
  /// are untouched).
  static imglib.Image _autoCropDarkBorders(imglib.Image img) {
    final w = img.width, h = img.height;
    if (w < 60 || h < 60) return img;

    bool isBorderRow(int y) {
      double sum = 0, sumSq = 0;
      int n = 0;
      for (int x = 0; x < w; x += 4) {
        final v = _getRed(img.getPixel(x, y)).toDouble();
        sum += v;
        sumSq += v * v;
        n++;
      }
      final mean = sum / n;
      final variance = (sumSq / n) - mean * mean;
      return mean < 24.0 && variance < 200.0;
    }

    bool isBorderCol(int x, int y0, int y1) {
      double sum = 0, sumSq = 0;
      int n = 0;
      for (int y = y0; y < y1; y += 4) {
        final v = _getRed(img.getPixel(x, y)).toDouble();
        sum += v;
        sumSq += v * v;
        n++;
      }
      final mean = sum / n;
      final variance = (sumSq / n) - mean * mean;
      return mean < 24.0 && variance < 200.0;
    }

    int top = 0;
    while (top < h - 1 && isBorderRow(top)) {
      top++;
    }
    int bottom = h - 1;
    while (bottom > top && isBorderRow(bottom)) {
      bottom--;
    }
    int left = 0;
    while (left < w - 1 && isBorderCol(left, top, bottom + 1)) {
      left++;
    }
    int right = w - 1;
    while (right > left && isBorderCol(right, top, bottom + 1)) {
      right--;
    }

    final cw = right - left + 1;
    final ch = bottom - top + 1;
    final trimmed =
        top > 0 || left > 0 || bottom < h - 1 || right < w - 1;
    // Keep any content region that is still a usable size — letterboxed
    // screenshots can leave the real scene at only ~20-25% of the frame.
    if (!trimmed || cw < w * 0.12 || ch < h * 0.10 || cw < 80 || ch < 80) {
      return img;
    }
    _log('✂️ Auto-cropped dark borders: ${w}x$h -> ${cw}x$ch '
        '(l=$left,t=$top,r=$right,b=$bottom)');
    return imglib.copyCrop(img, x: left, y: top, width: cw, height: ch);
  }

  /// Convert pixel geometry to physical units and Bond-number uncertainty.
  static Map<String, double> computePhysicalMetrics({
    required double radiusPixels,
    ScaleCalibration? calibration,
  }) {
    final bool isCalibrated = calibration != null;
    final double metersPerPixel = isCalibrated
        ? calibration.metersPerPixel
        : _defaultMetersPerPixelApprox;
    final double radiusM = math.max(0.0, radiusPixels) * metersPerPixel;
    final double radiusMm = radiusM * 1e3;
    final double pixelSizeUm = metersPerPixel * 1e6;
    final double bondNumberPhysical = YoungLaplaceSolver.bondNumber(radiusM);

    double bondNumberUncertainty = double.nan;
    if (isCalibrated) {
      final rel = math.max(0.0, calibration.relativeUncertainty);
      // Bo = k * R^2, so relative uncertainty scales as 2 * dR/R.
      bondNumberUncertainty = (2.0 * rel * bondNumberPhysical).abs();
    }

    return {
      'is_calibrated': isCalibrated ? 1.0 : 0.0,
      'meters_per_pixel': metersPerPixel,
      'pixel_size_um': pixelSizeUm,
      'radius_m': radiusM,
      'radius_mm': radiusMm,
      'bond_number_physical': bondNumberPhysical,
      'bond_number_physical_uncertainty': bondNumberUncertainty,
    };
  }

  static Future<Directory> _resolveTempDirectory() async {
    try {
      final dir = await getTemporaryDirectory();
      if (await dir.exists()) return dir;
    } catch (_) {
      // Fallback for headless/test contexts where path_provider may be unavailable.
    }
    return Directory.systemTemp;
  }

  /// Automatically infer scale calibration from image metadata when available.
  /// Priority:
  /// 1) EXIF X/YResolution + ResolutionUnit
  /// 2) PNG pHYs chunk (pixels per meter)
  static ScaleCalibration? detectAutoCalibration(
    imglib.Image image,
    Uint8List originalBytes,
  ) {
    final fromExif = _calibrationFromExif(image);
    if (fromExif != null) return fromExif;

    final fromPng = _calibrationFromPng(originalBytes);
    if (fromPng != null) return fromPng;

    return null;
  }

  static ScaleCalibration? _calibrationFromExif(imglib.Image image) {
    if (!image.hasExif) return null;
    final exif = image.exif;
    if (exif.isEmpty) return null;

    final ifd = exif.imageIfd;
    final unit = ifd.resolutionUnit;
    final xRes = _metadataValueToDouble(ifd.xResolution);
    final yRes = _metadataValueToDouble(ifd.yResolution);

    final metersPerPixel = _metersPerPixelFromResolution(
      xRes: xRes,
      yRes: yRes,
      resolutionUnit: unit,
    );
    if (metersPerPixel == null ||
        !metersPerPixel.isFinite ||
        metersPerPixel <= 0) {
      return null;
    }

    final relUnc = _resolutionAnisotropyUncertainty(xRes, yRes, base: 0.05);
    return ScaleCalibration(
      metersPerPixel: metersPerPixel,
      relativeUncertainty: relUnc,
      source: 'metadata_exif',
    );
  }

  static ScaleCalibration? _calibrationFromPng(Uint8List bytes) {
    try {
      final info = imglib.PngDecoder().startDecode(bytes);
      if (info is! imglib.PngInfo) return null;
      final dims = info.pixelDimensions;
      if (dims == null ||
          dims.unitSpecifier != imglib.PngPhysicalPixelDimensions.unitMeter) {
        return null;
      }

      final xPpm = dims.xPxPerUnit.toDouble();
      final yPpm = dims.yPxPerUnit.toDouble();
      if (xPpm <= 0 || yPpm <= 0) return null;

      final metersPerPixel = 1.0 / ((xPpm + yPpm) * 0.5);
      final relUnc = _resolutionAnisotropyUncertainty(xPpm, yPpm, base: 0.03);
      return ScaleCalibration(
        metersPerPixel: metersPerPixel,
        relativeUncertainty: relUnc,
        source: 'metadata_png_phys',
      );
    } catch (_) {
      return null;
    }
  }

  static double? _metersPerPixelFromResolution({
    required double? xRes,
    required double? yRes,
    required int? resolutionUnit,
  }) {
    final candidates = <double>[];
    if (xRes != null && xRes > 0) candidates.add(xRes);
    if (yRes != null && yRes > 0) candidates.add(yRes);
    if (candidates.isEmpty) return null;

    final meanRes = candidates.reduce((a, b) => a + b) / candidates.length;

    // EXIF ResolutionUnit values:
    // 2 = inch, 3 = centimeter. Anything else is unspecified.
    if (resolutionUnit == 2) {
      return 0.0254 / meanRes;
    }
    if (resolutionUnit == 3) {
      return 0.01 / meanRes;
    }
    return null;
  }

  static double _resolutionAnisotropyUncertainty(
    double? xRes,
    double? yRes, {
    required double base,
  }) {
    if (xRes == null || yRes == null || xRes <= 0 || yRes <= 0) {
      return base;
    }
    final mean = (xRes + yRes) * 0.5;
    if (mean <= 0) return base;
    final anisotropy = (xRes - yRes).abs() / mean;
    return (base + anisotropy).clamp(base, 0.25);
  }

  static double? _metadataValueToDouble(dynamic value) {
    if (value == null) return null;
    if (value is num) {
      final d = value.toDouble();
      return d.isFinite ? d : null;
    }
    try {
      final d = (value as dynamic).toDouble();
      if (d is num) {
        final asDouble = d.toDouble();
        return asDouble.isFinite ? asDouble : null;
      }
    } catch (_) {}
    return null;
  }

  /// Intensity-driven baseline fallback for cases where contour-only baseline
  /// evidence is weak (e.g. reflection-heavy or partially clipped contours).
  static Map<String, dynamic> _detectBaselineFromIntensity(
    List<int> gray,
    int width,
    int height,
  ) {
    if (gray.isEmpty || width < 24 || height < 24) {
      return {
        'slope': 0.0,
        'intercept': 0.0,
        'angle': 0.0,
        'angle_rad': 0.0,
        'rms': double.infinity,
        'span_fraction': 0.0,
        'inlier_fraction': 0.0,
        'tilt_penalty': 1.0,
        'confidence': 0.0,
        'source': 'intensity',
      };
    }

    final xMargin = (width * 0.05).round().clamp(3, width ~/ 4);
    final yStart = (height * 0.26).round().clamp(4, height - 12);
    final yEnd = (height * 0.94).round().clamp(yStart + 10, height - 4);

    final sideBand = (width * 0.22).round().clamp(10, width ~/ 3);
    final sideXSet = <int>{};
    for (int x = xMargin; x < xMargin + sideBand; x += 2) {
      sideXSet.add(x);
    }
    for (int x = width - xMargin - sideBand; x < width - xMargin; x += 2) {
      sideXSet.add(x);
    }
    var sideXs = sideXSet.where((x) => x > 0 && x < width - 1).toList()..sort();
    if (sideXs.length < 8) {
      sideXs = <int>[];
      for (int x = xMargin; x < width - xMargin; x += 3) {
        sideXs.add(x);
      }
    }

    // Step 1: find a seed row using directional contrast (bright above, dark below)
    // on side regions to avoid droplet interior/reflection confusion.
    const rowWindow = 2;
    double bestRowScore = double.negativeInfinity;
    double bestRowDiff = 0.0;
    double bestRowPositiveFrac = 0.0;
    int seedY = ((yStart + yEnd) * 0.5).round();
    for (int y = yStart + rowWindow; y <= yEnd - rowWindow; y++) {
      double sumDiff = 0.0;
      double sumAbs = 0.0;
      int positive = 0;
      int count = 0;
      for (final x in sideXs) {
        double upper = 0.0;
        double lower = 0.0;
        for (int k = 1; k <= rowWindow; k++) {
          upper += gray[(y - k) * width + x];
          lower += gray[(y + k) * width + x];
        }
        final diff = (upper / rowWindow) - (lower / rowWindow);
        sumDiff += diff;
        sumAbs += diff.abs();
        if (diff > 0.0) positive++;
        count++;
      }
      if (count == 0) continue;
      final meanDiff = sumDiff / count;
      final meanAbs = sumAbs / count;
      final positiveFrac = positive / count;
      final directional = math.max(0.0, meanDiff);
      final score = directional * (0.30 + 0.70 * positiveFrac) + 0.12 * meanAbs;
      if (score > bestRowScore) {
        bestRowScore = score;
        bestRowDiff = meanDiff;
        bestRowPositiveFrac = positiveFrac;
        seedY = y;
      }
    }

    // Step 2: per-column directional edge tracing around the seed row.
    final points = <math.Point<double>>[];
    final candidateGrad = <double>[];
    final searchRadius = (height * 0.06).round().clamp(8, 30);
    for (int x = xMargin; x < width - xMargin; x += 2) {
      double bestGrad = double.negativeInfinity;
      int bestY = -1;
      final localStart = math.max(yStart, seedY - searchRadius);
      final localEnd = math.min(yEnd, seedY + searchRadius);
      for (int y = localStart; y <= localEnd; y++) {
        final upper = gray[(y - 1) * width + x].toDouble();
        final lower = gray[(y + 1) * width + x].toDouble();
        final g = upper -
            lower; // signed vertical edge: bright->dark should be positive
        if (g > bestGrad) {
          bestGrad = g;
          bestY = y;
        }
      }
      if (bestY >= 0 && bestGrad.isFinite) {
        points.add(math.Point<double>(x.toDouble(), bestY.toDouble()));
        candidateGrad.add(bestGrad);
      }
    }

    if (points.length < 12) {
      return {
        'slope': 0.0,
        'intercept': (height * 0.7).toDouble(),
        'angle': 0.0,
        'angle_rad': 0.0,
        'rms': double.infinity,
        'span_fraction': 0.0,
        'inlier_fraction': 0.0,
        'tilt_penalty': 1.0,
        'confidence': 0.0,
        'source': 'intensity',
      };
    }

    final gradMedian = _medianDouble(candidateGrad);
    final keepThreshold = math.max(5.0, gradMedian * 0.70);
    final strongPoints = <math.Point<double>>[];
    for (int i = 0; i < points.length; i++) {
      if (candidateGrad[i] >= keepThreshold) {
        strongPoints.add(points[i]);
      }
    }
    final usePoints = strongPoints.length >= 8 ? strongPoints : points;

    if (usePoints.length < 8) {
      return {
        'slope': 0.0,
        'intercept': (height * 0.7).toDouble(),
        'angle': 0.0,
        'angle_rad': 0.0,
        'rms': double.infinity,
        'span_fraction': 0.0,
        'inlier_fraction': 0.0,
        'tilt_penalty': 1.0,
        'confidence': 0.0,
        'source': 'intensity',
      };
    }

    // Step 3: robust line fit with iterative inlier trimming.
    var working = List<math.Point<double>>.from(usePoints);
    double slope = 0.0;
    double intercept = seedY.toDouble();
    List<math.Point<double>> inliers = List<math.Point<double>>.from(working);
    for (int iter = 0; iter < 3; iter++) {
      final fit = _fitLineLeastSquares(working);
      slope = fit['slope']!;
      intercept = fit['intercept']!;
      final next = <math.Point<double>>[];
      for (final p in working) {
        if (_lineDistance(p, slope, intercept) <= 2.4) {
          next.add(p);
        }
      }
      if (next.length < math.max(8, (working.length * 0.45).round())) {
        break;
      }
      inliers = next;
      working = next;
    }
    if (inliers.length >= 8) {
      final refined = _fitLineLeastSquares(inliers);
      slope = refined['slope']!;
      intercept = refined['intercept']!;
    } else {
      inliers = usePoints;
      final refined = _fitLineLeastSquares(inliers);
      slope = refined['slope']!;
      intercept = refined['intercept']!;
    }

    final used = inliers;
    double rms = 0.0;
    for (final p in used) {
      final d = _lineDistance(p, slope, intercept);
      rms += d * d;
    }
    rms = math.sqrt(rms / math.max(1, used.length));

    final angleDeg = math.atan(slope) * 180.0 / math.pi;
    final inlierMinX = used.map((p) => p.x).reduce(math.min);
    final inlierMaxX = used.map((p) => p.x).reduce(math.max);
    final spanFraction =
        ((inlierMaxX - inlierMinX) / math.max(1.0, (width - 1).toDouble()))
            .clamp(0.0, 1.0);
    final inlierFraction =
        (used.length / math.max(1, usePoints.length)).clamp(0.0, 1.0);
    final meanGrad = candidateGrad.isNotEmpty
        ? candidateGrad.reduce((a, b) => a + b) / candidateGrad.length
        : 0.0;
    final gradStrength = ((meanGrad - 4.0) / 28.0).clamp(0.0, 1.0);

    // Guard against unstable tilt: keep row-anchored horizontal baseline when
    // directional support is weak.
    if (angleDeg.abs() > 9.0 &&
        (inlierFraction < 0.45 ||
            bestRowPositiveFrac < 0.40 ||
            bestRowDiff < 3.0)) {
      slope = 0.0;
      intercept = seedY.toDouble();
    }

    final finalAngleRad = math.atan(slope);
    final finalAngleDeg = finalAngleRad * 180.0 / math.pi;
    final finalTiltPenalty =
        (finalAngleDeg.abs() / _maxBaselineTiltDeg).clamp(0.0, 1.0);
    final directionalStrength =
        (math.max(0.0, bestRowDiff) / 34.0).clamp(0.0, 1.0);
    final polarityStrength = bestRowPositiveFrac.clamp(0.0, 1.0);
    final confidence = (math.exp(-rms / 1.9) *
            math.pow(inlierFraction, 0.72) *
            math.pow(spanFraction, 1.15) *
            (0.45 + 0.55 * gradStrength) *
            (0.45 + 0.55 * directionalStrength) *
            (0.40 + 0.60 * polarityStrength) *
            (1.0 - 0.50 * finalTiltPenalty))
        .clamp(0.0, 1.0);

    return {
      'slope': slope,
      'intercept': intercept,
      'angle': finalAngleDeg,
      'angle_rad': finalAngleRad,
      'rms': rms,
      'span_fraction': spanFraction,
      'inlier_fraction': inlierFraction,
      'tilt_penalty': finalTiltPenalty,
      'confidence': confidence,
      'source': 'intensity',
    };
  }

  static double _baselineQualityScore(Map<String, dynamic> baseline) {
    final confidence =
        ((baseline['confidence'] as num?)?.toDouble() ?? 0.0).clamp(0.0, 1.0);
    final span = ((baseline['span_fraction'] as num?)?.toDouble() ?? 0.0)
        .clamp(0.0, 1.0);
    final inlier = ((baseline['inlier_fraction'] as num?)?.toDouble() ?? 0.0)
        .clamp(0.0, 1.0);
    final rms =
        ((baseline['rms'] as num?)?.toDouble() ?? double.infinity).abs();
    final rmsScore = rms.isFinite ? math.exp(-rms / 2.6) : 0.0;
    return (0.45 * confidence + 0.20 * span + 0.15 * inlier + 0.20 * rmsScore)
        .clamp(0.0, 1.0);
  }

  static double _medianDouble(List<double> values) {
    if (values.isEmpty) return 0.0;
    final sorted = List<double>.from(values)..sort();
    final mid = sorted.length ~/ 2;
    if (sorted.length.isOdd) return sorted[mid];
    return (sorted[mid - 1] + sorted[mid]) * 0.5;
  }

  static Map<String, Map<String, dynamic>> _applyCrossMethodConsistency(
    Map<String, Map<String, dynamic>> methodResults,
  ) {
    final updated = methodResults.map(
      (k, v) => MapEntry(k, Map<String, dynamic>.from(v)),
    );

    // A near-perfect ADSA (Young-Laplace) fit is the physical reference. When
    // it disagrees with circle/polynomial fits, the cruder geometric methods
    // are the suspects — not ADSA. So an authoritative Young-Laplace fit is
    // exempt from outlier removal here.
    final bool ylAuthoritative =
        _isYoungLaplaceAuthoritative(updated['young_laplace']);

    final validEntries =
        updated.entries.where((e) => _isMethodValid(e.value)).toList();
    if (validEntries.length < 2) return updated;

    final validAngles = <double>[];
    for (final entry in validEntries) {
      final a = (entry.value['angle'] as num?)?.toDouble() ?? double.nan;
      if (a.isFinite) validAngles.add(a);
    }
    if (validAngles.length < 2) return updated;

    final medianAngle = _medianDouble(validAngles);
    final absDev = validAngles.map((a) => (a - medianAngle).abs()).toList();
    final mad = _medianDouble(absDev);
    final dynamicTolerance = math.max(18.0, 3.5 * 1.4826 * mad + 8.0);

    for (final entry in validEntries) {
      final angle = (entry.value['angle'] as num?)?.toDouble() ?? double.nan;
      if (!angle.isFinite) continue;
      final isOutlier = (angle - medianAngle).abs() > dynamicTolerance;
      if (!isOutlier) continue;

      final isYoungLaplace = entry.key == 'young_laplace';
      if (isYoungLaplace && ylAuthoritative) continue; // trust the ADSA fit

      // Keep single geometric survivor when only two methods are available,
      // but suppress extreme physics outliers and broad multi-method outliers.
      if (validEntries.length >= 3 || isYoungLaplace) {
        entry.value['is_valid'] = false;
        entry.value['invalid_reason'] = 'cross_method_outlier';
      }
    }

    final geometricAngles = <double>[];
    for (final key in const [
      'circle',
      'ellipse',
      'polynomial',
      'circle_local'
    ]) {
      final m = updated[key];
      if (_isMethodValid(m)) {
        final a = (m!['angle'] as num?)?.toDouble() ?? double.nan;
        if (a.isFinite) geometricAngles.add(a);
      }
    }
    final yl = updated['young_laplace'];
    if (!ylAuthoritative && _isMethodValid(yl) && geometricAngles.isNotEmpty) {
      final geometricMedian = _medianDouble(geometricAngles);
      final ylAngle = (yl!['angle'] as num?)?.toDouble() ?? double.nan;
      final ylResidual =
          (yl['residual'] as num?)?.toDouble() ?? double.infinity;
      if (ylAngle.isFinite &&
          (ylAngle - geometricMedian).abs() > 32.0 &&
          ylResidual > 0.14) {
        yl['is_valid'] = false;
        yl['invalid_reason'] = 'cross_method_outlier';
      }
    }

    return updated;
  }

  static Map<String, double> _estimateContactFromIntensity(
    List<int> gray,
    int width,
    int height,
    Map<String, dynamic> baseline, {
    double? hintCenterX,
    double? hintSpan,
  }) {
    if (gray.isEmpty || width < 20 || height < 20) {
      return {'leftX': double.nan, 'rightX': double.nan, 'confidence': 0.0};
    }

    final profileNear = List<double>.filled(width, 0.0);
    final profileBody = List<double>.filled(width, 0.0);
    for (int x = 0; x < width; x++) {
      final yBase = _baselineYAtX(baseline, x.toDouble()).round();
      double nearSum = 0.0;
      int nearN = 0;
      for (int dy = -6; dy <= -2; dy++) {
        final y = (yBase + dy).clamp(0, height - 1);
        nearSum += gray[y * width + x];
        nearN++;
      }
      profileNear[x] = nearN > 0 ? nearSum / nearN : 255.0;

      double bodySum = 0.0;
      int bodyN = 0;
      for (int dy = -26; dy <= -10; dy++) {
        final y = (yBase + dy).clamp(0, height - 1);
        bodySum += gray[y * width + x];
        bodyN++;
      }
      profileBody[x] = bodyN > 0 ? bodySum / bodyN : profileNear[x];
    }

    // Smooth profile to suppress dust/sparkle noise.
    final smoothNear = List<double>.from(profileNear);
    final smoothBody = List<double>.from(profileBody);
    for (int x = 2; x < width - 2; x++) {
      smoothNear[x] = (profileNear[x - 2] +
              profileNear[x - 1] +
              profileNear[x] +
              profileNear[x + 1] +
              profileNear[x + 2]) /
          5.0;
      smoothBody[x] = (profileBody[x - 2] +
              profileBody[x - 1] +
              profileBody[x] +
              profileBody[x + 1] +
              profileBody[x + 2]) /
          5.0;
    }
    final smooth = List<double>.filled(width, 0.0);
    for (int x = 0; x < width; x++) {
      smooth[x] = 0.30 * smoothNear[x] + 0.70 * smoothBody[x];
    }

    final sorted = List<double>.from(smooth)..sort();
    final q10 =
        sorted[(sorted.length * 0.10).floor().clamp(0, sorted.length - 1)];
    final q90 =
        sorted[(sorted.length * 0.90).floor().clamp(0, sorted.length - 1)];
    final contrast = (q90 - q10).abs();
    if (!contrast.isFinite || contrast < 10.0) {
      return {'leftX': double.nan, 'rightX': double.nan, 'confidence': 0.0};
    }

    // Assume droplet region is darker than bright background just above baseline.
    final threshold = q10 + 0.45 * (q90 - q10);
    final isDark = List<bool>.filled(width, false);
    for (int x = 0; x < width; x++) {
      isDark[x] = smooth[x] <= threshold;
    }

    int bestL = -1;
    int bestR = -1;
    double bestScore = double.negativeInfinity;
    int curL = -1;

    final bodySorted = List<double>.from(smoothBody)..sort();
    final b10 = bodySorted[
        (bodySorted.length * 0.10).floor().clamp(0, bodySorted.length - 1)];
    final b90 = bodySorted[
        (bodySorted.length * 0.90).floor().clamp(0, bodySorted.length - 1)];
    final bodyThreshold = b10 + 0.40 * (b90 - b10);
    final bodyDark = List<bool>.filled(width, false);
    for (int x = 0; x < width; x++) {
      bodyDark[x] = smoothBody[x] <= bodyThreshold;
    }
    int coreL = -1;
    int coreR = -1;
    int runL = -1;
    int bestCoreLen = 0;
    for (int x = 0; x < width; x++) {
      if (bodyDark[x]) {
        runL = runL == -1 ? x : runL;
      } else if (runL != -1) {
        final rr = x - 1;
        final len = rr - runL + 1;
        if (len > bestCoreLen) {
          bestCoreLen = len;
          coreL = runL;
          coreR = rr;
        }
        runL = -1;
      }
    }
    if (runL != -1) {
      final rr = width - 1;
      final len = rr - runL + 1;
      if (len > bestCoreLen) {
        bestCoreLen = len;
        coreL = runL;
        coreR = rr;
      }
    }

    final hintCenter = (hintCenterX != null && hintCenterX.isFinite)
        ? hintCenterX.clamp(0.0, width - 1.0)
        : double.nan;
    final hintSpanSafe =
        (hintSpan != null && hintSpan.isFinite && hintSpan > 2.0)
            ? hintSpan.clamp(2.0, width.toDouble())
            : double.nan;
    final coreCenter =
        (coreL >= 0 && coreR >= coreL) ? (coreL + coreR) * 0.5 : double.nan;
    final coreSpan = (coreL >= 0 && coreR >= coreL)
        ? (coreR - coreL + 1).toDouble()
        : double.nan;
    final coreWeight =
        (bestCoreLen / math.max(10.0, width * 0.20)).clamp(0.0, 1.0);

    double priorCenter = width * 0.5;
    if (coreCenter.isFinite && hintCenter.isFinite) {
      priorCenter = (coreWeight * coreCenter + (1.0 - coreWeight) * hintCenter)
          .clamp(0.0, width - 1.0);
    } else if (coreCenter.isFinite) {
      priorCenter = coreCenter;
    } else if (hintCenter.isFinite) {
      priorCenter = hintCenter;
    }
    double priorSpan = double.nan;
    if (coreSpan.isFinite && hintSpanSafe.isFinite) {
      priorSpan = (coreWeight * coreSpan + (1.0 - coreWeight) * hintSpanSafe)
          .clamp(2.0, width.toDouble());
    } else if (coreSpan.isFinite) {
      priorSpan = coreSpan;
    } else if (hintSpanSafe.isFinite) {
      priorSpan = hintSpanSafe;
    }

    double runScore(int l, int r) {
      final len = r - l + 1;
      if (len < 8) return double.negativeInfinity;
      final center = (l + r) * 0.5;
      final widthRatio = len / math.max(1.0, width.toDouble());
      final centerDist =
          (center - priorCenter).abs() / math.max(8.0, width * 0.5);
      final centerScore = math.exp(-math.pow(centerDist / 0.55, 2));
      final widthScore = priorSpan.isFinite
          ? math.exp(-math.pow(
              (len - priorSpan).abs() / math.max(12.0, priorSpan * 0.50), 2))
          : math.exp(-math.pow((widthRatio - 0.18).abs() / 0.22, 2));
      if (widthRatio > 0.82 && !priorSpan.isFinite)
        return double.negativeInfinity;

      final leftGrad = (l > 0) ? (smooth[l] - smooth[l - 1]).abs() : 0.0;
      final rightGrad =
          (r + 1 < width) ? (smooth[r + 1] - smooth[r]).abs() : 0.0;
      final edgeScore = ((leftGrad + rightGrad) / 2.0 / 22.0).clamp(0.2, 1.0);
      final coreAgreement = coreCenter.isFinite
          ? math.exp(-math.pow(
              (center - coreCenter).abs() / math.max(12.0, width * 0.18), 2))
          : 0.7;

      return len *
          (0.42 + 0.58 * centerScore) *
          (0.45 + 0.55 * widthScore) *
          edgeScore *
          (0.45 + 0.55 * coreAgreement);
    }

    for (int x = 0; x < width; x++) {
      if (isDark[x]) {
        curL = curL == -1 ? x : curL;
      } else if (curL != -1) {
        final curR = x - 1;
        final score = runScore(curL, curR);
        if (score > bestScore) {
          bestScore = score;
          bestL = curL;
          bestR = curR;
        }
        curL = -1;
      }
    }
    if (curL != -1) {
      final curR = width - 1;
      final score = runScore(curL, curR);
      if (score > bestScore) {
        bestScore = score;
        bestL = curL;
        bestR = curR;
      }
    }

    if (bestL < 0 || bestR < 0 || bestR - bestL + 1 < 8) {
      return {'leftX': double.nan, 'rightX': double.nan, 'confidence': 0.0};
    }

    // Refine edges by local gradient maxima around each boundary.
    int refineLeft = bestL;
    int refineRight = bestR;
    double leftBestGrad = 0.0;
    double rightBestGrad = 0.0;
    for (int x = math.max(1, bestL - 6);
        x <= math.min(width - 2, bestL + 6);
        x++) {
      final g = (smooth[x + 1] - smooth[x - 1]).abs();
      if (g > leftBestGrad) {
        leftBestGrad = g;
        refineLeft = x;
      }
    }
    for (int x = math.max(1, bestR - 6);
        x <= math.min(width - 2, bestR + 6);
        x++) {
      final g = (smooth[x + 1] - smooth[x - 1]).abs();
      if (g > rightBestGrad) {
        rightBestGrad = g;
        refineRight = x;
      }
    }
    if (refineRight > refineLeft + 3) {
      bestL = refineLeft;
      bestR = refineRight;
    }

    final bestLen = bestR - bestL + 1;
    final centerPenalty = ((bestL + bestR) * 0.5 - priorCenter).abs() /
        math.max(1.0, width * 0.5);
    final widthScore = priorSpan.isFinite
        ? math.exp(-math.pow(
            (bestLen - priorSpan).abs() / math.max(12.0, priorSpan * 0.50), 2))
        : (bestLen / math.max(1.0, width * 0.55)).clamp(0.0, 1.0);
    final edgeSharpness =
        ((leftBestGrad + rightBestGrad) / 2.0 / 24.0).clamp(0.0, 1.0);
    final confidence = (0.25 +
            0.45 * (contrast / 60.0).clamp(0.0, 1.0) +
            0.20 * widthScore +
            0.15 * edgeSharpness -
            0.25 * centerPenalty)
        .clamp(0.0, 1.0);

    return {
      'leftX': bestL.toDouble(),
      'rightX': bestR.toDouble(),
      'confidence': confidence,
    };
  }

  static Map<String, double>? _fallbackFromBinarySilhouette(
    List<int> gray,
    int width,
    int height,
    Map<String, dynamic> baseline,
  ) {
    if (gray.isEmpty || width < 24 || height < 24) return null;

    final baselineCenterY = _baselineYAtX(baseline, width * 0.5);
    final samples = <int>[];
    for (int x = 0; x < width; x += 2) {
      final yBase = _baselineYAtX(baseline, x.toDouble()).round();
      final yStart = math.max(0, yBase - 220);
      final yEnd = math.max(0, yBase - 3);
      for (int y = yStart; y <= yEnd; y += 2) {
        samples.add(gray[y * width + x]);
      }
    }
    if (samples.length < 50) return null;
    samples.sort();
    int q(double p) =>
        samples[(samples.length * p).floor().clamp(0, samples.length - 1)];
    final q20 = q(0.20).toDouble();
    final q35 = q(0.35).toDouble();
    final q50 = q(0.50).toDouble();
    final baseThreshold = math.min(150.0, q20 + 0.22 * (q50 - q20) + 12.0);
    final thresholds = <double>{
      (baseThreshold - 14.0).clamp(40.0, 190.0),
      baseThreshold.clamp(40.0, 190.0),
      (baseThreshold + 12.0).clamp(40.0, 190.0),
      (q35 + 14.0).clamp(40.0, 190.0),
    }.toList()
      ..sort();

    double bestScore = double.negativeInfinity;
    Map<String, double>? best;

    for (final darkThreshold in thresholds) {
      final mask = List<bool>.filled(width * height, false);
      for (int y = 1; y < height - 1; y++) {
        for (int x = 1; x < width - 1; x++) {
          final yBase = _baselineYAtX(baseline, x.toDouble());
          if (y >= yBase - 1.0) continue;
          if (gray[y * width + x] <= darkThreshold) {
            mask[y * width + x] = true;
          }
        }
      }

      final visited = List<bool>.filled(width * height, false);
      final queueX = <int>[];
      final queueY = <int>[];

      void push(int x, int y) {
        queueX.add(x);
        queueY.add(y);
      }

      for (int y0 = 1; y0 < height - 1; y0++) {
        for (int x0 = 1; x0 < width - 1; x0++) {
          final idx0 = y0 * width + x0;
          if (!mask[idx0] || visited[idx0]) continue;

          queueX.clear();
          queueY.clear();
          push(x0, y0);
          visited[idx0] = true;

          int area = 0;
          int minX = x0, maxX = x0, minY = y0, maxY = y0;
          int nearBaselineCount = 0;

          while (queueX.isNotEmpty) {
            final x = queueX.removeLast();
            final y = queueY.removeLast();
            area++;
            if (x < minX) minX = x;
            if (x > maxX) maxX = x;
            if (y < minY) minY = y;
            if (y > maxY) maxY = y;
            if (y >= baselineCenterY - 4.0) nearBaselineCount++;

            for (int dy = -1; dy <= 1; dy++) {
              for (int dx = -1; dx <= 1; dx++) {
                if (dx == 0 && dy == 0) continue;
                final nx = x + dx;
                final ny = y + dy;
                if (nx <= 0 || nx >= width - 1 || ny <= 0 || ny >= height - 1) {
                  continue;
                }
                final nIdx = ny * width + nx;
                if (visited[nIdx] || !mask[nIdx]) continue;
                visited[nIdx] = true;
                push(nx, ny);
              }
            }
          }

          if (area < 80) continue;
          final w = (maxX - minX + 1).toDouble();
          final h = (maxY - minY + 1).toDouble();
          if (w < 12 || h < 12) continue;
          final aspect = w / math.max(1.0, h);
          if (aspect < 0.35 || aspect > 2.8) continue;
          if (maxY < baselineCenterY - 10.0) continue;
          if (baselineCenterY - minY < 12.0) continue;

          final cx = (minX + maxX) * 0.5;
          final centerPenalty =
              (cx - width * 0.5).abs() / math.max(1.0, width * 0.5);
          final aspectPenalty = (aspect - 1.0).abs();
          final baselineSupport =
              nearBaselineCount / math.max(1.0, area.toDouble());
          final score = area * 0.02 +
              h * 1.8 +
              40.0 * baselineSupport -
              28.0 * centerPenalty -
              15.0 * aspectPenalty;

          if (score > bestScore) {
            final baseY = _baselineYAtX(baseline, cx);
            final a = w * 0.5;
            final hDrop = (baseY - minY).clamp(0.0, 1e9);
            if (a <= 2.0 || hDrop <= 2.0) continue;
            final theta = (2.0 * math.atan2(hDrop, a) * 180.0 / math.pi)
                .clamp(0.5, 179.5);
            final conf = (0.25 +
                    0.35 * (baselineSupport / 0.25).clamp(0.0, 1.0) +
                    0.20 * (1.0 - centerPenalty).clamp(0.0, 1.0) +
                    0.20 * (1.0 - aspectPenalty).clamp(0.0, 1.0))
                .clamp(0.0, 1.0);
            bestScore = score;
            best = {
              'angle': theta,
              'angle_left': theta,
              'angle_right': theta,
              'left_x': minX.toDouble(),
              'right_x': maxX.toDouble(),
              'apex_y': minY.toDouble(),
              'confidence': conf,
            };
          }
        }
      }
    }

    return best;
  }

  /// Main image processing pipeline
  static Future<Map<String, dynamic>> processImage(
    File imageFile, {
    ScaleCalibration? calibration,
    DropRoi? roi,
  }) async {
    try {
      _log('🔍 Starting scientific image processing: ${imageFile.path}');

      final Uint8List bytes = await imageFile.readAsBytes();
      imglib.Image? src = imglib.decodeImage(bytes);
      if (src == null) {
        return {
          'text': '❌ Failed to decode image. Try a different file.',
          'annotated': null
        };
      }
      // Phone-camera photos carry an EXIF orientation flag; the decoded pixels
      // may be sideways/upside-down. Bake the orientation into the pixels so the
      // drop is upright (drop above, substrate below) — otherwise the geometry
      // stage finds nothing "above the baseline". No-op for already-upright
      // images (e.g. the PFOTES test set).
      src = imglib.bakeOrientation(src);
      // Remove letterbox / uniform dark margins (common in screenshots and
      // cropped captures) before any polarity/geometry analysis.
      src = _autoCropDarkBorders(src);

      final autoCalibration =
          calibration == null ? detectAutoCalibration(src, bytes) : null;
      final effectiveCalibration = calibration ?? autoCalibration;
      final scaleSource =
          effectiveCalibration?.source ?? 'fallback_approximate';
      final loadedAngleCalibration = await _loadAngleCalibrationProfile();
      final angleCalibration =
          _isCalibrationProfileUsable(loadedAngleCalibration)
              ? loadedAngleCalibration
              : AngleCalibrationProfile.identity(
                  source: 'disabled_untrusted_profile');

      _log('📐 Image size: ${src.width}x${src.height}');

      // Convert to grayscale
      imglib.Image gray = imglib.grayscale(src);
      int width = gray.width;
      int height = gray.height;

      // Extract grayscale values
      List<int> grayValues = List.filled(width * height, 0);
      double meanIntensity = 0.0;
      for (int y = 0; y < height; y++) {
        for (int x = 0; x < width; x++) {
          final px = gray.getPixel(x, y);
          final r = _getRed(px);
          grayValues[y * width + x] = r;
          meanIntensity += r;
        }
      }
      meanIntensity /= (width * height);
      _log('💡 Mean intensity: ${meanIntensity.toStringAsFixed(1)}');

      bool inverted = false;
      // Determine background polarity by sampling image corners,
      // which are far from the drop and represent true background.
      // This is more reliable than global mean, which is skewed by
      // mixed images (bright sky + dark surface).
      double cornerMean = 0.0;
      int cornerCount = 0;
      final cornerW = (width * 0.12).round().clamp(8, 80);
      final cornerH = (height * 0.12).round().clamp(8, 60);
      // Sample: top-left, top-right, top-center
      for (final region in [
        [0, 0, cornerW, cornerH], // top-left
        [width - cornerW, 0, width, cornerH], // top-right
        [
          (width ~/ 2) - cornerW ~/ 2,
          0,
          (width ~/ 2) + cornerW ~/ 2,
          cornerH
        ], // top-center
      ]) {
        for (int y = region[1]; y < region[3] && y < height; y++) {
          for (int x = region[0]; x < region[2] && x < width; x++) {
            cornerMean += grayValues[y * width + x];
            cornerCount++;
          }
        }
      }
      if (cornerCount > 0) cornerMean /= cornerCount;
      _log('💡 Mean intensity: ${meanIntensity.toStringAsFixed(1)}, '
          'corner mean: ${cornerMean.toStringAsFixed(1)}');

      // If the background (corners) is dark, the image needs inversion
      // to produce a dark-droplet-on-light-background silhouette.
      // Use corner mean with a conservative threshold.
      if (cornerMean < 100) {
        for (int i = 0; i < grayValues.length; i++) {
          grayValues[i] = 255 - grayValues[i];
        }
        inverted = true;
        _log('🔄 Image inverted (dark background detected from corners)');
      }

      // ============ ROBUST BACK-LIT SILHOUETTE EXTRACTION ============
      // Preferred geometry path for back-lit drops (the standard lab capture):
      // threshold the bright background, locate the substrate baseline, and
      // trace the drop's outer silhouette. This is immune to the dark-drop /
      // dark-substrate merge and to interior refraction windows that defeat
      // gradient edge detection. Falls back to the legacy edge pipeline when
      // the scene is not a confident silhouette.
      final silhouette = SilhouetteExtractor.extract(grayValues, width, height,
          inverted: inverted, roi: roi);
      final bool useSilhouette =
          silhouette != null && silhouette.confidence >= 0.55;
      if (silhouette == null &&
          SilhouetteExtractor.lastRejectReason.isNotEmpty) {
        _log('🪟 Silhouette extractor rejected: '
            '${SilhouetteExtractor.lastRejectReason}');
      }
      if (useSilhouette) {
        _log('🪟 Silhouette extractor: ${silhouette.contour.length} points, '
            'conf=${silhouette.confidence.toStringAsFixed(2)}, '
            'contrast=${silhouette.contrast.toStringAsFixed(0)}, '
            'drop=${silhouette.dropWidth.toStringAsFixed(0)}x${silhouette.dropHeight.toStringAsFixed(0)} '
            '(Otsu=${silhouette.otsuThreshold.toStringAsFixed(0)})');
      } else {
        _log('🪟 Silhouette extractor not confident; using legacy edge path');
      }

      // Sub-pixel edge detection
      var subPixelEdges = SubPixelEdgeDetector.detectEdges(
        grayValues,
        width,
        height,
        lowThreshold: 25.0,
        highThreshold: 70.0,
        sigma: 1.2,
      );
      _log('🔬 Sub-pixel edges detected: ${subPixelEdges.length} points');

      // Fallback to integer edges if sub-pixel detection fails
      if (subPixelEdges.length < 50) {
        subPixelEdges = _detectEdgesInteger(grayValues, width, height);
        _log(
            '⚠️ Fallback to integer edge detection: ${subPixelEdges.length} points');
      }

      // Suppress boundary artifacts from image/frame borders.
      // Use a generous margin to ensure frame edges are never part of
      // the droplet contour.
      subPixelEdges = subPixelEdges
          .where(
            (p) =>
                p.x > 10.0 &&
                p.x < width - 11.0 &&
                p.y > 10.0 &&
                p.y < height - 11.0,
          )
          .toList();
      _log('🧹 Edge points after border suppression: ${subPixelEdges.length}');

      // Connected components to find largest droplet (or the robust silhouette).
      var contour = useSilhouette
          ? silhouette.contour
          : _extractLargestContour(subPixelEdges, width, height);

      if (!useSilhouette) {
        // ============ INTENSITY-AWARE REFLECTION FILTERING ============
        // For each edge point, check the pixel intensity ABOVE it (the
        // droplet side).  True droplet silhouette edges have dark pixels
        // above; reflection/gap boundary edges have bright pixels above.
        // This removes the reflection edges that would otherwise pull the
        // baseline downward and widen the contact span.
        contour = _filterReflectionEdges(contour, grayValues, width, height,
            inverted: inverted);
        _log('📊 Contour after reflection filter: ${contour.length} points');

        if (contour.length < 80) {
          _log('⚠️ Sparse contour detected; retrying with sensitive edge mode');
          var retryEdges = _detectEdgesAdaptive(
            grayValues,
            width,
            height,
            sensitive: true,
          );
          retryEdges = retryEdges
              .where(
                (p) =>
                    p.x > 6.0 &&
                    p.x < width - 7.0 &&
                    p.y > 6.0 &&
                    p.y < height - 7.0,
              )
              .toList();
          var retryContour = _extractLargestContour(retryEdges, width, height);
          retryContour = _filterReflectionEdges(
            retryContour,
            grayValues,
            width,
            height,
            inverted: inverted,
          );
          if (retryContour.length > contour.length) {
            contour = retryContour;
            _log('✅ Sensitive retry accepted: ${contour.length} points');
          } else {
            _log(
                'ℹ️ Sensitive retry kept original contour (${contour.length} points)');
          }
        }
      }

      if (contour.length < 20) {
        return {
          'text':
              '❌ No droplet detected. Try higher contrast / clearer silhouette.',
          'annotated': null
        };
      }
      // ============ BASELINE + COORDINATE NORMALIZATION ============
      // On horizontal fast-path, this is the exact legacy path.
      // On sloped path, the image is already leveled so the baseline
      // detected here will be near-horizontal.
      var baselineResult = useSilhouette
          ? Map<String, dynamic>.from(silhouette.baselineResult)
          : Map<String, dynamic>.from(_detectBaseline(contour));
      baselineResult['source'] = baselineResult['source'] ?? 'contour';
      final intensityBaseline =
          _detectBaselineFromIntensity(grayValues, width, height);
      if (useSilhouette) {
        _log('🧭 Baseline from silhouette substrate model '
            '(slope=${(baselineResult['slope'] as num).toStringAsFixed(4)}, '
            'y=${_baselineYAtX(baselineResult, width * 0.5).toStringAsFixed(1)})');
      } else {
        final contourBaselineScore = _baselineQualityScore(baselineResult);
        final intensityBaselineScore = _baselineQualityScore(intensityBaseline);
        if (intensityBaselineScore > contourBaselineScore + 0.03) {
          baselineResult = intensityBaseline;
          _log('🧭 Baseline selected from intensity model '
              '(score=${intensityBaselineScore.toStringAsFixed(2)}, '
              'contour=${contourBaselineScore.toStringAsFixed(2)})');
        } else {
          _log('🧭 Baseline selected from contour model '
              '(score=${contourBaselineScore.toStringAsFixed(2)}, '
              'intensity=${intensityBaselineScore.toStringAsFixed(2)})');
        }
      }
      final baselineYCenterInitial = _baselineYAtX(baselineResult, width * 0.5);
      final baselineLooksImplausible = baselineYCenterInitial < height * 0.25 ||
          baselineYCenterInitial > height * 0.98;
      if (baselineLooksImplausible && !useSilhouette) {
        baselineResult = intensityBaseline;
        _log(
            '🧭 Baseline overridden by intensity (implausible contour baseline '
            'at y=${baselineYCenterInitial.toStringAsFixed(1)})');
      }
      double baselineAngle = (baselineResult['angle'] as num).toDouble();
      double baselineConfidence =
          ((baselineResult['confidence'] as num?)?.toDouble() ?? 0.0)
              .clamp(0.0, 1.0);
      final bool isSlopedSurface = baselineAngle.abs() >= 0.5;
      double appliedRotationDeg = 0.0;
      var workingSrc = src;

      // Double rotation correction: if residual baseline tilt > 1° after
      // first rotation, apply a second micro-rotation to fully level.
      // (Skipped for the silhouette path, where tilt is handled analytically
      // by the baseline-frame transform without re-running edge detection.)
      if (!useSilhouette && isSlopedSurface && baselineAngle.abs() > 1.0) {
        final secondRotation = -baselineAngle;
        appliedRotationDeg += secondRotation;
        _log(
            '🔄 Double rotation: second micro-rotation ${secondRotation.toStringAsFixed(2)}° (total=${appliedRotationDeg.toStringAsFixed(2)}°)');

        workingSrc = _rotateImage(src, appliedRotationDeg);
        gray = imglib.grayscale(workingSrc);
        // Rotated image may have different dimensions — use the new ones.
        final rotW = gray.width;
        final rotH = gray.height;
        width = rotW;
        height = rotH;
        grayValues = List.filled(rotW * rotH, 0);
        for (int y = 0; y < rotH; y++) {
          for (int x = 0; x < rotW; x++) {
            grayValues[y * rotW + x] = _getRed(gray.getPixel(x, y));
          }
        }
        if (inverted) {
          for (int i = 0; i < grayValues.length; i++) {
            grayValues[i] = 255 - grayValues[i];
          }
        }
        subPixelEdges =
            _detectEdgesAdaptive(grayValues, rotW, rotH, sensitive: false);
        subPixelEdges = subPixelEdges
            .where(
              (p) =>
                  p.x > 10.0 &&
                  p.x < rotW - 11.0 &&
                  p.y > 10.0 &&
                  p.y < rotH - 11.0,
            )
            .toList();
        contour = _extractLargestContour(subPixelEdges, rotW, rotH);
        contour = _filterReflectionEdges(
          contour,
          grayValues,
          rotW,
          rotH,
          inverted: inverted,
        );
        baselineResult = Map<String, dynamic>.from(_detectBaseline(contour));
        baselineResult['source'] = baselineResult['source'] ?? 'contour';
        final intensityBaselineRot =
            _detectBaselineFromIntensity(grayValues, rotW, rotH);
        final contourBaselineScoreRot = _baselineQualityScore(baselineResult);
        final intensityBaselineScoreRot =
            _baselineQualityScore(intensityBaselineRot);
        if (intensityBaselineScoreRot > contourBaselineScoreRot + 0.03) {
          baselineResult = intensityBaselineRot;
          _log('🧭 Rotated baseline selected from intensity model '
              '(score=${intensityBaselineScoreRot.toStringAsFixed(2)}, '
              'contour=${contourBaselineScoreRot.toStringAsFixed(2)})');
        }
        final baselineYCenterRot = _baselineYAtX(baselineResult, rotW * 0.5);
        final baselineRotImplausible = baselineYCenterRot < rotH * 0.25 ||
            baselineYCenterRot > rotH * 0.98;
        if (baselineRotImplausible) {
          baselineResult = intensityBaselineRot;
          _log('🧭 Rotated baseline overridden by intensity (implausible y='
              '${baselineYCenterRot.toStringAsFixed(1)})');
        }
        baselineAngle = (baselineResult['angle'] as num).toDouble();
        baselineConfidence =
            ((baselineResult['confidence'] as num?)?.toDouble() ?? 0.0)
                .clamp(0.0, 1.0);
      }
      final baselineRms =
          ((baselineResult['rms'] as num?)?.toDouble() ?? double.infinity)
              .abs();
      if (baselineConfidence < 0.06 &&
          (!baselineRms.isFinite || baselineRms > 3.4)) {
        _log(
            '⚠️ Baseline is weak (conf=${baselineConfidence.toStringAsFixed(2)}, '
            'rms=${baselineRms.isFinite ? baselineRms.toStringAsFixed(2) : 'inf'}), continuing with reduced confidence');
      }

      var contourAligned =
          contour.map((p) => _toBaselineFrame(p, baselineResult)).toList();

      // The silhouette extractor already returns a clean, drop-only outline,
      // so skip component re-isolation (which can split or truncate it).
      var dropContourAligned = useSilhouette
          ? contourAligned
          : _extractDropContourAligned(contourAligned);
      _log(
          '🫧 Drop contour: ${dropContourAligned.length} points (from ${contourAligned.length} aligned)');

      if (dropContourAligned.length < 24) {
        // Fallback: relax extraction while still constraining to the droplet's
        // likely horizontal neighborhood (to avoid frame/substrate components).
        final aboveBaseline = contourAligned.where((p) => p.y < 0.5).toList();
        if (aboveBaseline.isNotEmpty) {
          final minY = aboveBaseline.map((p) => p.y).reduce(math.min);
          final maxY = aboveBaseline.map((p) => p.y).reduce(math.max);
          final ySpan = math.max(1e-6, maxY - minY);
          final topBand =
              aboveBaseline.where((p) => p.y <= minY + 0.35 * ySpan).toList();
          final centerGuess = topBand.isNotEmpty
              ? topBand.map((p) => p.x).reduce((a, b) => a + b) / topBand.length
              : (aboveBaseline.map((p) => p.x).reduce(math.min) +
                      aboveBaseline.map((p) => p.x).reduce(math.max)) *
                  0.5;
          final xMin = aboveBaseline.map((p) => p.x).reduce(math.min);
          final xMax = aboveBaseline.map((p) => p.x).reduce(math.max);
          final window = ((xMax - xMin) * 0.28)
              .clamp(45.0, math.max(80.0, (xMax - xMin) * 0.45));
          final focused = aboveBaseline
              .where((p) => (p.x - centerGuess).abs() <= window)
              .toList();
          dropContourAligned = focused.length >= 16 ? focused : aboveBaseline;
        } else {
          dropContourAligned = aboveBaseline;
        }
        _log(
            '⚠️ Drop extraction fallback: ${dropContourAligned.length} points near center');
        if (dropContourAligned.length < 16) {
          final silhouetteFallback = _fallbackFromBinarySilhouette(
            grayValues,
            width,
            height,
            baselineResult,
          );
          if (silhouetteFallback != null &&
              _isAnglePlausible(silhouetteFallback['angle'] ?? double.nan) &&
              (silhouetteFallback['confidence'] ?? 0.0) >= 0.12) {
            final theta = (silhouetteFallback['angle'] as num).toDouble();
            return {
              'text':
                  '🎯 Contact Angle: ${theta.toStringAsFixed(2)}° ± 8.00°\n\n'
                      'Fallback: silhouette-cap (low contour support)',
              'annotated': null,
              'angle_numeric': theta,
              'angle_left': theta,
              'angle_right': theta,
              'uncertainty_numeric': 8.0,
              'baseline_tilt': baselineAngle,
              'baseline_confidence': baselineConfidence,
              'baseline_source': baselineResult['source'] ?? 'contour',
              'contact_confidence':
                  (silhouetteFallback['confidence'] as num).toDouble(),
              'method_quality': {
                'polynomial': {
                  'is_valid': true,
                  'invalid_reason': null,
                  'fit_variant': 'silhouette_cap',
                }
              },
              'contour_aligned_count': contourAligned.length,
              'drop_contour_aligned_count': dropContourAligned.length,
              'silhouette_fallback': silhouetteFallback,
              'surface_type': theta >= 150
                  ? 'Superhydrophobic'
                  : (theta >= 90 ? 'Hydrophobic' : 'Hydrophilic'),
            };
          }
          return {
            'text':
                '❌ Could not isolate droplet contour from background edges.',
            'annotated': null,
            'baseline_tilt': baselineAngle,
            'baseline_confidence': baselineConfidence,
            'baseline_source': baselineResult['source'] ?? 'contour',
            'contour_aligned_count': contourAligned.length,
            'drop_contour_aligned_count': dropContourAligned.length,
          };
        }
      }

      // Strict contact detection: use ONLY upper contour points above baseline.
      final dropMinX = dropContourAligned.map((p) => p.x).reduce(math.min);
      final dropMaxX = dropContourAligned.map((p) => p.x).reduce(math.max);
      final dropSpan = (dropMaxX - dropMinX).abs();
      final contactPad = (dropSpan * 0.55).clamp(18.0, 140.0);
      final strictContactContour = <math.Point<double>>[
        ...dropContourAligned,
        ...contourAligned.where((p) =>
            p.y <= 0.25 &&
            p.y >= -5.0 &&
            p.x >= dropMinX - contactPad &&
            p.x <= dropMaxX + contactPad),
      ];
      final contactResult = _detectContactPoints(
        strictContactContour,
        fallbackContourAligned: strictContactContour,
      );
      double leftXAligned = contactResult['leftX']!;
      double rightXAligned = contactResult['rightX']!;
      double leftContactConfidence =
          (contactResult['left_confidence'] ?? 0.0).clamp(0.0, 1.0);
      double rightContactConfidence =
          (contactResult['right_confidence'] ?? 0.0).clamp(0.0, 1.0);
      final double contactSlopeLeft =
          (contactResult['left_slope'] ?? double.nan).toDouble();
      final double contactSlopeRight =
          (contactResult['right_slope'] ?? double.nan).toDouble();
      double contactConfidence =
          ((leftContactConfidence + rightContactConfidence) / 2.0)
              .clamp(0.0, 1.0);
      const double baselineY = 0.0;

      final apexAligned =
          dropContourAligned.reduce((a, b) => a.y < b.y ? a : b);
      final apexXGlobal = apexAligned.x;
      final contourSpanGeom = (dropContourAligned.isNotEmpty)
          ? (dropContourAligned.map((p) => p.x).reduce(math.max) -
              dropContourAligned.map((p) => p.x).reduce(math.min))
          : 0.0;
      final hintLeftOriginal =
          _fromBaselineFrame(math.Point(dropMinX, 0.0), baselineResult).x;
      final hintRightOriginal =
          _fromBaselineFrame(math.Point(dropMaxX, 0.0), baselineResult).x;
      final hintCenterOriginal = (hintLeftOriginal + hintRightOriginal) * 0.5;
      final hintSpanOriginal = (hintRightOriginal - hintLeftOriginal).abs();
      final intensityContact = _estimateContactFromIntensity(
        grayValues,
        width,
        height,
        baselineResult,
        hintCenterX: hintCenterOriginal,
        hintSpan: hintSpanOriginal,
      );
      final intensityContactConfidence =
          ((intensityContact['confidence'] ?? 0.0).toDouble()).clamp(0.0, 1.0);
      final intensityLeftOrig = intensityContact['leftX'] ?? double.nan;
      final intensityRightOrig = intensityContact['rightX'] ?? double.nan;
      double intensityLeftAligned = double.nan;
      double intensityRightAligned = double.nan;
      if (intensityLeftOrig.isFinite && intensityRightOrig.isFinite) {
        final pL = _toBaselineFrame(
          math.Point(
            intensityLeftOrig,
            _baselineYAtX(baselineResult, intensityLeftOrig),
          ),
          baselineResult,
        );
        final pR = _toBaselineFrame(
          math.Point(
            intensityRightOrig,
            _baselineYAtX(baselineResult, intensityRightOrig),
          ),
          baselineResult,
        );
        intensityLeftAligned = pL.x;
        intensityRightAligned = pR.x;
        final intensitySpan =
            (intensityRightAligned - intensityLeftAligned).abs();
        final geomSpanNow = (rightXAligned - leftXAligned).abs();
        final intensitySpanPlausible = intensitySpan > 6.0 &&
            intensitySpan >= contourSpanGeom * 0.20 &&
            intensitySpan <= contourSpanGeom * 1.80;
        final geomSpanImplausible = geomSpanNow < contourSpanGeom * 0.18 ||
            geomSpanNow > contourSpanGeom * 2.20;
        final useIntensityOverride = intensitySpanPlausible &&
            (geomSpanImplausible ||
                !leftXAligned.isFinite ||
                !rightXAligned.isFinite);
        if (useIntensityOverride) {
          leftXAligned = intensityLeftAligned;
          rightXAligned = intensityRightAligned;
          leftContactConfidence = intensityContactConfidence;
          rightContactConfidence = intensityContactConfidence;
          contactConfidence = intensityContactConfidence;
        } else if (intensitySpanPlausible &&
            intensityContactConfidence >= 0.25 &&
            contactConfidence <= 0.30 &&
            leftXAligned.isFinite &&
            rightXAligned.isFinite) {
          final blend =
              (0.25 + 0.45 * intensityContactConfidence).clamp(0.20, 0.65);
          leftXAligned =
              (1.0 - blend) * leftXAligned + blend * intensityLeftAligned;
          rightXAligned =
              (1.0 - blend) * rightXAligned + blend * intensityRightAligned;
          leftContactConfidence = math.max(
              leftContactConfidence, intensityContactConfidence * 0.85);
          rightContactConfidence = math.max(
              rightContactConfidence, intensityContactConfidence * 0.85);
          contactConfidence =
              ((leftContactConfidence + rightContactConfidence) * 0.5)
                  .clamp(0.0, 1.0);
        }
      }
      final minSpanAllowed = math.max(10.0, contourSpanGeom * 0.30);

      double robustApexX(double leftX, double rightX) {
        if (!leftX.isFinite || !rightX.isFinite || rightX <= leftX + 3.0) {
          return apexXGlobal;
        }
        final span = rightX - leftX;
        List<math.Point<double>> candidates(double frac) => dropContourAligned
            .where(
              (p) =>
                  p.y < -1.0 &&
                  p.x >= leftX + frac * span &&
                  p.x <= rightX - frac * span,
            )
            .toList();

        var local = candidates(0.18);
        if (local.length < 6) local = candidates(0.10);
        if (local.length < 6) local = candidates(0.05);
        if (local.length < 6) return (leftX + rightX) * 0.5;
        return local.reduce((a, b) => a.y < b.y ? a : b).x;
      }

      bool contactsValid() {
        final apexXAligned = robustApexX(leftXAligned, rightXAligned);
        if (!leftXAligned.isFinite || !rightXAligned.isFinite) return false;
        if (rightXAligned <= leftXAligned + 3.0) return false;
        if (rightXAligned - leftXAligned < minSpanAllowed) return false;
        if (leftXAligned >= apexXAligned - 1.5) return false;
        if (rightXAligned <= apexXAligned + 1.5) return false;
        return true;
      }

      if (!contactsValid()) {
        final silhouetteFallback = _fallbackFromBinarySilhouette(
          grayValues,
          width,
          height,
          baselineResult,
        );
        if (silhouetteFallback != null) {
          final sLeft = (silhouetteFallback['left_x'] ?? double.nan).toDouble();
          final sRight =
              (silhouetteFallback['right_x'] ?? double.nan).toDouble();
          if (sLeft.isFinite && sRight.isFinite && sRight > sLeft + 6.0) {
            final sLeftAligned = _toBaselineFrame(
              math.Point(
                sLeft,
                _baselineYAtX(baselineResult, sLeft),
              ),
              baselineResult,
            ).x;
            final sRightAligned = _toBaselineFrame(
              math.Point(
                sRight,
                _baselineYAtX(baselineResult, sRight),
              ),
              baselineResult,
            ).x;
            if (sRightAligned > sLeftAligned + minSpanAllowed * 0.65) {
              leftXAligned = sLeftAligned;
              rightXAligned = sRightAligned;
              final sConf =
                  ((silhouetteFallback['confidence'] ?? 0.0) as num).toDouble();
              leftContactConfidence =
                  math.max(leftContactConfidence, sConf * 0.80);
              rightContactConfidence =
                  math.max(rightContactConfidence, sConf * 0.80);
              contactConfidence =
                  ((leftContactConfidence + rightContactConfidence) * 0.5)
                      .clamp(0.0, 1.0);
            }
          }
        }
      }

      if (!contactsValid()) {
        _log('❌ Contact detection failed after fusion: '
            'left=$leftXAligned, right=$rightXAligned, '
            'apexX=${robustApexX(leftXAligned, rightXAligned)}, minSpan=${minSpanAllowed.toStringAsFixed(1)}');
        return {
          'text': '❌ Could not locate contact points reliably.',
          'annotated': null,
          'baseline_tilt': baselineAngle,
          'baseline_confidence': baselineConfidence,
          'baseline_source': baselineResult['source'] ?? 'contour',
          'contact_confidence': contactConfidence,
          'contact_confidence_left': leftContactConfidence,
          'contact_confidence_right': rightContactConfidence,
          'contact_left_x_aligned': leftXAligned,
          'contact_right_x_aligned': rightXAligned,
          'contact_apex_x_aligned': robustApexX(leftXAligned, rightXAligned),
          'contact_min_span_required': minSpanAllowed,
        };
      }
      if (contactConfidence < 0.08) {
        _log(
          '⚠️ Contact confidence low: '
          'left=${leftContactConfidence.toStringAsFixed(2)}, '
          'right=${rightContactConfidence.toStringAsFixed(2)}',
        );
      }

      final leftContactOriginal =
          _fromBaselineFrame(math.Point(leftXAligned, 0.0), baselineResult);
      final rightContactOriginal =
          _fromBaselineFrame(math.Point(rightXAligned, 0.0), baselineResult);

      _log(
          '📍 Baseline tilt=${baselineAngle.toStringAsFixed(2)}°, RMS=${(baselineResult['rms'] as num).toDouble().toStringAsFixed(2)} px');
      _log(
          '📍 Contacts (aligned): left=${leftXAligned.toStringAsFixed(2)}, right=${rightXAligned.toStringAsFixed(2)}, conf=${contactConfidence.toStringAsFixed(2)}');

      final double contactSpan = (rightXAligned - leftXAligned).abs();
      final double dropHeight = math.max(1e-6, -apexAligned.y);
      final double halfSpan = math.max(
        1e-6,
        contourSpanGeom > 2.0 ? contourSpanGeom * 0.5 : contactSpan * 0.5,
      );
      final double geometricPriorAngle =
          (2.0 * math.atan2(dropHeight, halfSpan) * 180.0 / math.pi)
              .clamp(1.0, 179.0);
      Map<String, double> regularizeSideAngles(double left, double right) {
        double l = left;
        double r = right;
        final lFinite = l.isFinite;
        final rFinite = r.isFinite;
        if (lFinite && !rFinite) r = l;
        if (!lFinite && rFinite) l = r;
        if (!l.isFinite || !r.isFinite) {
          return {'left': l, 'right': r, 'mean': (l + r) * 0.5};
        }
        final meanAngle = (l + r) * 0.5;
        final extremeButImplausible =
            (meanAngle > 170.0 && geometricPriorAngle < 155.0) ||
                (meanAngle < 8.0 && geometricPriorAngle > 20.0);
        if (extremeButImplausible && contactConfidence < 0.35) {
          l = geometricPriorAngle;
          r = geometricPriorAngle;
        }
        final extremeDisagreement = ((l > 170.0 && r < 170.0) ||
            (r > 170.0 && l < 170.0) ||
            (l < 10.0 && r > 10.0) ||
            (r < 10.0 && l > 10.0));
        if (extremeDisagreement) {
          final lDist = (l - geometricPriorAngle).abs();
          final rDist = (r - geometricPriorAngle).abs();
          if (lDist <= rDist) {
            r = l;
          } else {
            l = r;
          }
        }
        final mismatch = (l - r).abs();
        if (mismatch > 70.0) {
          final lDist = (l - geometricPriorAngle).abs();
          final rDist = (r - geometricPriorAngle).abs();
          if (lDist <= rDist) {
            r = l;
          } else {
            l = r;
          }
        }
        return {'left': l, 'right': r, 'mean': (l + r) * 0.5};
      }

      final symmetry = _computeSymmetryScore(
        dropContourAligned,
        leftXAligned,
        rightXAligned,
      );
      final symmetryScore = symmetry['score'] ?? 0.0;
      final symmetryResidual = symmetry['residual'] ?? double.infinity;
      _log(
        '🔁 Symmetry: score=${symmetryScore.toStringAsFixed(3)}, '
        'residual=${symmetryResidual.isFinite ? symmetryResidual.toStringAsFixed(3) : 'inf'}',
      );
      final contourPad = (contactSpan * 0.30).clamp(10.0, 45.0);
      final narrowedContourAligned = dropContourAligned
          .where(
            (p) =>
                p.y < -0.8 &&
                p.x >= leftXAligned - contourPad &&
                p.x <= rightXAligned + contourPad,
          )
          .toList();
      // For the silhouette path keep the FULL outline: for contact angles >90°
      // the drop bulges *beyond* the contact points, so narrowing to the
      // contact span would clip the very curvature that defines the angle.
      final analysisContourAligned = useSilhouette
          ? dropContourAligned.where((p) => p.y < -0.5).toList()
          : (narrowedContourAligned.length >= 24
              ? narrowedContourAligned
              : dropContourAligned);
      final analysisContour = analysisContourAligned
          .map((p) => _fromBaselineFrame(p, baselineResult))
          .toList();
      _log(
          '🔎 Analysis contour: ${analysisContourAligned.length} points (isolated=${dropContourAligned.length}, raw=${contourAligned.length})');

      // Prepare points for fitting (drop points are above baseline => y < 0 in aligned frame)
      List<double> xs = [], ys = [];
      List<math.Point<double>> leftPoints = [], rightPoints = [];
      final double midXAligned = (leftXAligned + rightXAligned) / 2.0;
      final double localWindow = (contactSpan * 0.35).clamp(24.0, 120.0);

      for (final p in analysisContourAligned) {
        if (p.y < -1.5) {
          xs.add(p.x);
          ys.add(p.y);
        }
      }

      for (final p in analysisContourAligned) {
        if (p.y > -140.0 && p.y < 1.0) {
          if (p.x <= midXAligned + 4.0 &&
              (p.x - leftXAligned).abs() <= localWindow) {
            leftPoints.add(p);
          }
          if (p.x >= midXAligned - 4.0 &&
              (p.x - rightXAligned).abs() <= localWindow) {
            rightPoints.add(p);
          }
        }
      }

      if (leftPoints.length < 6 || rightPoints.length < 6) {
        leftPoints.clear();
        rightPoints.clear();
        for (final p in contourAligned) {
          if (p.y > -160.0 &&
              p.y < 1.5 &&
              p.x >= leftXAligned - localWindow &&
              p.x <= rightXAligned + localWindow) {
            if (p.x <= midXAligned &&
                (p.x - leftXAligned).abs() <= localWindow) {
              leftPoints.add(p);
            }
            if (p.x >= midXAligned &&
                (p.x - rightXAligned).abs() <= localWindow) {
              rightPoints.add(p);
            }
          }
        }
      }

      if (xs.length < 6) {
        final silhouetteFallback = _fallbackFromBinarySilhouette(
          grayValues,
          width,
          height,
          baselineResult,
        );
        if (silhouetteFallback != null &&
            _isAnglePlausible(silhouetteFallback['angle'] ?? double.nan) &&
            (silhouetteFallback['confidence'] ?? 0.0) >= 0.12) {
          final theta = (silhouetteFallback['angle'] as num).toDouble();
          return {
            'text': '🎯 Contact Angle: ${theta.toStringAsFixed(2)}° ± 8.00°\n\n'
                'Fallback: silhouette-cap (sparse contour fit)',
            'annotated': null,
            'angle_numeric': theta,
            'angle_left': theta,
            'angle_right': theta,
            'uncertainty_numeric': 8.0,
            'baseline_tilt': baselineAngle,
            'baseline_confidence': baselineConfidence,
            'baseline_source': baselineResult['source'] ?? 'contour',
            'contact_confidence':
                (silhouetteFallback['confidence'] as num).toDouble(),
            'method_quality': {
              'polynomial': {
                'is_valid': true,
                'invalid_reason': null,
                'fit_variant': 'silhouette_cap',
              }
            },
            'contour_count': contour.length,
            'silhouette_fallback': silhouetteFallback,
            'surface_type': theta >= 150
                ? 'Superhydrophobic'
                : (theta >= 90 ? 'Hydrophobic' : 'Hydrophilic'),
          };
        }
        return {
          'text': '❌ Not enough points for fitting (${xs.length}).\n'
              'diag: silhouette=$useSilhouette, contour=${contour.length}, '
              'aligned=${contourAligned.length}, drop=${dropContourAligned.length}, '
              'baselineY=${_baselineYAtX(baselineResult, width * 0.5).toStringAsFixed(0)}, '
              'img=${width}x$height\n'
              'Tip: use a back-lit drop (dark drop on a bright, even background) '
              'and draw the ROI box snugly around the droplet.',
          'annotated': null
        };
      }

      // ============ MULTI-METHOD ANALYSIS ============

      Map<String, Map<String, dynamic>> methodResults = {};

      // Method 1: Circle fit
      try {
        var circle = AngleUtils.circleFit(xs, ys);
        double thetaCircle = AngleUtils.calculateCircleAngle(circle, baselineY);
        double rSqCircle = circle.length > 3 ? circle[3] : 0.8;
        final circleResult = {
          'angle': thetaCircle,
          'r_squared': rSqCircle,
          'params': circle,
          'left_contact_x': leftXAligned,
          'right_contact_x': rightXAligned,
          'baseline_y': baselineY,
          'contact_confidence': contactConfidence,
          'baseline_confidence': baselineConfidence,
          'symmetry_score': symmetryScore,
        };
        final calibratedCircle =
            _applyAngleCalibration(circleResult, angleCalibration);
        methodResults['circle'] =
            _validateMethodResult('circle', calibratedCircle);
        _log(
            '⭕ Circle: ${thetaCircle.toStringAsFixed(2)}° (R²=${rSqCircle.toStringAsFixed(3)})${_methodStatusSuffix(methodResults['circle']!)}');
      } catch (e) {
        _log('⚠️ Circle fit failed: $e');
        methodResults['circle'] = _invalidMethodResult('fit_failed');
      }

      // Method 2: Ellipse fit
      try {
        var ellipse = AngleUtils.ellipseFit(xs, ys);
        double thetaEllipseLeft = AngleUtils.calculateEllipseAngle(
          ellipse,
          baselineY,
          leftXAligned,
          true,
        );
        double thetaEllipseRight = AngleUtils.calculateEllipseAngle(
          ellipse,
          baselineY,
          rightXAligned,
          false,
        );
        double thetaEllipse = (thetaEllipseLeft + thetaEllipseRight) / 2.0;
        double rSqEllipse = ellipse.length > 5 ? ellipse[5] : 0.8;
        final ellipseResult = {
          'angle': thetaEllipse,
          'angle_left': thetaEllipseLeft,
          'angle_right': thetaEllipseRight,
          'r_squared': rSqEllipse,
          'params': ellipse,
          'contact_confidence': contactConfidence,
          'baseline_confidence': baselineConfidence,
          'symmetry_score': symmetryScore,
        };

        // Local circle fit (bottom 40% of drop contour — closest to baseline)
        List<math.Point<double>> bottomContour;
        if (xs.length >= 20) {
          final indexed = List.generate(xs.length, (i) => i);
          // Sort by y descending (least negative = closest to baseline)
          indexed.sort((a, b) => ys[b].compareTo(ys[a]));
          final count = (xs.length * 0.4).round();
          bottomContour =
              indexed.take(count).map((i) => math.Point(xs[i], ys[i])).toList();
        } else {
          bottomContour = <math.Point<double>>[];
        }
        if (bottomContour.length >= 10) {
          var localCircle = AngleUtils.circleFit(
              bottomContour.map((p) => p.x).toList(),
              bottomContour.map((p) => p.y).toList());
          if (localCircle.length > 3 && localCircle[3] > 0.98) {
            final localAngle =
                AngleUtils.calculateCircleAngle(localCircle, baselineY);
            final localCircleResult = _applyAngleCalibration(
              {
                'angle': localAngle,
                'r_squared': localCircle[3],
                'params': localCircle,
                'left_contact_x': leftXAligned,
                'right_contact_x': rightXAligned,
                'baseline_y': baselineY,
                'contact_confidence': contactConfidence,
                'baseline_confidence': baselineConfidence,
                'symmetry_score': symmetryScore,
              },
              angleCalibration,
            );
            methodResults['circle_local'] = _validateMethodResult(
              'circle',
              localCircleResult,
            );
          }
        }

        final calibratedEllipse =
            _applyAngleCalibration(ellipseResult, angleCalibration);
        methodResults['ellipse'] =
            _validateMethodResult('ellipse', calibratedEllipse);
        _log(
            '⬭ Ellipse: ${thetaEllipse.toStringAsFixed(2)}° (R²=${rSqEllipse.toStringAsFixed(3)})${_methodStatusSuffix(methodResults['ellipse']!)}');
      } catch (e) {
        _log('⚠️ Ellipse fit failed: $e');
        methodResults['ellipse'] = _invalidMethodResult('fit_failed');
      }

      // Method 3: Polynomial tangent (4th degree with weighting)
      try {
        final polyLeft = AngleUtils.polynomialAngleDetailed(
          leftPoints,
          leftXAligned,
          baselineY,
          true,
          degree: 4,
          useWeighting: true,
          contactSpan: contactSpan,
        );
        final polyRight = AngleUtils.polynomialAngleDetailed(
          rightPoints,
          rightXAligned,
          baselineY,
          false,
          degree: 4,
          useWeighting: true,
          contactSpan: contactSpan,
        );
        final tangentLeft = AngleUtils.localTangentAngleDetailed(
          leftPoints,
          leftXAligned,
          baselineY,
          true,
        );
        final tangentRight = AngleUtils.localTangentAngleDetailed(
          rightPoints,
          rightXAligned,
          baselineY,
          false,
        );
        double thetaPolyLeft = polyLeft['angle']!;
        double thetaPolyRight = polyRight['angle']!;
        final polyRegularized =
            regularizeSideAngles(thetaPolyLeft, thetaPolyRight);
        thetaPolyLeft = polyRegularized['left']!;
        thetaPolyRight = polyRegularized['right']!;
        double thetaPoly = (thetaPolyLeft + thetaPolyRight) / 2.0;
        double polyRSq =
            ((polyLeft['r_squared']! + polyRight['r_squared']!) / 2.0)
                .clamp(0.0, 1.0);
        String fitVariant = 'polynomial';
        final polyMismatch = (thetaPolyLeft - thetaPolyRight).abs();

        final tanLeftAngle = tangentLeft['angle'] ?? double.nan;
        final tanRightAngle = tangentRight['angle'] ?? double.nan;
        final tanLeftRSq = tangentLeft['r_squared'] ?? 0.0;
        final tanRightRSq = tangentRight['r_squared'] ?? 0.0;
        final tangentUsable = _isAnglePlausible(tanLeftAngle) &&
            _isAnglePlausible(tanRightAngle) &&
            tanLeftRSq >= 0.40 &&
            tanRightRSq >= 0.40;

        final polynomialLikelyUnstable = !_isAnglePlausible(thetaPolyLeft) ||
            !_isAnglePlausible(thetaPolyRight) ||
            polyRSq < 0.72 ||
            polyMismatch > 48.0;
        if (tangentUsable && polynomialLikelyUnstable) {
          thetaPolyLeft = tanLeftAngle;
          thetaPolyRight = tanRightAngle;
          final tanRegularized =
              regularizeSideAngles(thetaPolyLeft, thetaPolyRight);
          thetaPolyLeft = tanRegularized['left']!;
          thetaPolyRight = tanRegularized['right']!;
          thetaPoly = (thetaPolyLeft + thetaPolyRight) / 2.0;
          polyRSq = ((tanLeftRSq + tanRightRSq) / 2.0).clamp(0.0, 1.0);
          fitVariant = 'local_tangent';
        }

        final polyResult = {
          'angle': thetaPoly,
          'angle_left': thetaPolyLeft,
          'angle_right': thetaPolyRight,
          'r_squared': polyRSq,
          'used_points': leftPoints.length + rightPoints.length,
          'fit_variant': fitVariant,
          'contact_confidence': contactConfidence,
          'baseline_confidence': baselineConfidence,
          'symmetry_score': symmetryScore,
        };
        final calibratedPoly =
            _applyAngleCalibration(polyResult, angleCalibration);
        methodResults['polynomial'] =
            _validateMethodResult('polynomial', calibratedPoly);
        if (!_isMethodValid(methodResults['polynomial']) && tangentUsable) {
          final tangentFallback = {
            'angle': (tanLeftAngle + tanRightAngle) / 2.0,
            'angle_left': tanLeftAngle,
            'angle_right': tanRightAngle,
            'r_squared': ((tanLeftRSq + tanRightRSq) / 2.0).clamp(0.0, 1.0),
            'used_points': leftPoints.length + rightPoints.length,
            'fit_variant': 'local_tangent',
            'contact_confidence': contactConfidence,
            'baseline_confidence': baselineConfidence,
            'symmetry_score': symmetryScore,
          };
          final calibratedTangentFallback =
              _applyAngleCalibration(tangentFallback, angleCalibration);
          methodResults['polynomial'] =
              _validateMethodResult('polynomial', calibratedTangentFallback);
        }
        _log(
            '📈 Polynomial${fitVariant == 'local_tangent' ? ' (local tangent)' : ''}: '
            '${thetaPoly.toStringAsFixed(2)}° (R²=${polyRSq.toStringAsFixed(3)})'
            '${_methodStatusSuffix(methodResults['polynomial']!)}');
      } catch (e) {
        _log('⚠️ Polynomial fit failed: $e');
        methodResults['polynomial'] = _invalidMethodResult('fit_failed');
      }

      // Method 4: Young-Laplace (ADSA-style)
      try {
        var ylResult = YoungLaplaceSolver.fitContour(
          analysisContourAligned,
          baselineY,
          dropRadiusPixels: (rightXAligned - leftXAligned) / 2.0,
        );
        final ylMethodResult = {
          'angle': ylResult['contact_angle']!,
          'angle_left': ylResult['angle_left'] ?? ylResult['contact_angle']!,
          'angle_right': ylResult['angle_right'] ?? ylResult['contact_angle']!,
          'r_squared': ylResult['r_squared']!,
          'bond_number': ylResult['bond_number']!,
          'residual': ylResult['residual']!,
          'contact_confidence': contactConfidence,
          'baseline_confidence': baselineConfidence,
          'symmetry_score': symmetryScore,
        };
        final calibratedYL =
            _applyAngleCalibration(ylMethodResult, angleCalibration);
        methodResults['young_laplace'] =
            _validateMethodResult('young_laplace', calibratedYL);
        _log(
            '🔬 Young-Laplace: ${ylResult['contact_angle']!.toStringAsFixed(2)}° (Bo=${ylResult['bond_number']!.toStringAsFixed(3)})${_methodStatusSuffix(methodResults['young_laplace']!)}');
      } catch (e) {
        _log('⚠️ Young-Laplace fit failed: $e');
        methodResults['young_laplace'] = _invalidMethodResult('fit_failed');
      }

      methodResults = _applyCrossMethodConsistency(methodResults);

      // ============ ENSEMBLE ANGLE CALCULATION ============

      var ensembleResult = _calculateEnsembleAngle(methodResults);
      double thetaFinal = ensembleResult['angle'];
      double thetaLeft = ensembleResult['angle_left'];
      double thetaRight = ensembleResult['angle_right'];
      Map<String, double> weights = ensembleResult['weights'];
      final validMethodCountEarly =
          methodResults.values.where((m) => _isMethodValid(m)).length;
      if (!thetaFinal.isFinite || validMethodCountEarly == 0) {
        double slopeToAngle(double slope, bool isLeftSide) {
          if (!slope.isFinite) return 90.0;
          double tx = 1.0;
          double ty = slope;
          if (ty > 0.0) {
            tx = -tx;
            ty = -ty;
          }
          final norm = math.sqrt(tx * tx + ty * ty);
          if (!norm.isFinite || norm <= 1e-10) return 90.0;
          final substrateX = isLeftSide ? 1.0 : -1.0;
          final dot = (substrateX * (tx / norm)).clamp(-1.0, 1.0);
          return (math.acos(dot) * 180.0 / math.pi).clamp(0.5, 179.5);
        }

        final slopeLeftAngle = slopeToAngle(contactSlopeLeft, true);
        final slopeRightAngle = slopeToAngle(contactSlopeRight, false);
        final slopeRescueUsable = contactSlopeLeft.isFinite &&
            contactSlopeRight.isFinite &&
            _isAnglePlausible(slopeLeftAngle) &&
            _isAnglePlausible(slopeRightAngle);
        if (slopeRescueUsable) {
          final slopeMethod = _validateMethodResult('polynomial', {
            'angle': (slopeLeftAngle + slopeRightAngle) / 2.0,
            'angle_left': slopeLeftAngle,
            'angle_right': slopeRightAngle,
            'r_squared': 0.60,
            'used_points': 8.0,
            'fit_variant': 'local_tangent',
            'contact_confidence': contactConfidence,
            'baseline_confidence': baselineConfidence,
            'symmetry_score': symmetryScore,
          });
          if (_isMethodValid(slopeMethod)) {
            methodResults['polynomial'] = slopeMethod;
            ensembleResult = _calculateEnsembleAngle(methodResults);
            thetaFinal = ensembleResult['angle'];
            thetaLeft = ensembleResult['angle_left'];
            thetaRight = ensembleResult['angle_right'];
            weights = ensembleResult['weights'];
            _log('⚠️ Using strict contact-slope rescue for tangent angle.');
          }
        }

        if (thetaFinal.isFinite) {
          // Rescue succeeded; skip deeper fallback chain.
        } else {
          final rescueLeft = AngleUtils.localTangentAngleDetailed(
            leftPoints,
            leftXAligned,
            baselineY,
            true,
          );
          final rescueRight = AngleUtils.localTangentAngleDetailed(
            rightPoints,
            rightXAligned,
            baselineY,
            false,
          );
          final rescueRegularized = regularizeSideAngles(
            rescueLeft['angle'] ?? double.nan,
            rescueRight['angle'] ?? double.nan,
          );
          final rescueLeftAngle = rescueRegularized['left'] ?? double.nan;
          final rescueRightAngle = rescueRegularized['right'] ?? double.nan;
          final rescueRSq = ((rescueLeft['r_squared'] ?? 0.0) +
                  (rescueRight['r_squared'] ?? 0.0)) /
              2.0;
          final rescueUsable = _isAnglePlausible(rescueLeftAngle) &&
              _isAnglePlausible(rescueRightAngle) &&
              rescueRSq >= 0.35;
          var silhouetteFallback = _fallbackFromBinarySilhouette(
            grayValues,
            width,
            height,
            baselineResult,
          );
          final silhouetteConfPrimary =
              (silhouetteFallback?['confidence'] as num?)?.toDouble() ?? 0.0;
          if (silhouetteFallback == null || silhouetteConfPrimary < 0.18) {
            final altBaseline =
                _detectBaselineFromIntensity(grayValues, width, height);
            final silhouetteAlt = _fallbackFromBinarySilhouette(
              grayValues,
              width,
              height,
              altBaseline,
            );
            final altConf =
                (silhouetteAlt?['confidence'] as num?)?.toDouble() ?? 0.0;
            if (altConf > silhouetteConfPrimary) {
              silhouetteFallback = silhouetteAlt;
            }
          }
          final silhouetteUsable = silhouetteFallback != null &&
              _isAnglePlausible(silhouetteFallback['angle'] ?? double.nan) &&
              (silhouetteFallback['confidence'] ?? 0.0) >= 0.12;

          if (!rescueUsable) {
            if (silhouetteUsable) {
              final sil = silhouetteFallback;
              final silhouetteMethod = _validateMethodResult('polynomial', {
                'angle': sil['angle']!,
                'angle_left': sil['angle_left']!,
                'angle_right': sil['angle_right']!,
                'r_squared': (sil['confidence'] ?? 0.0).clamp(0.0, 1.0),
                'used_points': 18.0,
                'fit_variant': 'silhouette_cap',
                'contact_confidence':
                    math.max(contactConfidence, sil['confidence'] ?? 0.0),
                'baseline_confidence': baselineConfidence,
                'symmetry_score': symmetryScore,
              });
              if (!_isMethodValid(silhouetteMethod) &&
                  (sil['confidence'] ?? 0.0) >= 0.42 &&
                  baselineConfidence >= 0.10) {
                silhouetteMethod['is_valid'] = true;
                silhouetteMethod.remove('invalid_reason');
              }
              if (_isMethodValid(silhouetteMethod)) {
                methodResults['polynomial'] = silhouetteMethod;
                ensembleResult = _calculateEnsembleAngle(methodResults);
                thetaFinal = ensembleResult['angle'];
                thetaLeft = ensembleResult['angle_left'];
                thetaRight = ensembleResult['angle_right'];
                weights = ensembleResult['weights'];
                _log(
                    '⚠️ All primary models rejected; using silhouette-cap fallback.');
              }
            }
          }

          if (!rescueUsable && !thetaFinal.isFinite) {
            return {
              'text':
                  '❌ Could not obtain a reliable angle from the image (all models rejected).',
              'annotated': null,
              'method_quality': methodResults.map((k, v) => MapEntry(k, {
                    'is_valid': _isMethodValid(v),
                    'invalid_reason': v['invalid_reason'],
                  })),
              'baseline_tilt': baselineAngle,
              'baseline_confidence': baselineConfidence,
              'baseline_source': baselineResult['source'] ?? 'contour',
              'contact_confidence': contactConfidence,
              'contact_confidence_left': leftContactConfidence,
              'contact_confidence_right': rightContactConfidence,
              'contact_x_left_aligned': leftXAligned,
              'contact_x_right_aligned': rightXAligned,
              'contact_y_surface_aligned': baselineY,
              'contact_x_left': leftContactOriginal.x,
              'contact_x_right': rightContactOriginal.x,
              'contact_y_surface_left': leftContactOriginal.y,
              'contact_y_surface_right': rightContactOriginal.y,
              'contact_slope_left': contactSlopeLeft,
              'contact_slope_right': contactSlopeRight,
              'symmetry_score': symmetryScore,
              'rescue_r_squared': rescueRSq,
              'rescue_left_angle': rescueLeftAngle,
              'rescue_right_angle': rescueRightAngle,
              if (silhouetteFallback != null)
                'silhouette_fallback': silhouetteFallback,
            };
          }

          if (rescueUsable) {
            final rescuePoly = _validateMethodResult(
              'polynomial',
              {
                'angle': (rescueLeftAngle + rescueRightAngle) / 2.0,
                'angle_left': rescueLeftAngle,
                'angle_right': rescueRightAngle,
                'r_squared': rescueRSq,
                'used_points': leftPoints.length + rightPoints.length,
                'fit_variant': 'local_tangent',
                'contact_confidence': contactConfidence,
                'baseline_confidence': baselineConfidence,
                'symmetry_score': symmetryScore,
              },
            );
            if (!_isMethodValid(rescuePoly) &&
                contactConfidence >= 0.10 &&
                baselineConfidence >= 0.10 &&
                symmetryScore >= 0.10) {
              rescuePoly['is_valid'] = true;
              rescuePoly.remove('invalid_reason');
            }
            methodResults['polynomial'] = rescuePoly;

            ensembleResult = _calculateEnsembleAngle(methodResults);
            thetaFinal = ensembleResult['angle'];
            thetaLeft = ensembleResult['angle_left'];
            thetaRight = ensembleResult['angle_right'];
            weights = ensembleResult['weights'];
            final allowHardRescue =
                contactConfidence >= 0.10 && baselineConfidence >= 0.10;
            if (!thetaFinal.isFinite) {
              if (!allowHardRescue) {
                return {
                  'text':
                      '❌ Could not obtain a reliable angle from the image (all models rejected).',
                  'annotated': null,
                  'method_quality': methodResults.map((k, v) => MapEntry(k, {
                        'is_valid': _isMethodValid(v),
                        'invalid_reason': v['invalid_reason'],
                      })),
                  'baseline_tilt': baselineAngle,
                  'baseline_confidence': baselineConfidence,
                  'baseline_source': baselineResult['source'] ?? 'contour',
                  'contact_confidence': contactConfidence,
                  'contact_confidence_left': leftContactConfidence,
                  'contact_confidence_right': rightContactConfidence,
                  'symmetry_score': symmetryScore,
                };
              }
              thetaLeft = rescueLeftAngle;
              thetaRight = rescueRightAngle;
              thetaFinal = (thetaLeft + thetaRight) / 2.0;
              weights = {'polynomial': 1.0};
            }
            _log('⚠️ All primary models rejected; using local tangent rescue.');
          }
        }
      }

      // ============ UNCERTAINTY QUANTIFICATION ============

      // σ of the baseline placement (px): standard error of the fitted line
      // (rms/√n_inliers), floored at a sub-pixel systematic residual — even a
      // perfect fit cannot beat the optical blur of the contact line.
      final double baselineSigmaPx = (() {
        final rms = ((baselineResult['rms'] as num?)?.toDouble() ?? 2.0)
            .clamp(0.0, 10.0);
        final inlierFrac =
            ((baselineResult['inlier_fraction'] as num?)?.toDouble() ?? 0.1)
                .clamp(0.0, 1.0);
        final nInliers = math.max(4.0, inlierFrac * width);
        return (rms / math.sqrt(nInliers) + 0.3).clamp(0.3, 1.5);
      })();

      var uncertaintyResult = _calculateUncertainty(
        xs,
        ys,
        leftPoints,
        rightPoints,
        baselineY,
        leftXAligned,
        rightXAligned,
        methodResults,
        baselineSigmaPx: baselineSigmaPx,
      );
      double uncertainty = uncertaintyResult['combined'] ?? 1.0;
      double uncertaintyBootstrap = uncertaintyResult['bootstrap'] ?? 0.0;
      double uncertaintyMethodDisagreement =
          uncertaintyResult['method_disagreement'] ?? 0.0;
      double uncertaintyEdge = uncertaintyResult['edge'] ?? 0.5;
      double uncertaintyContact = uncertaintyResult['contact'] ?? 0.5;
      double uncertaintyBaseline = uncertaintyResult['baseline'] ?? 0.3;
      final double uncertaintyCalibration =
          math.max(0.0, angleCalibration.residualStdDeg);
      if (uncertaintyCalibration > 0.0) {
        uncertainty = math.sqrt(
          uncertainty * uncertainty +
              uncertaintyCalibration * uncertaintyCalibration,
        );
      }

      // Calculate physical metrics with explicit (or fallback) calibration.
      final double dropRadius = (rightXAligned - leftXAligned) / 2.0;
      final physicalMetrics = computePhysicalMetrics(
        radiusPixels: dropRadius,
        calibration: effectiveCalibration,
      );
      final bool isCalibrated = (physicalMetrics['is_calibrated'] ?? 0.0) > 0.5;
      final double pixelSizeUm = physicalMetrics['pixel_size_um']!;
      final double dropRadiusMm = physicalMetrics['radius_mm']!;
      final double bondNumberPhysical =
          physicalMetrics['bond_number_physical']!;
      final double bondNumberPhysicalUncertainty =
          physicalMetrics['bond_number_physical_uncertainty']!;
      final double scaleRelativeUncertainty =
          effectiveCalibration?.relativeUncertainty ?? double.nan;

      final double bondNumberFit =
          _isMethodValid(methodResults['young_laplace'])
              ? ((methodResults['young_laplace']?['bond_number'] as num?)
                      ?.toDouble() ??
                  double.nan)
              : double.nan;
      final double bondNumber =
          bondNumberFit.isFinite ? bondNumberFit : bondNumberPhysical;

      // ============ ANNOTATE IMAGE ============

      imglib.Image annotated = src.clone();
      _annotateImage(
        annotated,
        analysisContour,
        baselineResult,
        leftContactOriginal,
        rightContactOriginal,
        leftXAligned,
        rightXAligned,
        methodResults,
        thetaFinal,
        thetaLeft,
        thetaRight,
      );

      // Save annotated image
      Directory tmp = await _resolveTempDirectory();
      String outPath =
          '${tmp.path}/contact_angle_${DateTime.now().millisecondsSinceEpoch}.png';
      File outFile = File(outPath);
      await outFile.writeAsBytes(imglib.encodePng(annotated));

      // Determine surface type
      String surfaceType;
      if (thetaFinal < 10) {
        surfaceType = 'Complete Wetting';
      } else if (thetaFinal < 90) {
        surfaceType = 'Hydrophilic';
      } else if (thetaFinal < 150) {
        surfaceType = 'Hydrophobic';
      } else {
        surfaceType = 'Superhydrophobic';
      }

      final double baselineYAtCenter =
          _baselineYAtX(baselineResult, width / 2.0);
      final double baselineSlope = (baselineResult['slope'] as num).toDouble();
      final String scaleModeLabel = !isCalibrated
          ? 'approximate'
          : (scaleSource.startsWith('metadata_')
              ? 'auto-$scaleSource'
              : scaleSource);
      final String angleCalibrationLabel = angleCalibration.source;
      final validMethodCount =
          methodResults.values.where((m) => _isMethodValid(m)).length;
      final circleSummary = _formatMethodSummary('circle', methodResults);
      final ellipseSummary = _formatMethodSummary('ellipse', methodResults);
      final polySummary = _formatMethodSummary('polynomial', methodResults);
      final ylSummary = _formatMethodSummary('young_laplace', methodResults);
      final scaleCaution = !isCalibrated
          ? '\n⚠️ Physical units are approximate. Add scale calibration for scientific metrology.'
          : '';

      // Build result text
      String resultText = '''
🎯 Contact Angle: ${thetaFinal.toStringAsFixed(2)}° ± ${uncertainty.toStringAsFixed(2)}°

Left: ${thetaLeft.toStringAsFixed(1)}° | Right: ${thetaRight.toStringAsFixed(1)}°
Hysteresis: ${(thetaLeft - thetaRight).abs().toStringAsFixed(1)}°
Baseline tilt: ${baselineAngle.toStringAsFixed(2)}° (${(baselineResult['source'] ?? 'contour')}, conf=${baselineConfidence.toStringAsFixed(2)})
Valid methods: $validMethodCount/${methodResults.length}

Methods:
• Circle fit: $circleSummary
• Ellipse fit: $ellipseSummary
• Polynomial: $polySummary
• Young-Laplace: $ylSummary

Scale: ${pixelSizeUm.toStringAsFixed(3)} um/px ($scaleModeLabel)
${scaleRelativeUncertainty.isFinite ? 'Scale uncertainty: ±${(scaleRelativeUncertainty * 100.0).toStringAsFixed(2)}%' : ''}
Drop radius: ${dropRadiusMm.toStringAsFixed(4)} mm
Bo_physical: ${bondNumberPhysical.toStringAsExponential(2)}${bondNumberPhysicalUncertainty.isFinite ? ' ± ${bondNumberPhysicalUncertainty.toStringAsExponential(1)}' : ''}
Angle calibration: $angleCalibrationLabel${uncertaintyCalibration > 0 ? ' (residual σ≈${uncertaintyCalibration.toStringAsFixed(2)}°)' : ''}
Symmetry score: ${symmetryScore.toStringAsFixed(2)}

Surface: $surfaceType
Contour: ${analysisContour.length} points
${inverted ? 'Background: Dark (auto-corrected)' : 'Background: Light'}
$scaleCaution
''';

      _log(
          '✅ Done. Final angle: ${thetaFinal.toStringAsFixed(2)}° ± ${uncertainty.toStringAsFixed(2)}°');

      return {
        'text': resultText,
        'annotated': outFile,
        'annotated_path': outPath,
        'angle_numeric': thetaFinal,
        'angle_left': thetaLeft,
        'angle_right': thetaRight,
        // Measurement-regime QC flags (ISO 19403-2 practice; Vuckovac et al.
        // Soft Matter 2019; ramé-hart baseline-tilt-to-zero convention).
        'quality_flags': <String>[
          if (thetaFinal >= 150.0)
            'high_angle_regime: baseline sensitivity grows steeply above '
                '150° (±1 px → up to ~8° near 180°); treat with caution',
          if (thetaFinal <= 20.0)
            'low_angle_regime: tangent placement is ambiguous below 20°',
          if (baselineAngle.abs() > 2.0)
            'stage_tilt: baseline tilt '
                '${baselineAngle.toStringAsFixed(1)}° — level the stage '
                '(angles are tilt-corrected but residual error grows)',
          if (thetaLeft.isFinite &&
              thetaRight.isFinite &&
              (thetaLeft - thetaRight).abs() > 4.0)
            'asymmetry: |θL−θR| = '
                '${(thetaLeft - thetaRight).abs().toStringAsFixed(1)}° — '
                'non-axisymmetric drop, contamination, or baseline error',
          if (dropRadius.isFinite && dropRadius < 100.0)
            'small_drop: contact half-width ${dropRadius.toStringAsFixed(0)} '
                'px — errors scale inversely with drop pixel size; move '
                'closer or crop tighter',
        ],
        'uncertainty_numeric': uncertainty,
        'uncertainty_bootstrap': uncertaintyBootstrap,
        'uncertainty_method': uncertaintyMethodDisagreement,
        'uncertainty_edge': uncertaintyEdge,
        'uncertainty_contact': uncertaintyContact,
        'uncertainty_baseline': uncertaintyBaseline,
        'uncertainty_calibration': uncertaintyCalibration,
        'theta_circle': _methodMetricOrNaN(methodResults, 'circle', 'angle'),
        'theta_ellipse': _methodMetricOrNaN(methodResults, 'ellipse', 'angle'),
        'theta_poly': _methodMetricOrNaN(methodResults, 'polynomial', 'angle'),
        'theta_young_laplace':
            _methodMetricOrNaN(methodResults, 'young_laplace', 'angle'),
        'r_squared_circle':
            _methodMetricOrNaN(methodResults, 'circle', 'r_squared'),
        'r_squared_ellipse':
            _methodMetricOrNaN(methodResults, 'ellipse', 'r_squared'),
        'r_squared_young_laplace':
            _methodMetricOrNaN(methodResults, 'young_laplace', 'r_squared'),
        'bond_number': bondNumber,
        'bond_number_fit': bondNumberFit,
        'bond_number_physical': bondNumberPhysical,
        'bond_number_physical_uncertainty': bondNumberPhysicalUncertainty,
        'scale_is_calibrated': isCalibrated,
        'meters_per_pixel': physicalMetrics['meters_per_pixel'],
        'pixel_size_um': pixelSizeUm,
        'drop_radius_px': dropRadius,
        'drop_radius_mm': dropRadiusMm,
        'scale_relative_uncertainty': scaleRelativeUncertainty,
        'scale_source': scaleSource,
        'contour_count': analysisContour.length,
        'baseline_y': baselineYAtCenter,
        'baseline_tilt': baselineAngle,
        'baseline_slope': baselineSlope,
        'baseline_source': baselineResult['source'] ?? 'contour',
        'baseline_method': baselineResult['baseline_method'] ?? 'legacy',
        'baseline_confidence':
            ((baselineResult['confidence'] as num?)?.toDouble() ?? 0.0)
                .clamp(0.0, 1.0),
        'baseline_span_fraction':
            ((baselineResult['span_fraction'] as num?)?.toDouble() ?? 0.0)
                .clamp(0.0, 1.0),
        'baseline_inlier_fraction':
            ((baselineResult['inlier_fraction'] as num?)?.toDouble() ?? 0.0)
                .clamp(0.0, 1.0),
        'contact_confidence': contactConfidence,
        'contact_confidence_left': leftContactConfidence,
        'contact_confidence_right': rightContactConfidence,
        'contact_x_left_aligned': leftXAligned,
        'contact_x_right_aligned': rightXAligned,
        'contact_y_surface_aligned': baselineY,
        'contact_x_left': leftContactOriginal.x,
        'contact_x_right': rightContactOriginal.x,
        'contact_y_surface_left': leftContactOriginal.y,
        'contact_y_surface_right': rightContactOriginal.y,
        'contact_slope_left': contactSlopeLeft,
        'contact_slope_right': contactSlopeRight,
        'symmetry_score': symmetryScore,
        'symmetry_residual': symmetryResidual,
        'angle_calibration_source': angleCalibration.source,
        'angle_calibration_residual_std': angleCalibration.residualStdDeg,
        'method_weights': weights,
        'method_quality': methodResults.map((k, v) => MapEntry(k, {
              'is_valid': _isMethodValid(v),
              'invalid_reason': v['invalid_reason'],
            })),
        'filename': imageFile.path.split(Platform.pathSeparator).last,
        'surface_type': surfaceType,
      };
    } catch (e, st) {
      _log('❌ Processing failed: $e\n$st');
      return {
        'text':
            '❌ Processing failed: ${e.toString()}\n\nTry: better contrast, cropped droplet, or attach sample image.',
        'annotated': null
      };
    }
  }

  static String _methodStatusSuffix(Map<String, dynamic> methodResult) {
    if (_isMethodValid(methodResult)) return '';
    final reason =
        _humanizeInvalidReason(methodResult['invalid_reason'] as String?);
    return ' [rejected: $reason]';
  }

  /// Fallback integer edge detection using Sobel operator
  static List<math.Point<double>> _detectEdgesInteger(
      List<int> gray, int width, int height) {
    var edges = <math.Point<double>>[];

    for (int y = 1; y < height - 1; y++) {
      for (int x = 1; x < width - 1; x++) {
        double sx = 0.0, sy = 0.0;
        // Sobel kernels
        sx -= gray[(y - 1) * width + (x - 1)] +
            2 * gray[y * width + (x - 1)] +
            gray[(y + 1) * width + (x - 1)];
        sx += gray[(y - 1) * width + (x + 1)] +
            2 * gray[y * width + (x + 1)] +
            gray[(y + 1) * width + (x + 1)];
        sy -= gray[(y - 1) * width + (x - 1)] +
            2 * gray[(y - 1) * width + x] +
            gray[(y - 1) * width + (x + 1)];
        sy += gray[(y + 1) * width + (x - 1)] +
            2 * gray[(y + 1) * width + x] +
            gray[(y + 1) * width + (x + 1)];

        double mag = math.sqrt(sx * sx + sy * sy) / 8.0;
        if (mag > 30) {
          edges.add(math.Point(x.toDouble(), y.toDouble()));
        }
      }
    }

    return edges;
  }

  static imglib.Image _rotateImage(imglib.Image src, double angleDeg) {
    try {
      return imglib.copyRotate(src, angle: angleDeg);
    } catch (_) {}
    try {
      final out = Function.apply(imglib.copyRotate as dynamic, [src, angleDeg]);
      if (out is imglib.Image) return out;
    } catch (_) {}
    return src;
  }

  static List<math.Point<double>> _detectEdgesAdaptive(
    List<int> gray,
    int width,
    int height, {
    bool sensitive = false,
  }) {
    final low = sensitive ? 18.0 : 25.0;
    final high = sensitive ? 58.0 : 70.0;
    final sigma = sensitive ? 1.0 : 1.2;
    final edges = SubPixelEdgeDetector.detectEdges(
      gray,
      width,
      height,
      lowThreshold: low,
      highThreshold: high,
      sigma: sigma,
    );
    if (edges.length >= 50) return edges;
    return _detectEdgesInteger(gray, width, height);
  }

  static math.Point<double> debugRotatePoint(
    math.Point<double> p,
    double angleDeg,
    double cx,
    double cy,
  ) {
    final rad = angleDeg * math.pi / 180.0;
    final cosA = math.cos(rad);
    final sinA = math.sin(rad);
    final dx = p.x - cx;
    final dy = p.y - cy;
    return math.Point(
      cx + dx * cosA - dy * sinA,
      cy + dx * sinA + dy * cosA,
    );
  }

  static math.Point<double> debugRotatePointBack(
    math.Point<double> p,
    double angleDeg,
    double cx,
    double cy,
  ) {
    return debugRotatePoint(p, -angleDeg, cx, cy);
  }

  static imglib.Image debugRotateImage(imglib.Image src, double angleDeg) {
    final width = src.width;
    final height = src.height;
    final dst = imglib.Image(width: width, height: height);
    final cx = (width - 1) / 2.0;
    final cy = (height - 1) / 2.0;
    final rad = angleDeg * math.pi / 180.0;
    final cosA = math.cos(rad);
    final sinA = math.sin(rad);

    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        final dx = x - cx;
        final dy = y - cy;
        final srcX = cx + dx * cosA + dy * sinA;
        final srcY = cy - dx * sinA + dy * cosA;
        final ix = srcX.round();
        final iy = srcY.round();

        if (ix >= 0 && ix < width && iy >= 0 && iy < height) {
          dst.setPixel(x, y, src.getPixel(ix, iy));
        } else {
          dst.setPixelRgba(x, y, 0, 0, 0, 255);
        }
      }
    }

    return dst;
  }

  static Map<String, dynamic> debugDetectBaseline(
    List<math.Point<double>> contour,
  ) {
    return _detectBaseline(contour);
  }

  static Map<String, double> debugDetectContactsAligned(
    List<math.Point<double>> contourAligned,
  ) {
    return _detectContactPoints(
      contourAligned,
      fallbackContourAligned: contourAligned,
    );
  }
}
