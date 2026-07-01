part of '../image_processor.dart';

  /// Annotate image with analysis results
void _annotateImage(
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
        rightXAligned + t * tanLengthRight * math.cos(angleRightRad),
        -t * tanLengthRight * math.sin(angleRightRad),
      );
      final p = _fromBaselineFrame(pAligned, baseline);
      int px = p.x.round();
      int py = p.y.round();
      if (px >= 0 && px < annotated.width && py >= 0 && py < annotated.height) {
        annotated.setPixelRgba(px, py, 255, 128, 0, 255);
      }
    }
  }

