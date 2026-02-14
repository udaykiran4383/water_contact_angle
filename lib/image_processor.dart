import 'dart:io';
import 'dart:developer' as developer;
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as imglib;
import 'package:path_provider/path_provider.dart';

import 'processing/angle_utils.dart';
import 'processing/sub_pixel_edge.dart';
import 'processing/young_laplace.dart';

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
class ImageProcessor {
  // Bootstrap iterations for uncertainty estimation
  static const int _bootstrapIterations = 100;

  // Minimum R² to consider a fit valid
  static const double _minRSquared = 0.85;

  static const double _minCircleRSquared = 0.72;
  static const double _minEllipseRSquared = 0.72;
  static const double _minPolynomialRSquared = 0.78;
  static const double _minYoungLaplaceRSquared = 0.68;
  static const double _maxYoungLaplaceResidual = 0.35;

  // Maximum plausible baseline tilt for sessile-drop capture setup
  static const double _maxBaselineTiltDeg = 20.0;

  // Fallback calibration used when no explicit scale is provided.
  static const double _defaultMetersPerPixelApprox = 10e-6;

  static void _log(String message) {
    developer.log(message, name: 'ImageProcessor');
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

  /// Main image processing pipeline
  static Future<Map<String, dynamic>> processImage(
    File imageFile, {
    ScaleCalibration? calibration,
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

      final autoCalibration =
          calibration == null ? detectAutoCalibration(src, bytes) : null;
      final effectiveCalibration = calibration ?? autoCalibration;
      final scaleSource =
          effectiveCalibration?.source ?? 'fallback_approximate';

      _log('📐 Image size: ${src.width}x${src.height}');

      // Convert to grayscale
      imglib.Image gray = imglib.grayscale(src);
      final int width = gray.width;
      final int height = gray.height;

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
      if (meanIntensity < 127) {
        // Invert for silhouette cases
        for (int i = 0; i < grayValues.length; i++) {
          grayValues[i] = 255 - grayValues[i];
        }
        inverted = true;
        _log('🔄 Image inverted for darker background');
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
      subPixelEdges = subPixelEdges
          .where(
            (p) =>
                p.x > 2.5 &&
                p.x < width - 3.5 &&
                p.y > 2.5 &&
                p.y < height - 3.5,
          )
          .toList();
      _log('🧹 Edge points after border suppression: ${subPixelEdges.length}');

      // Connected components to find largest droplet
      var contour = _extractLargestContour(subPixelEdges, width, height);

      if (contour.length < 20) {
        return {
          'text':
              '❌ No droplet detected. Try higher contrast / clearer silhouette.',
          'annotated': null
        };
      }

      // Baseline detection and coordinate normalization.
      // We rotate all geometry so baseline is horizontal (y=0) before fitting.
      final baselineResult = _detectBaseline(contour);
      final double baselineAngle = (baselineResult['angle'] as num).toDouble();
      final contourAligned =
          contour.map((p) => _toBaselineFrame(p, baselineResult)).toList();

      final dropContourAligned = _extractDropContourAligned(contourAligned);
      if (dropContourAligned.length < 24) {
        return {
          'text': '❌ Could not isolate droplet contour from background edges.',
          'annotated': null
        };
      }

      final contactResult = _detectContactPoints(
        dropContourAligned,
        fallbackContourAligned: contourAligned,
      );
      final double leftXAligned = contactResult['leftX']!;
      final double rightXAligned = contactResult['rightX']!;
      const double baselineY = 0.0;

      if (!leftXAligned.isFinite ||
          !rightXAligned.isFinite ||
          rightXAligned <= leftXAligned + 6.0) {
        return {
          'text': '❌ Could not locate contact points reliably.',
          'annotated': null
        };
      }

      final leftContactOriginal =
          _fromBaselineFrame(math.Point(leftXAligned, 0.0), baselineResult);
      final rightContactOriginal =
          _fromBaselineFrame(math.Point(rightXAligned, 0.0), baselineResult);

      _log(
          '📍 Baseline tilt=${baselineAngle.toStringAsFixed(2)}°, RMS=${(baselineResult['rms'] as num).toDouble().toStringAsFixed(2)} px');
      _log(
          '📍 Contacts (aligned): left=${leftXAligned.toStringAsFixed(2)}, right=${rightXAligned.toStringAsFixed(2)}');

      final double contactSpan = (rightXAligned - leftXAligned).abs();
      final contourPad = (contactSpan * 0.30).clamp(10.0, 45.0);
      final narrowedContourAligned = dropContourAligned
          .where(
            (p) =>
                p.y < -0.8 &&
                p.x >= leftXAligned - contourPad &&
                p.x <= rightXAligned + contourPad,
          )
          .toList();
      final analysisContourAligned = narrowedContourAligned.length >= 24
          ? narrowedContourAligned
          : dropContourAligned;
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

      if (xs.length < 10) {
        return {
          'text': '❌ Not enough points for fitting (${xs.length}).',
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
        };
        methodResults['circle'] = _validateMethodResult('circle', circleResult);
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
        };
        methodResults['ellipse'] =
            _validateMethodResult('ellipse', ellipseResult);
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
        );
        final polyRight = AngleUtils.polynomialAngleDetailed(
          rightPoints,
          rightXAligned,
          baselineY,
          false,
          degree: 4,
          useWeighting: true,
        );
        double thetaPolyLeft = polyLeft['angle']!;
        double thetaPolyRight = polyRight['angle']!;
        double thetaPoly = (thetaPolyLeft + thetaPolyRight) / 2.0;
        double polyRSq =
            ((polyLeft['r_squared']! + polyRight['r_squared']!) / 2.0)
                .clamp(0.0, 1.0);
        final polyResult = {
          'angle': thetaPoly,
          'angle_left': thetaPolyLeft,
          'angle_right': thetaPolyRight,
          'r_squared': polyRSq,
          'used_points': leftPoints.length + rightPoints.length,
        };
        methodResults['polynomial'] =
            _validateMethodResult('polynomial', polyResult);
        _log(
            '📈 Polynomial: ${thetaPoly.toStringAsFixed(2)}° (R²=${polyRSq.toStringAsFixed(3)})${_methodStatusSuffix(methodResults['polynomial']!)}');
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
          'r_squared': ylResult['r_squared']!,
          'bond_number': ylResult['bond_number']!,
          'residual': ylResult['residual']!,
        };
        methodResults['young_laplace'] =
            _validateMethodResult('young_laplace', ylMethodResult);
        _log(
            '🔬 Young-Laplace: ${ylResult['contact_angle']!.toStringAsFixed(2)}° (Bo=${ylResult['bond_number']!.toStringAsFixed(3)})${_methodStatusSuffix(methodResults['young_laplace']!)}');
      } catch (e) {
        _log('⚠️ Young-Laplace fit failed: $e');
        methodResults['young_laplace'] = _invalidMethodResult('fit_failed');
      }

      // ============ ENSEMBLE ANGLE CALCULATION ============

      var ensembleResult = _calculateEnsembleAngle(methodResults);
      double thetaFinal = ensembleResult['angle'];
      double thetaLeft = ensembleResult['angle_left'];
      double thetaRight = ensembleResult['angle_right'];
      Map<String, double> weights = ensembleResult['weights'];

      // ============ UNCERTAINTY QUANTIFICATION ============

      var uncertaintyResult = _calculateUncertainty(
        xs,
        ys,
        leftPoints,
        rightPoints,
        baselineY,
        leftXAligned,
        rightXAligned,
        methodResults,
      );
      double uncertainty = uncertaintyResult['combined'] ?? 1.0;
      double uncertaintyBootstrap = uncertaintyResult['bootstrap'] ?? 0.0;
      double uncertaintyMethodDisagreement =
          uncertaintyResult['method_disagreement'] ?? 0.0;
      double uncertaintyEdge = uncertaintyResult['edge'] ?? 0.5;

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
      Directory tmp = await getTemporaryDirectory();
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
Baseline tilt: ${baselineAngle.toStringAsFixed(2)}°
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
        'uncertainty_numeric': uncertainty,
        'uncertainty_bootstrap': uncertaintyBootstrap,
        'uncertainty_method': uncertaintyMethodDisagreement,
        'uncertainty_edge': uncertaintyEdge,
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

  static Map<String, dynamic> _invalidMethodResult(String reason) {
    return {
      'angle': double.nan,
      'r_squared': 0.0,
      'is_valid': false,
      'invalid_reason': reason,
    };
  }

  static bool _isAnglePlausible(double angle) {
    return angle.isFinite && angle >= 1.0 && angle <= 179.0;
  }

  static bool _isMethodValid(Map<String, dynamic>? methodResult) {
    if (methodResult == null) return false;
    return methodResult['is_valid'] == true &&
        _isAnglePlausible(
          (methodResult['angle'] as num?)?.toDouble() ?? double.nan,
        );
  }

  static Map<String, dynamic> _validateMethodResult(
    String method,
    Map<String, dynamic> rawResult,
  ) {
    final result = Map<String, dynamic>.from(rawResult);
    final angle = (result['angle'] as num?)?.toDouble() ?? double.nan;
    final rSq =
        ((result['r_squared'] as num?)?.toDouble() ?? 0.0).clamp(0.0, 1.0);
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
          if (!radius.isFinite || radius <= 2.0) {
            reason = 'invalid_radius';
          } else if (!cy.isFinite || cy >= baselineY - 0.4) {
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
              final tolerance = math.max(5.0, span * 0.16);
              if ((predLeft - leftX).abs() > tolerance ||
                  (predRight - rightX).abs() > tolerance) {
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
          final axisRatio = (a.isFinite && b.isFinite && a > 0 && b > 0)
              ? math.max(a, b) / math.min(a, b)
              : double.infinity;
          if (!a.isFinite || !b.isFinite || a <= 0 || b <= 0) {
            reason = 'invalid_axes';
          } else if (axisRatio > 4.5) {
            reason = 'aspect_ratio_outlier';
          } else if (rSq < _minEllipseRSquared) {
            reason = 'low_r_squared';
          }
          break;
        case 'polynomial':
          final usedPoints = (result['used_points'] as num?)?.toDouble() ?? 0.0;
          final leftAngle =
              (result['angle_left'] as num?)?.toDouble() ?? double.nan;
          final rightAngle =
              (result['angle_right'] as num?)?.toDouble() ?? double.nan;
          final mismatch = leftAngle.isFinite && rightAngle.isFinite
              ? (leftAngle - rightAngle).abs()
              : 999.0;
          if (usedPoints < 12.0) {
            reason = 'insufficient_points';
          } else if (mismatch > 45.0) {
            reason = 'left_right_mismatch';
          } else if (rSq < _minPolynomialRSquared) {
            reason = 'low_r_squared';
          }
          break;
        case 'young_laplace':
          final residual =
              (result['residual'] as num?)?.toDouble() ?? double.infinity;
          final bo = (result['bond_number'] as num?)?.toDouble() ?? double.nan;
          if (!bo.isFinite || bo <= 0) {
            reason = 'invalid_bond_number';
          } else if (residual > _maxYoungLaplaceResidual) {
            reason = 'high_residual';
          } else if (rSq < _minYoungLaplaceRSquared) {
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

  static String _methodStatusSuffix(Map<String, dynamic> methodResult) {
    if (_isMethodValid(methodResult)) return '';
    final reason =
        _humanizeInvalidReason(methodResult['invalid_reason'] as String?);
    return ' [rejected: $reason]';
  }

  static String _humanizeInvalidReason(String? reason) {
    switch (reason) {
      case 'fit_failed':
        return 'fit failed';
      case 'angle_out_of_range':
        return 'angle out of range';
      case 'invalid_radius':
        return 'invalid radius';
      case 'center_below_baseline':
        return 'circle center below baseline';
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
      default:
        return 'invalid';
    }
  }

  static String _formatMethodSummary(
    String methodName,
    Map<String, Map<String, dynamic>> methodResults,
  ) {
    final result = methodResults[methodName];
    if (result == null) return 'N/A';

    final angle = (result['angle'] as num?)?.toDouble() ?? double.nan;
    final rSq = (result['r_squared'] as num?)?.toDouble() ?? double.nan;
    if (!_isMethodValid(result)) {
      final reason =
          _humanizeInvalidReason(result['invalid_reason'] as String?);
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

  static double _methodMetricOrNaN(
    Map<String, Map<String, dynamic>> methodResults,
    String methodName,
    String key,
  ) {
    final result = methodResults[methodName];
    if (!_isMethodValid(result)) return double.nan;
    final value = (result![key] as num?)?.toDouble() ?? double.nan;
    return value.isFinite ? value : double.nan;
  }

  /// Isolates the droplet arc in baseline-aligned coordinates.
  /// Keeps the full above-baseline arc and selects the most plausible connected
  /// component (high vertical extent, centered, both flank supports).
  static List<math.Point<double>> _extractDropContourAligned(
    List<math.Point<double>> contourAligned,
  ) {
    if (contourAligned.length < 20) return [];

    final maxY = contourAligned.map((p) => p.y).reduce(math.max);
    final minX = contourAligned.map((p) => p.x).reduce(math.min);
    final maxX = contourAligned.map((p) => p.x).reduce(math.max);
    final minY = contourAligned.map((p) => p.y).reduce(math.min);
    final yRange = (maxY - minY).abs();
    final xRange = (maxX - minX).abs();
    if (xRange < 4.0 || yRange < 4.0) return [];

    // Keep the entire droplet arc above the baseline.
    final candidates = contourAligned.where((p) => p.y < -0.8).toList();
    if (candidates.length < 20) {
      return candidates;
    }

    const cellSize = 2.0;
    final localMinX = candidates.map((p) => p.x).reduce(math.min);
    final localMinY = candidates.map((p) => p.y).reduce(math.min);
    final gridW =
        (((candidates.map((p) => p.x).reduce(math.max) - localMinX) / cellSize)
                .ceil()) +
            3;

    final grid = <int, List<int>>{};
    for (int i = 0; i < candidates.length; i++) {
      final gx = ((candidates[i].x - localMinX) / cellSize).floor();
      final gy = ((candidates[i].y - localMinY) / cellSize).floor();
      final key = gy * gridW + gx;
      grid.putIfAbsent(key, () => <int>[]).add(i);
    }

    const maxNeighborDistance = 4.8;
    const maxNeighborDistanceSq = maxNeighborDistance * maxNeighborDistance;
    final visited = List<bool>.filled(candidates.length, false);
    List<math.Point<double>> bestComponent = [];
    double bestScore = double.negativeInfinity;
    final globalCenterX = (minX + maxX) * 0.5;

    for (int i = 0; i < candidates.length; i++) {
      if (visited[i]) continue;

      final stack = <int>[i];
      visited[i] = true;
      final componentIdx = <int>[];

      while (stack.isNotEmpty) {
        final cur = stack.removeLast();
        componentIdx.add(cur);
        final gx = ((candidates[cur].x - localMinX) / cellSize).floor();
        final gy = ((candidates[cur].y - localMinY) / cellSize).floor();

        for (int dy = -1; dy <= 1; dy++) {
          for (int dx = -1; dx <= 1; dx++) {
            final key = (gy + dy) * gridW + (gx + dx);
            final neighbors = grid[key];
            if (neighbors == null) continue;
            for (final ni in neighbors) {
              if (visited[ni]) continue;
              final dxp = candidates[ni].x - candidates[cur].x;
              final dyp = candidates[ni].y - candidates[cur].y;
              if (dxp * dxp + dyp * dyp <= maxNeighborDistanceSq) {
                visited[ni] = true;
                stack.add(ni);
              }
            }
          }
        }
      }

      if (componentIdx.length < 14) continue;

      final component = componentIdx.map((idx) => candidates[idx]).toList();
      final cMinX = component.map((p) => p.x).reduce(math.min);
      final cMaxX = component.map((p) => p.x).reduce(math.max);
      final cMinY = component.map((p) => p.y).reduce(math.min);
      final cMaxY = component.map((p) => p.y).reduce(math.max);
      final height = cMaxY - cMinY;
      final width = cMaxX - cMinX;
      if (height < 12.0) continue;

      final meanX =
          component.map((p) => p.x).reduce((a, b) => a + b) / component.length;
      final nearBaselineCount = component.where((p) => p.y > -8.0).length;
      final apexX = component.reduce((a, b) => a.y < b.y ? a : b).x;
      final leftNearBaseline =
          component.where((p) => p.y > -8.0 && p.x < apexX - 0.8).length;
      final rightNearBaseline =
          component.where((p) => p.y > -8.0 && p.x > apexX + 0.8).length;
      final centerPenalty =
          (meanX - globalCenterX).abs() / math.max(1.0, xRange * 0.5);
      final widthPenalty = width > xRange * 0.85
          ? (width - xRange * 0.85) / math.max(1.0, xRange)
          : 0.0;
      final flankPenalty =
          (leftNearBaseline == 0 || rightNearBaseline == 0) ? 180.0 : 0.0;
      final flankImbalance = (leftNearBaseline - rightNearBaseline).abs() /
          math.max(1.0, (leftNearBaseline + rightNearBaseline).toDouble());
      final imbalancePenalty = 25.0 * flankImbalance;

      final score = component.length +
          6.0 * height +
          1.8 * nearBaselineCount -
          35.0 * centerPenalty -
          120.0 * widthPenalty -
          flankPenalty -
          imbalancePenalty;

      if (score > bestScore) {
        bestScore = score;
        bestComponent = component;
      }
    }

    if (bestComponent.isNotEmpty) {
      final apexX = bestComponent.reduce((a, b) => a.y < b.y ? a : b).x;
      final leftNearBaseline =
          bestComponent.where((p) => p.y > -10.0 && p.x < apexX - 0.8).length;
      final rightNearBaseline =
          bestComponent.where((p) => p.y > -10.0 && p.x > apexX + 0.8).length;
      if (leftNearBaseline >= 2 && rightNearBaseline >= 2) {
        return bestComponent;
      }
    }

    return candidates;
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

  /// Extract the most plausible connected contour from edge points.
  /// A pure "largest component" heuristic is brittle when substrate/frame edges
  /// dominate; we instead score components by geometry and border proximity.
  static List<math.Point<double>> _extractLargestContour(
      List<math.Point<double>> edges, int width, int height) {
    if (edges.isEmpty) return [];

    // Create a grid for fast lookup (quantized to 2-pixel cells)
    int cellSize = 2;
    int gridW = (width / cellSize).ceil();
    Map<int, List<int>> grid = {};

    for (int i = 0; i < edges.length; i++) {
      int gx = (edges[i].x / cellSize).floor();
      int gy = (edges[i].y / cellSize).floor();
      int key = gy * gridW + gx;
      grid.putIfAbsent(key, () => []).add(i);
    }

    // Find connected components
    List<bool> visited = List.filled(edges.length, false);
    List<List<int>> components = [];

    for (int i = 0; i < edges.length; i++) {
      if (visited[i]) continue;

      List<int> component = [];
      List<int> stack = [i];
      visited[i] = true;

      while (stack.isNotEmpty) {
        int cur = stack.removeLast();
        component.add(cur);

        int gx = (edges[cur].x / cellSize).floor();
        int gy = (edges[cur].y / cellSize).floor();

        // Check neighbors in 3x3 grid cells
        for (int dy = -1; dy <= 1; dy++) {
          for (int dx = -1; dx <= 1; dx++) {
            int key = (gy + dy) * gridW + (gx + dx);
            var neighbors = grid[key];
            if (neighbors == null) continue;

            for (int ni in neighbors) {
              if (visited[ni]) continue;
              double dist = math.sqrt(math.pow(edges[ni].x - edges[cur].x, 2) +
                  math.pow(edges[ni].y - edges[cur].y, 2));
              if (dist < 5.0) {
                visited[ni] = true;
                stack.add(ni);
              }
            }
          }
        }
      }

      components.add(component);
    }

    List<int> best = [];
    double bestScore = double.negativeInfinity;
    final imageCenterX = width * 0.5;

    for (final comp in components) {
      if (comp.length < 12) continue;

      double minX = double.infinity;
      double maxX = double.negativeInfinity;
      double minY = double.infinity;
      double maxY = double.negativeInfinity;
      double sumX = 0.0;
      int borderTouches = 0;
      int nearBottom = 0;

      for (final idx in comp) {
        final p = edges[idx];
        minX = math.min(minX, p.x);
        maxX = math.max(maxX, p.x);
        minY = math.min(minY, p.y);
        maxY = math.max(maxY, p.y);
        sumX += p.x;
        if (p.x <= 3.0 ||
            p.x >= width - 4.0 ||
            p.y <= 3.0 ||
            p.y >= height - 4.0) {
          borderTouches++;
        }
        if (p.y >= height * 0.78) nearBottom++;
      }

      final w = maxX - minX;
      final h = maxY - minY;
      final meanX = sumX / comp.length;
      final centerPenalty =
          (meanX - imageCenterX).abs() / math.max(1.0, width * 0.5);
      final widthPenalty = w > width * 0.92
          ? (w - width * 0.92) / math.max(1.0, width.toDouble())
          : 0.0;

      double score = comp.length +
          8.0 * h +
          0.25 * nearBottom -
          2.2 * borderTouches -
          40.0 * centerPenalty -
          180.0 * widthPenalty;
      if (h < 10.0) score -= 120.0;

      if (score > bestScore) {
        bestScore = score;
        best = comp;
      }
    }

    if (best.isEmpty) {
      List<int> largest = [];
      for (final comp in components) {
        if (comp.length > largest.length) largest = comp;
      }
      best = largest;
    }

    return best.map((i) => edges[i]).toList();
  }

  /// Detect baseline using robust RANSAC + least-squares refinement.
  static Map<String, dynamic> _detectBaseline(
      List<math.Point<double>> contour) {
    if (contour.isEmpty) {
      return {
        'slope': 0.0,
        'intercept': 0.0,
        'angle': 0.0,
        'angle_rad': 0.0,
        'rms': 0.0,
      };
    }

    final double maxY = contour.map((p) => p.y).reduce(math.max);
    final double minY = contour.map((p) => p.y).reduce(math.min);
    final double yRange = (maxY - minY).abs();
    final double bottomBand = (yRange * 0.10).clamp(8.0, 22.0);

    final bottomPoints =
        contour.where((p) => p.y >= maxY - bottomBand).toList();
    if (bottomPoints.length < 6) {
      return {
        'slope': 0.0,
        'intercept': maxY,
        'angle': 0.0,
        'angle_rad': 0.0,
        'rms': 0.0,
      };
    }

    final rnd = math.Random(42);
    final double minDx = ((bottomPoints.map((p) => p.x).reduce(math.max) -
                bottomPoints.map((p) => p.x).reduce(math.min)) *
            0.05)
        .clamp(6.0, 30.0);

    double bestSlope = 0.0;
    double bestIntercept = maxY;
    double bestScore = double.negativeInfinity;
    List<math.Point<double>> bestInliers = [];

    for (int iter = 0; iter < 160; iter++) {
      final p1 = bottomPoints[rnd.nextInt(bottomPoints.length)];
      final p2 = bottomPoints[rnd.nextInt(bottomPoints.length)];
      final dx = p2.x - p1.x;
      if (dx.abs() < minDx) continue;

      final slope = (p2.y - p1.y) / dx;
      final angleDeg = math.atan(slope) * 180.0 / math.pi;
      if (angleDeg.abs() > _maxBaselineTiltDeg) continue;

      final intercept = p1.y - slope * p1.x;
      final denom = math.sqrt(1.0 + slope * slope);
      final inliers = <math.Point<double>>[];
      double errSum = 0.0;
      for (final p in bottomPoints) {
        final dist = ((slope * p.x - p.y + intercept).abs()) / denom;
        if (dist < 2.2) {
          inliers.add(p);
          errSum += dist;
        }
      }

      if (inliers.length < 5) continue;
      final meanErr = errSum / inliers.length;
      final score = inliers.length - 0.35 * meanErr;
      if (score > bestScore) {
        bestScore = score;
        bestSlope = slope;
        bestIntercept = intercept;
        bestInliers = inliers;
      }
    }

    if (bestInliers.length >= 5) {
      final refined = _fitLineLeastSquares(bestInliers);
      bestSlope = refined['slope']!;
      bestIntercept = refined['intercept']!;
    } else {
      bestSlope = 0.0;
      bestIntercept = maxY;
    }

    double angleRad = math.atan(bestSlope);
    double angleDeg = angleRad * 180.0 / math.pi;
    if (angleDeg.abs() > _maxBaselineTiltDeg) {
      bestSlope = 0.0;
      angleRad = 0.0;
      angleDeg = 0.0;
      bestIntercept = maxY;
      bestInliers = bottomPoints;
    }

    double rms = 0.0;
    if (bestInliers.isNotEmpty) {
      double sumSq = 0.0;
      for (final p in bestInliers) {
        final d = _lineDistance(p, bestSlope, bestIntercept);
        sumSq += d * d;
      }
      rms = math.sqrt(sumSq / bestInliers.length);
    }

    return {
      'slope': bestSlope,
      'intercept': bestIntercept,
      'angle': angleDeg,
      'angle_rad': angleRad,
      'rms': rms,
    };
  }

  static Map<String, double> _fitLineLeastSquares(
      List<math.Point<double>> points) {
    if (points.length < 2) return {'slope': 0.0, 'intercept': 0.0};

    double meanX =
        points.map((p) => p.x).reduce((a, b) => a + b) / points.length;
    double meanY =
        points.map((p) => p.y).reduce((a, b) => a + b) / points.length;

    double num = 0.0;
    double den = 0.0;
    for (final p in points) {
      final dx = p.x - meanX;
      num += dx * (p.y - meanY);
      den += dx * dx;
    }

    final slope = den.abs() > 1e-10 ? num / den : 0.0;
    final intercept = meanY - slope * meanX;
    return {'slope': slope, 'intercept': intercept};
  }

  static double _lineDistance(
    math.Point<double> point,
    double slope,
    double intercept,
  ) {
    return (slope * point.x - point.y + intercept).abs() /
        math.sqrt(1.0 + slope * slope);
  }

  static math.Point<double> _toBaselineFrame(
    math.Point<double> p,
    Map<String, dynamic> baseline,
  ) {
    final double slope = (baseline['slope'] as num).toDouble();
    final double intercept = (baseline['intercept'] as num).toDouble();
    final double angle = math.atan(slope);
    final double cosA = math.cos(angle);
    final double sinA = math.sin(angle);

    final double dx = p.x;
    final double dy = p.y - intercept;
    final double xAligned = dx * cosA + dy * sinA;
    final double yAligned = -dx * sinA + dy * cosA;
    return math.Point(xAligned, yAligned);
  }

  static math.Point<double> _fromBaselineFrame(
    math.Point<double> pAligned,
    Map<String, dynamic> baseline,
  ) {
    final double slope = (baseline['slope'] as num).toDouble();
    final double intercept = (baseline['intercept'] as num).toDouble();
    final double angle = math.atan(slope);
    final double cosA = math.cos(angle);
    final double sinA = math.sin(angle);

    final double x = pAligned.x * cosA - pAligned.y * sinA;
    final double y = intercept + pAligned.x * sinA + pAligned.y * cosA;
    return math.Point(x, y);
  }

  static Map<String, double> _detectContactPoints(
    List<math.Point<double>> dropContourAligned, {
    List<math.Point<double>>? fallbackContourAligned,
  }) {
    if (dropContourAligned.length < 8) {
      return _fallbackContactPoints(
        fallbackContourAligned ?? dropContourAligned,
      );
    }

    final apex = dropContourAligned.reduce((a, b) => a.y < b.y ? a : b);
    final apexX = apex.x;

    final leftAll = dropContourAligned.where((p) => p.x < apexX - 0.6).toList();
    final rightAll =
        dropContourAligned.where((p) => p.x > apexX + 0.6).toList();
    if (leftAll.length < 4 || rightAll.length < 4) {
      return _fallbackContactPoints(
        fallbackContourAligned ?? dropContourAligned,
      );
    }

    List<math.Point<double>> nearBaseline(List<math.Point<double>> points) {
      var primary = points.where((p) => p.y > -6.0).toList();
      if (primary.length >= 4) return primary;
      primary = points.where((p) => p.y > -14.0).toList();
      if (primary.length >= 4) return primary;
      return points;
    }

    final leftCandidates = nearBaseline(leftAll);
    final rightCandidates = nearBaseline(rightAll);
    final leftX = _estimateContactX(leftCandidates, isLeft: true);
    final rightX = _estimateContactX(rightCandidates, isLeft: false);

    bool hasVerticalSupport(double x) {
      final support = dropContourAligned
          .where((p) => (p.x - x).abs() <= 8.0 && p.y < -7.0)
          .length;
      return support >= 3;
    }

    if (leftX.isFinite &&
        rightX.isFinite &&
        rightX > leftX + 6.0 &&
        hasVerticalSupport(leftX) &&
        hasVerticalSupport(rightX)) {
      return {'leftX': leftX, 'rightX': rightX};
    }

    return _fallbackContactPoints(
      fallbackContourAligned ?? dropContourAligned,
    );
  }

  static double _estimateContactX(
    List<math.Point<double>> sidePoints, {
    required bool isLeft,
  }) {
    if (sidePoints.isEmpty) return double.nan;
    final byBaseline = List<math.Point<double>>.from(sidePoints)
      ..sort((a, b) => b.y.compareTo(a.y));
    final topCount =
        math.min(20, math.max(6, (byBaseline.length * 0.35).round()));
    final top = byBaseline.take(topCount).toList();

    top.sort((a, b) => isLeft ? b.x.compareTo(a.x) : a.x.compareTo(b.x));
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

  static Map<String, double> _fallbackContactPoints(
    List<math.Point<double>> contourAligned,
  ) {
    final nearBaseline = contourAligned.where((p) => p.y.abs() <= 5.0).toList();
    if (nearBaseline.length < 4) {
      return {'leftX': double.nan, 'rightX': double.nan};
    }

    final minX = nearBaseline.map((p) => p.x).reduce(math.min);
    final maxX = nearBaseline.map((p) => p.x).reduce(math.max);
    final centerX = (minX + maxX) * 0.5;
    final left = nearBaseline.where((p) => p.x < centerX).toList();
    final right = nearBaseline.where((p) => p.x > centerX).toList();
    if (left.isEmpty || right.isEmpty) {
      return {'leftX': double.nan, 'rightX': double.nan};
    }

    final leftX = left.map((p) => p.x).reduce(math.max);
    final rightX = right.map((p) => p.x).reduce(math.min);
    if (!(leftX.isFinite && rightX.isFinite && rightX > leftX + 4.0)) {
      return {'leftX': double.nan, 'rightX': double.nan};
    }

    return {'leftX': leftX, 'rightX': rightX};
  }

  static double _baselineYAtX(Map<String, dynamic> baseline, double x) {
    final slope = (baseline['slope'] as num).toDouble();
    final intercept = (baseline['intercept'] as num).toDouble();
    return slope * x + intercept;
  }

  /// Calculate ensemble angle from multiple methods weighted by R²
  static Map<String, dynamic> _calculateEnsembleAngle(
      Map<String, Map<String, dynamic>> methodResults) {
    final validAngles = <double>[];
    for (final result in methodResults.values) {
      final angle = (result['angle'] as num?)?.toDouble() ?? double.nan;
      if (_isMethodValid(result) && angle.isFinite) validAngles.add(angle);
    }
    validAngles.sort();
    final medianAngle = validAngles.isEmpty
        ? 90.0
        : (validAngles.length.isOdd
            ? validAngles[validAngles.length ~/ 2]
            : (validAngles[validAngles.length ~/ 2 - 1] +
                    validAngles[validAngles.length ~/ 2]) /
                2.0);

    double sumAngle = 0.0, sumWeight = 0.0;
    double sumLeft = 0.0, sumRight = 0.0;
    double sumWeightLR = 0.0;
    Map<String, double> weights = {};

    for (var entry in methodResults.entries) {
      if (!_isMethodValid(entry.value)) continue;
      double angle = (entry.value['angle'] as num?)?.toDouble() ?? double.nan;
      double rSq = (entry.value['r_squared'] as num?)?.toDouble() ?? 0.5;

      if (!angle.isFinite) continue;

      rSq = rSq.clamp(0.0, 1.0);
      // Start from quality, then suppress strong outliers in method disagreement.
      double weight = rSq >= _minRSquared ? (rSq * rSq + 0.05) : rSq * 0.35;
      final disagreement = (angle - medianAngle).abs();
      weight *= math.exp(-disagreement / 18.0);

      // Additional weight for Young-Laplace (physics-based)
      if (entry.key == 'young_laplace' && rSq > 0.7) weight *= 1.1;
      if (entry.key == 'polynomial') {
        final usedPoints =
            (entry.value['used_points'] as num?)?.toDouble() ?? 0.0;
        if (usedPoints < 12.0) weight *= 0.7;
      }
      if (weight < 1e-5) continue;

      sumAngle += angle * weight;
      sumWeight += weight;
      weights[entry.key] = weight;

      // Handle left/right angles
      double? left = (entry.value['angle_left'] as num?)?.toDouble();
      double? right = (entry.value['angle_right'] as num?)?.toDouble();
      if (left != null && left.isFinite && right != null && right.isFinite) {
        sumLeft += left * weight;
        sumRight += right * weight;
        sumWeightLR += weight;
      }
    }

    if (sumWeight < 0.01) {
      final poly = methodResults['polynomial'];
      if (_isMethodValid(poly)) {
        final polyAngle = (poly!['angle'] as num?)?.toDouble() ?? 90.0;
        final polyLeft = (poly['angle_left'] as num?)?.toDouble() ?? polyAngle;
        final polyRight =
            (poly['angle_right'] as num?)?.toDouble() ?? polyAngle;
        return {
          'angle': polyAngle,
          'angle_left': polyLeft,
          'angle_right': polyRight,
          'weights': {'polynomial': 1.0},
        };
      }
      final fallback = validAngles.isNotEmpty ? _median(validAngles) : 90.0;
      return {
        'angle': fallback,
        'angle_left': fallback,
        'angle_right': fallback,
        'weights': weights,
      };
    }

    double ensembleAngle = sumAngle / sumWeight;
    double ensembleLeft =
        sumWeightLR > 0 ? sumLeft / sumWeightLR : ensembleAngle;
    double ensembleRight =
        sumWeightLR > 0 ? sumRight / sumWeightLR : ensembleAngle;

    // Normalize weights
    for (var key in weights.keys) {
      weights[key] = weights[key]! / sumWeight;
    }

    return {
      'angle': ensembleAngle,
      'angle_left': ensembleLeft,
      'angle_right': ensembleRight,
      'weights': weights,
    };
  }

  /// Calculate combined uncertainty from multiple sources
  static Map<String, double> _calculateUncertainty(
      List<double> xs,
      List<double> ys,
      List<math.Point<double>> leftPoints,
      List<math.Point<double>> rightPoints,
      double baselineY,
      double leftX,
      double rightX,
      Map<String, Map<String, dynamic>> methodResults) {
    // 1. Bootstrap uncertainty with multi-model sampling.
    List<double> bootstrapAngles = [];
    final rnd = math.Random(7);

    for (int t = 0; t < _bootstrapIterations; t++) {
      try {
        if (xs.length < 10) break;
        final indices = List.generate(xs.length, (_) => rnd.nextInt(xs.length));
        final sX = indices.map((i) => xs[i]).toList();
        final sY = indices.map((i) => ys[i]).toList();
        final sampleAngles = <double>[];

        final circle = AngleUtils.circleFit(sX, sY);
        final thetaCircle = AngleUtils.calculateCircleAngle(circle, baselineY);
        final circleRSq = circle.length > 3 ? circle[3] : 0.0;
        if (_isAnglePlausible(thetaCircle) && circleRSq >= _minCircleRSquared) {
          sampleAngles.add(thetaCircle);
        }

        if (sX.length >= 12) {
          final ellipse = AngleUtils.ellipseFit(sX, sY);
          final thetaEllipseLeft =
              AngleUtils.calculateEllipseAngle(ellipse, baselineY, leftX, true);
          final thetaEllipseRight = AngleUtils.calculateEllipseAngle(
              ellipse, baselineY, rightX, false);
          final thetaEllipse = (thetaEllipseLeft + thetaEllipseRight) / 2.0;
          final ellipseRSq = ellipse.length > 5 ? ellipse[5] : 0.0;
          if (_isAnglePlausible(thetaEllipse) &&
              ellipseRSq >= _minEllipseRSquared &&
              (thetaEllipseLeft - thetaEllipseRight).abs() <= 45.0) {
            sampleAngles.add(thetaEllipse);
          }
        }

        if (sampleAngles.isNotEmpty) {
          final theta =
              sampleAngles.reduce((a, b) => a + b) / sampleAngles.length;
          bootstrapAngles.add(theta);
        }
      } catch (_) {}
    }

    double bootstrapUncertainty = 0.0;
    if (bootstrapAngles.length >= 12) {
      bootstrapUncertainty = (_percentile(bootstrapAngles, 97.5) -
              _percentile(bootstrapAngles, 2.5)) /
          2.0;
    }

    // 2. Inter-method disagreement (robust MAD estimate).
    List<double> methodAngles = [];
    for (final entry in methodResults.values) {
      final angle = (entry['angle'] as num?)?.toDouble() ?? double.nan;
      if (_isMethodValid(entry) && angle.isFinite) methodAngles.add(angle);
    }

    double methodDisagreement = 0.0;
    if (methodAngles.length >= 2) {
      final median = _median(methodAngles);
      final absDev = methodAngles.map((v) => (v - median).abs()).toList();
      final mad = _median(absDev);
      methodDisagreement = 1.4826 * mad;
      if (methodDisagreement < 1e-8) {
        methodDisagreement = _sampleStdDev(methodAngles);
      }
    }

    // 3. Edge localization uncertainty from near-contact point spread.
    final leftBand = leftPoints
        .where((p) => (p.x - leftX).abs() <= 8.0)
        .map((p) => p.y.abs())
        .toList();
    final rightBand = rightPoints
        .where((p) => (p.x - rightX).abs() <= 8.0)
        .map((p) => p.y.abs())
        .toList();

    double edgeSpreadPx = 0.6;
    final spreads = <double>[];
    if (leftBand.length >= 3) spreads.add(_sampleStdDev(leftBand));
    if (rightBand.length >= 3) spreads.add(_sampleStdDev(rightBand));
    if (spreads.isNotEmpty) {
      edgeSpreadPx = spreads.reduce((a, b) => a + b) / spreads.length;
    }

    final dropRadius = math.max(5.0, (rightX - leftX).abs() / 2.0);
    double edgeUncertainty =
        math.atan(edgeSpreadPx / dropRadius) * 180.0 / math.pi;
    edgeUncertainty = edgeUncertainty.clamp(0.12, 1.5);

    // 4. Combined uncertainty (quadrature).
    double combined = math.sqrt(
      bootstrapUncertainty * bootstrapUncertainty +
          methodDisagreement * methodDisagreement +
          edgeUncertainty * edgeUncertainty,
    );

    combined = combined.clamp(0.25, 20.0);

    return {
      'combined': combined,
      'bootstrap': bootstrapUncertainty,
      'method_disagreement': methodDisagreement,
      'edge': edgeUncertainty,
    };
  }

  static double _sampleStdDev(List<double> values) {
    if (values.length < 2) return 0.0;
    final mean = values.reduce((a, b) => a + b) / values.length;
    double sumSq = 0.0;
    for (final v in values) {
      final d = v - mean;
      sumSq += d * d;
    }
    return math.sqrt(sumSq / (values.length - 1));
  }

  static double _median(List<double> values) {
    if (values.isEmpty) return 0.0;
    final sorted = List<double>.from(values)..sort();
    final mid = sorted.length ~/ 2;
    if (sorted.length.isOdd) return sorted[mid];
    return (sorted[mid - 1] + sorted[mid]) / 2.0;
  }

  static double _percentile(List<double> values, double p) {
    if (values.isEmpty) return 0.0;
    final sorted = List<double>.from(values)..sort();
    final pos = (p.clamp(0.0, 100.0) / 100.0) * (sorted.length - 1);
    final lo = pos.floor();
    final hi = pos.ceil();
    if (lo == hi) return sorted[lo];
    final t = pos - lo;
    return sorted[lo] * (1.0 - t) + sorted[hi] * t;
  }

  /// Annotate image with analysis results
  static void _annotateImage(
    imglib.Image annotated,
    List<math.Point<double>> contour,
    Map<String, dynamic> baseline,
    math.Point<double> leftContactOriginal,
    math.Point<double> rightContactOriginal,
    double leftXAligned,
    double rightXAligned,
    Map<String, Map<String, dynamic>> methodResults,
    double thetaFinal,
    double thetaLeft,
    double thetaRight,
  ) {
    // Draw contour (green)
    for (var p in contour) {
      int px = p.x.round();
      int py = p.y.round();
      if (px >= 0 && px < annotated.width && py >= 0 && py < annotated.height) {
        annotated.setPixelRgba(px, py, 0, 255, 0, 255);
      }
    }

    // Draw baseline (red)
    for (int x = 0; x < annotated.width; x++) {
      int y = _baselineYAtX(baseline, x.toDouble()).round();
      if (y >= 0 && y < annotated.height) {
        annotated.setPixelRgba(x, y, 255, 0, 0, 220);
      }
    }

    // Draw contact points (magenta, thicker)
    for (int dy = -2; dy <= 2; dy++) {
      for (int dx = -2; dx <= 2; dx++) {
        int lx = leftContactOriginal.x.round() + dx;
        int ly = leftContactOriginal.y.round() + dy;
        int rx = rightContactOriginal.x.round() + dx;
        int ry = rightContactOriginal.y.round() + dy;
        if (lx >= 0 &&
            lx < annotated.width &&
            ly >= 0 &&
            ly < annotated.height) {
          annotated.setPixelRgba(lx, ly, 255, 0, 255, 255);
        }
        if (rx >= 0 &&
            rx < annotated.width &&
            ry >= 0 &&
            ry < annotated.height) {
          annotated.setPixelRgba(rx, ry, 255, 0, 255, 255);
        }
      }
    }

    // Draw fitted circle (cyan) if available
    final circleResult = methodResults['circle'];
    var circleParams = circleResult?['params'];
    if (_isMethodValid(circleResult) &&
        circleParams != null &&
        circleParams is List &&
        circleParams.length >= 3) {
      double cx = (circleParams[0] as num).toDouble();
      double cy = (circleParams[1] as num).toDouble();
      double r = (circleParams[2] as num).toDouble();
      if (r.isFinite && r > 1 && cx.isFinite && cy.isFinite) {
        int steps = (2 * math.pi * r).ceil().clamp(16, 2000);
        for (int i = 0; i < steps; i++) {
          double ang = (i / steps) * 2.0 * math.pi;
          final pAligned = math.Point(
            cx + r * math.cos(ang),
            cy + r * math.sin(ang),
          );
          final p = _fromBaselineFrame(pAligned, baseline);
          int px = p.x.round();
          int py = p.y.round();
          if (px >= 0 &&
              px < annotated.width &&
              py >= 0 &&
              py < annotated.height) {
            annotated.setPixelRgba(px, py, 0, 255, 255, 180);
          }
        }
      }
    }

    // Draw fitted ellipse (yellow) if available
    final ellipseResult = methodResults['ellipse'];
    var ellipseParams = ellipseResult?['params'];
    if (_isMethodValid(ellipseResult) &&
        ellipseParams != null &&
        ellipseParams is List &&
        ellipseParams.length >= 5) {
      double cx = (ellipseParams[0] as num).toDouble();
      double cy = (ellipseParams[1] as num).toDouble();
      double a = (ellipseParams[2] as num).toDouble();
      double b = (ellipseParams[3] as num).toDouble();
      double theta = (ellipseParams[4] as num).toDouble();
      if (a.isFinite && b.isFinite && a > 1 && b > 1) {
        int steps = (2 * math.pi * math.max(a, b)).ceil().clamp(32, 2000);
        for (int i = 0; i < steps; i++) {
          double t = (i / steps) * 2.0 * math.pi;
          double xe = a * math.cos(t);
          double ye = b * math.sin(t);
          final pAligned = math.Point(
            cx + xe * math.cos(theta) - ye * math.sin(theta),
            cy + xe * math.sin(theta) + ye * math.cos(theta),
          );
          final p = _fromBaselineFrame(pAligned, baseline);
          int px = p.x.round();
          int py = p.y.round();
          if (px >= 0 &&
              px < annotated.width &&
              py >= 0 &&
              py < annotated.height) {
            annotated.setPixelRgba(px, py, 255, 255, 0, 180);
          }
        }
      }
    }

    // Draw tangent lines at contact points (orange)
    double tanLengthLeft = 30.0 + 0.12 * (thetaFinal - 90.0).abs();
    double tanLengthRight = 30.0 + 0.12 * (thetaFinal - 90.0).abs();
    double angleLeftRad = thetaLeft * math.pi / 180.0;
    double angleRightRad = thetaRight * math.pi / 180.0;

    // Left tangent
    for (int i = 0; i < tanLengthLeft.toInt(); i++) {
      double t = i / tanLengthLeft;
      final pAligned = math.Point(
        leftXAligned + t * tanLengthLeft * math.cos(math.pi - angleLeftRad),
        -t * tanLengthLeft * math.sin(math.pi - angleLeftRad),
      );
      final p = _fromBaselineFrame(pAligned, baseline);
      int px = p.x.round();
      int py = p.y.round();
      if (px >= 0 && px < annotated.width && py >= 0 && py < annotated.height) {
        annotated.setPixelRgba(px, py, 255, 128, 0, 255);
      }
    }

    // Right tangent
    for (int i = 0; i < tanLengthRight.toInt(); i++) {
      double t = i / tanLengthRight;
      final pAligned = math.Point(
        rightXAligned - t * tanLengthRight * math.cos(math.pi - angleRightRad),
        -t * tanLengthRight * math.sin(math.pi - angleRightRad),
      );
      final p = _fromBaselineFrame(pAligned, baseline);
      int px = p.x.round();
      int py = p.y.round();
      if (px >= 0 && px < annotated.width && py >= 0 && py < annotated.height) {
        annotated.setPixelRgba(px, py, 255, 128, 0, 255);
      }
    }
  }
}
