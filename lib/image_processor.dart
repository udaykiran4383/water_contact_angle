import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as imglib;
import 'package:path_provider/path_provider.dart';

import 'processing/angle_utils.dart';

class ImageProcessor {
  /// Extract red channel from pixel (handles multiple formats)
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

  /// Draw tangent line exactly at baseline contact point
  static void _drawTangentWithSlope(
    imglib.Image img,
    double contactX,
    double contactY,
    double slope,
    List<int> rgb,
    bool isLeftSide, {
    double length = 50.0,
  }) {
    // Direction vector along tangent
    double dx_dir = 1.0;
    double dy_dir = slope;

    double len_vec = math.sqrt(dx_dir * dx_dir + dy_dir * dy_dir);
    if (len_vec < 1e-6 || !len_vec.isFinite) {
      dx_dir = 1.0;
      dy_dir = 0.0;
      len_vec = 1.0;
    }
    double dx_norm = dx_dir / len_vec;
    double dy_norm = dy_dir / len_vec;

    double half = length / 2.0;
    double startX = contactX - dx_norm * half;
    double startY = contactY - dy_norm * half;
    double endX = contactX + dx_norm * half;
    double endY = contactY + dy_norm * half;

    _drawLineRgba(img, startX.round(), startY.round(), endX.round(), endY.round(), rgb[0], rgb[1], rgb[2], 255, thickness: 3);
  }

  /// Find contact point closest to baseline
  static math.Point<double>? _findContactPoint(
    List<math.Point<double>> contour,
    double baselineY,
    bool isLeftSide,
    double centerX,
  ) {
    final sidePts = contour
        .where((p) => isLeftSide ? p.x < centerX : p.x > centerX)
        .toList();
    if (sidePts.isEmpty) return null;

    math.Point<double> best = sidePts.first;
    double minDiff = (best.y - baselineY).abs();
    for (final p in sidePts) {
      final d = (p.y - baselineY).abs();
      if (d < minDiff) {
        minDiff = d;
        best = p;
      }
    }
    return best;
  }

  /// Find contact point using curvature analysis
  static math.Point<double>? _findCurvatureContact(
    List<math.Point<double>> contour,
    double baselineY,
    bool isLeftSide,
    double centerX,
    {double band = 8.0}
  ) {
    final side = contour
        .where((p) => (isLeftSide ? p.x < centerX : p.x > centerX) && (p.y - baselineY).abs() < band)
        .toList();
    if (side.length < 5) return null;

    side.sort((a, b) => a.x.compareTo(b.x));

    double maxCurv = -1.0;
    math.Point<double>? best;
    for (int i = 1; i < side.length - 1; i++) {
      final p1 = side[i - 1];
      final p2 = side[i];
      final p3 = side[i + 1];
      final a = math.sqrt(math.pow(p2.x - p1.x, 2) + math.pow(p2.y - p1.y, 2));
      final b = math.sqrt(math.pow(p3.x - p2.x, 2) + math.pow(p3.y - p2.y, 2));
      final c = math.sqrt(math.pow(p3.x - p1.x, 2) + math.pow(p3.y - p1.y, 2));
      final s = (a + b + c) / 2.0;
      final area2 = math.max(s * (s - a) * (s - b) * (s - c), 0.0);
      final area = math.sqrt(area2);
      final denom = (a * b * c) + 1e-6;
      final curv = (4.0 * area) / denom;
      if (curv > maxCurv) {
        maxCurv = curv;
        best = p2;
      }
    }
    return best;
  }

  /// Estimate local slope at contact point
  static double? _estimateLocalSlopeAt(
    List<math.Point<double>> contour,
    math.Point<double> contact,
  ) {
    double radius = 4.0;
    List<math.Point<double>> neighbors = [];
    for (int attempt = 0; attempt < 5; attempt++) {
      final r2 = radius * radius;
      neighbors = contour.where((p) {
        final dx = p.x - contact.x;
        final dy = p.y - contact.y;
        return (dx * dx + dy * dy) <= r2;
      }).toList();
      if (neighbors.length >= 8) break;
      radius += 2.0;
    }

    if (neighbors.length < 4) return null;

    final xs = neighbors.map((p) => p.x).toList();
    final ys = neighbors.map((p) => p.y).toList();
    final double sigma = math.max(1.5, radius / 2.5);
    final double twoSigma2 = 2.0 * sigma * sigma;
    final weights = <double>[];
    for (final p in neighbors) {
      final dx = p.x - contact.x;
      final dy = p.y - contact.y;
      final d2 = dx * dx + dy * dy;
      weights.add(math.exp(-d2 / twoSigma2));
    }

    double Sw = 0.0, Swx = 0.0, Swy = 0.0;
    for (int i = 0; i < neighbors.length; i++) {
      final w = weights[i];
      Sw += w;
      Swx += w * xs[i];
      Swy += w * ys[i];
    }
    if (Sw <= 0) return null;
    final meanX = Swx / Sw;
    final meanY = Swy / Sw;

    double varXw = 0.0, varYw = 0.0;
    for (int i = 0; i < neighbors.length; i++) {
      final w = weights[i];
      varXw += w * (xs[i] - meanX) * (xs[i] - meanX);
      varYw += w * (ys[i] - meanY) * (ys[i] - meanY);
    }

    if (varXw < varYw * 0.2) {
      double num = 0.0, den = 0.0;
      for (int i = 0; i < neighbors.length; i++) {
        final w = weights[i];
        num += w * (ys[i] - meanY) * (xs[i] - meanX);
        den += w * (ys[i] - meanY) * (ys[i] - meanY);
      }
      if (den.abs() < 1e-8) return null;
      final dx_dy = num / den;
      if (dx_dy.abs() < 1e-8) return null;
      return 1.0 / dx_dy;
    } else {
      double num = 0.0, den = 0.0;
      for (int i = 0; i < neighbors.length; i++) {
        final w = weights[i];
        num += w * (xs[i] - meanX) * (ys[i] - meanY);
        den += w * (xs[i] - meanX) * (xs[i] - meanX);
      }
      if (den.abs() < 1e-8) return null;
      return num / den;
    }
  }

  /// Draw line with thickness using Bresenham algorithm
  static void _drawLineRgba(imglib.Image img, int x1, int y1, int x2, int y2, int r, int g, int b, int a, {int thickness = 1}) {
    int dx = (x2 - x1).abs();
    int dy = (y2 - y1).abs();
    int sx = x1 < x2 ? 1 : -1;
    int sy = y1 < y2 ? 1 : -1;
    int err = dx - dy;
    int x = x1, y = y1;
    while (true) {
      if (x >= 0 && x < img.width && y >= 0 && y < img.height) {
        img.setPixelRgba(x, y, r, g, b, a);
        if (thickness > 1) {
          int nx = -(y2 - y1).sign;
          int ny = (x2 - x1).sign;
          int half = (thickness - 1) ~/ 2;
          for (int t = 1; t <= half; t++) {
            int ox1 = x + nx * t, oy1 = y + ny * t;
            int ox2 = x - nx * t, oy2 = y - ny * t;
            if (ox1 >= 0 && ox1 < img.width && oy1 >= 0 && oy1 < img.height) img.setPixelRgba(ox1, oy1, r, g, b, a);
            if (ox2 >= 0 && ox2 < img.width && oy2 >= 0 && oy2 < img.height) img.setPixelRgba(ox2, oy2, r, g, b, a);
          }
        }
      }
      if (x == x2 && y == y2) break;
      int e2 = 2 * err;
      if (e2 > -dy) { err -= dy; x += sx; }
      if (e2 < dx) { err += dx; y += sy; }
    }
  }

  /// Main image processing pipeline
  static Future<Map<String, dynamic>> processImage(File imageFile) async {
    try {
      print('🔍 Starting image processing: ${imageFile.path}');

      final Uint8List bytes = await imageFile.readAsBytes();
      imglib.Image? src = imglib.decodeImage(bytes);
      if (src == null) {
        return {'text': '❌ Failed to decode image. Try a different file.', 'annotated': null};
      }

      print('📐 Image size: ${src.width}x${src.height}');

      imglib.Image gray = imglib.grayscale(src);

      double meanIntensity = 0.0;
      for (int y = 0; y < gray.height; y++) {
        for (int x = 0; x < gray.width; x++) {
          final px = gray.getPixel(x, y);
          final r = _getRed(px);
          meanIntensity += r;
        }
      }
      meanIntensity /= (gray.width * gray.height);
      print('💡 Mean intensity: ${meanIntensity.toStringAsFixed(1)}');

      bool inverted = false;
      if (meanIntensity < 127) {
        for (int y = 0; y < gray.height; y++) {
          for (int x = 0; x < gray.width; x++) {
            final px = gray.getPixel(x, y);
            final r = _getRed(px);
            final inv = 255 - r;
            gray.setPixelRgba(x, y, inv, inv, inv, 255);
          }
        }
        inverted = true;
        print('🔄 Image inverted for darker background');
      }

      imglib.Image blurred = imglib.gaussianBlur(gray, radius: 3);

      final int width = blurred.width;
      final int height = blurred.height;
      final List<int> edgeMask = List.filled(width * height, 0);

      final gx = [
        [-1, 0, 1],
        [-2, 0, 2],
        [-1, 0, 1]
      ];
      final gy = [
        [-1, -2, -1],
        [0, 0, 0],
        [1, 2, 1]
      ];

      for (int y = 1; y < height - 1; y++) {
        for (int x = 1; x < width - 1; x++) {
          double sx = 0.0, sy = 0.0;
          for (int ky = -1; ky <= 1; ky++) {
            for (int kx = -1; kx <= 1; kx++) {
              final vpx = blurred.getPixel(x + kx, y + ky);
              final v = _getRed(vpx);
              sx += gx[ky + 1][kx + 1] * v;
              sy += gy[ky + 1][kx + 1] * v;
            }
          }
          double mag = math.sqrt(sx * sx + sy * sy);
          edgeMask[y * width + x] = mag > 70 ? 1 : 0;
        }
      }

      List<int> dilated = List.from(edgeMask);
      for (int y = 1; y < height - 1; y++) {
        for (int x = 1; x < width - 1; x++) {
          int maxv = 0;
          for (int ky = -1; ky <= 1; ky++) {
            for (int kx = -1; kx <= 1; kx++) {
              if (edgeMask[(y + ky) * width + (x + kx)] == 1) maxv = 1;
            }
          }
          dilated[y * width + x] = maxv;
        }
      }
      List<int> closed = List.from(dilated);
      for (int y = 1; y < height - 1; y++) {
        for (int x = 1; x < width - 1; x++) {
          int minv = 1;
          for (int ky = -1; ky <= 1; ky++) {
            for (int kx = -1; kx <= 1; kx++) {
              if (dilated[(y + ky) * width + (x + kx)] == 0) minv = 0;
            }
          }
          closed[y * width + x] = minv;
        }
      }

      final visited = List.filled(width * height, 0);
      int largestLabel = -1;
      int largestSize = 0;
      List<int> labels = List.filled(width * height, 0);
      int currentLabel = 1;

      for (int y = 0; y < height; y++) {
        for (int x = 0; x < width; x++) {
          int idx = y * width + x;
          if (closed[idx] == 1 && visited[idx] == 0) {
            int size = 0;
            List<int> stack = [idx];
            visited[idx] = 1;
            labels[idx] = currentLabel;
            while (stack.isNotEmpty) {
              int cur = stack.removeLast();
              size++;
              int cy_ = cur ~/ width;
              int cx_ = cur % width;
              for (int ny = cy_ - 1; ny <= cy_ + 1; ny++) {
                for (int nx = cx_ - 1; nx <= cx_ + 1; nx++) {
                  if (nx >= 0 && nx < width && ny >= 0 && ny < height) {
                    int nidx = ny * width + nx;
                    if (closed[nidx] == 1 && visited[nidx] == 0) {
                      visited[nidx] = 1;
                      labels[nidx] = currentLabel;
                      stack.add(nidx);
                    }
                  }
                }
              }
            }
            if (size > largestSize) {
              largestSize = size;
              largestLabel = currentLabel;
            }
            currentLabel++;
          }
        }
      }

      if (largestLabel == -1 || largestSize < 50) {
        return {'text': '❌ No droplet detected. Ensure high-contrast silhouette.', 'annotated': null};
      }

      List<math.Point<double>> contour = [];
      double minContourX = double.infinity, maxContourX = -double.infinity;
      for (int y = 0; y < height; y++) {
        for (int x = 0; x < width; x++) {
          int idx = y * width + x;
          if (labels[idx] == largestLabel) {
            contour.add(math.Point(x.toDouble(), y.toDouble()));
            minContourX = math.min(minContourX, x.toDouble());
            maxContourX = math.max(maxContourX, x.toDouble());
          }
        }
      }

      if (contour.length < 30) {
        return {'text': '❌ Droplet contour too small (${contour.length} pts). Crop/contrast.', 'annotated': null};
      }

      double roughBaseline = contour.map((p) => p.y).reduce(math.max);
      double bottomThreshold = 3.0;
      List<double> bottomYs = contour.where((p) => p.y > roughBaseline - bottomThreshold).map((p) => p.y).toList();
      double baselineY = bottomYs.isNotEmpty ? bottomYs.fold(0.0, (a, b) => a + b) / bottomYs.length : roughBaseline;

      List<math.Point<double>> bottomPoints = contour.where((p) => p.y > baselineY - bottomThreshold).toList();
      if (bottomPoints.isEmpty) {
        return {'text': '❌ Could not locate contact points. Ensure droplet touches surface.', 'annotated': null};
      }
      double leftX = bottomPoints.map((p) => p.x).reduce(math.min);
      double rightX = bottomPoints.map((p) => p.x).reduce(math.max);

      double centerX = (leftX + rightX) / 2.0;

      print('📍 Contacts: left=${leftX.toStringAsFixed(0)} right=${rightX.toStringAsFixed(0)} baselineY=${baselineY.toStringAsFixed(0)}');

      List<double> xs = [], ys = [];
      for (var p in contour) {
        final px = p.x.toDouble();
        final py = p.y.toDouble();
        if (py < baselineY - 3) {
          xs.add(px);
          ys.add(py);
        }
      }

      if (xs.length < 8) {
        return {'text': '❌ Not enough points for fitting (${xs.length}).', 'annotated': null};
      }

      var circle = AngleUtils.circleFit(xs, ys);
      double thetaCircle = AngleUtils.calculateCircleAngle(circle, baselineY);

      double spanLeftX = leftX;
      double spanRightX = rightX;

      double localRange = 35.0;
      List<math.Point<double>> leftPoints = contour.where((p) => p.x >= leftX - localRange && p.x <= leftX + localRange).toList();
      List<math.Point<double>> rightPoints = contour.where((p) => p.x >= rightX - localRange && p.x <= rightX + localRange).toList();

      var leftRes = AngleUtils.polynomialAngle(leftPoints, spanLeftX, baselineY, true);
      var rightRes = AngleUtils.polynomialAngle(rightPoints, spanRightX, baselineY, false);
      double thetaPolyLeft = leftRes['angle']!;
      double thetaPolyRight = rightRes['angle']!;
      double slopeLeft = leftRes['slope']!;
      double slopeRight = rightRes['slope']!;
      double thetaPoly = (thetaPolyLeft + thetaPolyRight) / 2.0;
      double thetaFinal = (thetaCircle + thetaPoly) / 2.0;

      List<double> bs = [];
      final rnd = math.Random();
      for (int t = 0; t < 12; t++) {
        List<int> idxs = List.generate(xs.length, (_) => rnd.nextInt(xs.length));
        List<double> sX = idxs.map((i) => xs[i]).toList();
        List<double> sY = idxs.map((i) => ys[i]).toList();
        try {
          var c2 = AngleUtils.circleFit(sX, sY);
          double thC = AngleUtils.calculateCircleAngle(c2, baselineY);
          double thP = thetaPoly + (rnd.nextDouble() - 0.5) * 5.0;
          bs.add((thC + thP) / 2.0);
        } catch (_) {}
      }
      double uncertainty = 0.0;
      if (bs.length >= 2) {
        double meanBs = bs.reduce((a, b) => a + b) / bs.length;
        double varianceVal = bs.map((t) => math.pow(t - meanBs, 2)).reduce((a, b) => a + b) / (bs.length - 1);
        double sd = math.sqrt(varianceVal);
        uncertainty = 1.96 * sd / math.sqrt(bs.length);
      }

      imglib.Image annotated = src.clone();

      for (var p in contour) {
        int px = p.x.toInt();
        int py = p.y.toInt();
        if (py < baselineY &&
            px >= 0 && px < annotated.width && py >= 0 && py < annotated.height) {
          annotated.setPixelRgba(px, py, 0, 255, 0, 255);
        }
      }

      int by = baselineY.round();
      int startXDraw = (spanLeftX - 10).clamp(0, annotated.width).toInt();
      int endXDraw = (spanRightX + 10).clamp(0, annotated.width).toInt();
      for (int x = startXDraw; x <= endXDraw; x++) {
        if (by >= 0 && by < annotated.height) annotated.setPixelRgba(x, by, 255, 255, 255, 255);
      }

      try {
        double cx_ = circle[0], cy_ = circle[1], r = circle[2];
        if (r.isFinite && r > 1 && cx_.isFinite && cy_.isFinite) {
          double h = baselineY - cy_;
          if (h.abs() < r) {
            double discriminant = r * r - h * h;
            if (discriminant >= 0) {
              double sqrtDisc = math.sqrt(discriminant);
              double leftContactX = cx_ - sqrtDisc;
              double rightContactX = cx_ + sqrtDisc;
              
              double leftAngle = math.atan2(baselineY - cy_, leftContactX - cx_);
              double rightAngle = math.atan2(baselineY - cy_, rightContactX - cx_);
              
              if (rightAngle < leftAngle) rightAngle += 2 * math.pi;
              
              double arcLength = r * (rightAngle - leftAngle);
              int steps = math.max(16, (arcLength / 2).ceil()).clamp(16, 500);
              
              for (int i = 0; i <= steps; i++) {
                double t = i / steps;
                double ang = leftAngle + t * (rightAngle - leftAngle);
                double pxD = cx_ + r * math.cos(ang);
                double pyD = cy_ + r * math.sin(ang);
                int px = pxD.round();
                int py = pyD.round();
                
                if (px >= 0 && px < annotated.width && py >= 0 && py < annotated.height) {
                  annotated.setPixelRgba(px, py, 0, 255, 0, 255);
                }
              }
            }
          }
        }
      } catch (_) {}

      final circleContacts = AngleUtils.getCircleBaselineIntersections(circle, baselineY);
      math.Point<double>? leftContact;
      math.Point<double>? rightContact;
      
      if (circleContacts.length >= 2) {
        leftContact = circleContacts[0];
        rightContact = circleContacts[1];
      } else {
        leftContact = _findCurvatureContact(contour, baselineY, true, centerX) ??
          _findContactPoint(contour, baselineY, true, centerX);
        rightContact = _findCurvatureContact(contour, baselineY, false, centerX) ??
          _findContactPoint(contour, baselineY, false, centerX);
      }

      if (leftContact != null) {
        double circleSlope = AngleUtils.getTangentSlopeAtContact(circle, leftContact.x, baselineY);
        if (circleSlope.isFinite) {
          slopeLeft = circleSlope;
          double angleFromHorizontal = (math.atan(slopeLeft.abs()) * 180.0 / math.pi);
          thetaPolyLeft = 180.0 - angleFromHorizontal;
        }
      }

      if (rightContact != null) {
        double circleSlope = AngleUtils.getTangentSlopeAtContact(circle, rightContact.x, baselineY);
        if (circleSlope.isFinite) {
          slopeRight = circleSlope;
          double angleFromHorizontal = (math.atan(slopeRight.abs()) * 180.0 / math.pi);
          thetaPolyRight = 180.0 - angleFromHorizontal;
        }
      }

      if (leftContact != null) {
        _drawTangentWithSlope(annotated, leftContact.x, baselineY, slopeLeft, [0, 230, 0], true, length: 50.0);
        final cx = leftContact.x.round();
        final cy = baselineY.round();
        for (int dx = -2; dx <= 2; dx++) {
          int x = cx + dx;
          if (x >= 0 && x < annotated.width && cy >= 0 && cy < annotated.height) {
            annotated.setPixelRgba(x, cy, 255, 255, 0, 255);
          }
        }
      } else {
        _drawTangentWithSlope(annotated, spanLeftX, baselineY, slopeLeft, [0, 230, 0], true, length: 50.0);
      }
      
      if (rightContact != null) {
        _drawTangentWithSlope(annotated, rightContact.x, baselineY, slopeRight, [255, 0, 0], false, length: 50.0);
        final cx = rightContact.x.round();
        final cy = baselineY.round();
        for (int dx = -2; dx <= 2; dx++) {
          int x = cx + dx;
          if (x >= 0 && x < annotated.width && cy >= 0 && cy < annotated.height) {
            annotated.setPixelRgba(x, cy, 255, 255, 0, 255);
          }
        }
      } else {
        _drawTangentWithSlope(annotated, spanRightX, baselineY, slopeRight, [255, 0, 0], false, length: 50.0);
      }

      thetaPoly = (thetaPolyLeft + thetaPolyRight) / 2.0;
      thetaFinal = thetaPoly;

      final lText = 'θL=${thetaPolyLeft.toStringAsFixed(1)}°';
      final rText = 'θR=${thetaPolyRight.toStringAsFixed(1)}°';
      final radiusText = 'R=${circle[2].toStringAsFixed(1)}';
      
      int lx = (((leftContact?.x ?? spanLeftX) - 40)).clamp(0, annotated.width - 60).round();
      int ly = ((baselineY - 50)).clamp(0, annotated.height - 1).round();
      
      int rx = (((rightContact?.x ?? spanRightX) + 10)).clamp(0, annotated.width - 60).round();
      int ry = ((baselineY - 50)).clamp(0, annotated.height - 1).round();
      
      int radiusX = ((circle[0] - 40)).clamp(0, annotated.width - 80).round();
      int radiusY = ((circle[1] - 10)).clamp(0, annotated.height - 1).round();
      
      imglib.drawString(annotated, lText, font: imglib.arial14, x: lx, y: ly);
      imglib.drawString(annotated, rText, font: imglib.arial14, x: rx, y: ry);
      imglib.drawString(annotated, radiusText, font: imglib.arial14, x: radiusX, y: radiusY);

      Directory tmp = await getTemporaryDirectory();
      String outPath = '${tmp.path}/contact_angle_${DateTime.now().millisecondsSinceEpoch}.png';
      File outFile = File(outPath);
      await outFile.writeAsBytes(imglib.encodePng(annotated));

      String surfaceType = thetaFinal < 90 ? 'Hydrophilic' : thetaFinal < 150 ? 'Hydrophobic' : 'Superhydrophobic';

      String resultText = '''🎯 Contact Angle (avg): ${thetaFinal.toStringAsFixed(2)}° ± ${uncertainty.toStringAsFixed(2)}°\n\nPer-side angles:\n• Left (θL): ${thetaPolyLeft.toStringAsFixed(1)}°\n• Right (θR): ${thetaPolyRight.toStringAsFixed(1)}°\n\nCircle Fit:\n• Radius: ${circle[2].toStringAsFixed(1)}px\n• Circle angle: ${thetaCircle.toStringAsFixed(1)}°\n\nFits:\n• Poly avg: ${thetaPoly.toStringAsFixed(1)}°\n• Surface: $surfaceType\n\nQuality:\n• Contour pts: ${contour.length}\n• Baseline: Avg bottom 3px (corrected)\n• Tangents: At baseline contact points\n${inverted ? '• BG: Dark (corrected)' : '• BG: Light'}\n''';

      print('✅ Done. Angle ${thetaFinal.toStringAsFixed(2)}°, saved -> $outPath');

      return {
        'text': resultText,
        'annotated': outFile,
        'annotated_path': outPath,
        'angle_numeric': thetaFinal,
        'uncertainty_numeric': uncertainty,
        'theta_circle': thetaCircle,
        'theta_poly': thetaPoly,
        'theta_left': thetaPolyLeft,
        'theta_right': thetaPolyRight,
        'contour_count': contour.length,
        'baseline_y': baselineY,
        'filename': imageFile.path.split(Platform.pathSeparator).last,
        'surface_type': surfaceType,
        'circle_radius': circle[2],
        'left_contact_x': leftContact?.x ?? spanLeftX,
        'left_contact_y': baselineY,
        'right_contact_x': rightContact?.x ?? spanRightX,
        'right_contact_y': baselineY,
      };
    } catch (e, st) {
      print('❌ Processing failed: $e\n$st');
      return {
        'text': '❌ Processing failed: ${e.toString()}\n\nTry better contrast/cropped image.',
        'annotated': null
      };
    }
  }
}
