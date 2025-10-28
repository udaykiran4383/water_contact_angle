import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as imglib;
import 'package:path_provider/path_provider.dart';

import 'processing/angle_utils.dart';

class ImageProcessor {
  // helper to extract red channel robustly across `image` package versions
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

  /// Draw a tangent of length L centered at the contact point, with direction
  /// perpendicular to the radius from (cx, cy) to contact point. Uses image
  /// package drawLine.
  static List<math.Point<double>> _drawTangent(
      imglib.Image img,
      double cx,
      double cy,
      double r,
      math.Point<double> contact,
    List<int> rgb,
      {double length = 50.0, double offset = 2.0}) {
    final vx = contact.x - cx;
    final vy = contact.y - cy;
    // Tangent vector is perpendicular to radius
    double tx = -vy;
    double ty = vx;
    double len = math.sqrt(tx * tx + ty * ty);
    if (len < 1e-6) len = 1.0; // avoid div by zero
    double nx = tx / len;
    double ny = ty / len;

    // Choose outward direction (draw only one side), prefer upward (ny < 0)
    if (ny > 0) {
      nx = -nx;
      ny = -ny;
    }

    // Offset the start point slightly outward along the radius to avoid
    // overlapping the green boundary at the first few pixels.
    double rvLen = math.sqrt(vx * vx + vy * vy);
    double rnx = rvLen > 1e-6 ? (vx / rvLen) : 0.0;
    double rny = rvLen > 1e-6 ? (vy / rvLen) : 0.0;
    final start = math.Point(contact.x + rnx * offset, contact.y + rny * offset);

    final p2 = math.Point(start.x + nx * length, start.y + ny * length);
    _drawLineRgba(img, start.x.round(), start.y.round(), p2.x.round(), p2.y.round(), rgb[0], rgb[1], rgb[2], 255, thickness: 4);
    return [start, p2];
  }

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
        // simple thickness by drawing orthogonal neighbors
        if (thickness > 1) {
          int nx = -(y2 - y1).sign;
          int ny = (x2 - x1).sign;
          int half = (thickness - 1) ~/ 2;
          for (int t = 1; t <= half; t++) {
            int ox1 = x + nx * t;
            int oy1 = y + ny * t;
            int ox2 = x - nx * t;
            int oy2 = y - ny * t;
            if (ox1 >= 0 && ox1 < img.width && oy1 >= 0 && oy1 < img.height) img.setPixelRgba(ox1, oy1, r, g, b, a);
            if (ox2 >= 0 && ox2 < img.width && oy2 >= 0 && oy2 < img.height) img.setPixelRgba(ox2, oy2, r, g, b, a);
          }
        }
      }
      if (x == x2 && y == y2) break;
      int e2 = 2 * err;
      if (e2 > -dy) {
        err -= dy;
        x += sx;
      }
      if (e2 < dx) {
        err += dx;
        y += sy;
      }
    }
  }

  static Future<Map<String, dynamic>> processImage(File imageFile) async {
    try {
      print('🔍 Starting image processing: ${imageFile.path}');

      
      final Uint8List bytes = await imageFile.readAsBytes();
      imglib.Image? src = imglib.decodeImage(bytes);
      if (src == null) {
        return {'text': '❌ Failed to decode image. Try a different file.', 'annotated': null};
      }

      print('📐 Image size: ${src.width}x${src.height}');

      // Convert to grayscale
      imglib.Image gray = imglib.grayscale(src);

      // Compute mean intensity (use red channel of grayscale)
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
        // invert image for silhouette cases
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

      // Blur to reduce noise - gaussianBlur requires named parameter `radius`
      imglib.Image blurred = imglib.gaussianBlur(gray, radius: 3);

      // Edge detection via Sobel magnitude (simple and robust without opencv binding)
      final int width = blurred.width;
      final int height = blurred.height;
      final List<int> edgeMask = List.filled(width * height, 0);

      // Sobel kernels
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
          edgeMask[y * width + x] = mag > 80 ? 1 : 0; // threshold; tune as needed
        }
      }

      // Morphological closing (dilate then erode)
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

      // Connected components -> choose largest as droplet
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
        return {
          'text':
              '❌ No droplet detected. Try higher contrast / clearer droplet silhouette.',
          'annotated': null
        };
      }

      // Segment droplet using Otsu threshold and choose the best round component
      // Build histogram of grayscale (red channel)
      List<int> hist = List.filled(256, 0);
      for (int y = 0; y < height; y++) {
        for (int x = 0; x < width; x++) {
          final px = gray.getPixel(x, y);
          final r = _getRed(px);
          hist[r]++;
        }
      }
      int totalPx = width * height;
      int otsuT = 0;
      {
        int sum = 0;
        for (int i = 0; i < 256; i++) sum += i * hist[i];
        int sumB = 0, wB = 0, wF = 0;
        double maxVar = -1;
        for (int t = 0; t < 256; t++) {
          wB += hist[t];
          if (wB == 0) continue;
          wF = totalPx - wB;
          if (wF == 0) break;
          sumB += t * hist[t];
          double mB = sumB / wB;
          double mF = (sum - sumB) / wF;
          double varBetween = wB * wF * (mB - mF) * (mB - mF);
          if (varBetween > maxVar) {
            maxVar = varBetween;
            otsuT = t;
          }
        }
      }

      List<int> maskDark = List.filled(width * height, 0);
      List<int> maskLight = List.filled(width * height, 0);
      for (int y = 0; y < height; y++) {
        for (int x = 0; x < width; x++) {
          int idx = y * width + x;
          final r = _getRed(gray.getPixel(x, y));
          if (r < otsuT) maskDark[idx] = 1; // dark = droplet candidate
          if (r > otsuT) maskLight[idx] = 1; // light = droplet candidate (if inverted)
        }
      }

      Map<String, dynamic> pickBestComponent(List<int> mask) {
        List<int> labelsI = List.filled(width * height, 0);
        int label = 1;
        double bestScore = -1;
        int bestLabel = 0;
        List<int> bestBBox = [0,0,0,0];
        for (int y = 0; y < height; y++) {
          for (int x = 0; x < width; x++) {
            int idx = y * width + x;
            if (mask[idx] == 1 && labelsI[idx] == 0) {
              int minX = x, maxX = x, minY = y, maxY = y;
              int area = 0;
              bool touchesBorder = false;
              List<int> st = [idx];
              labelsI[idx] = label;
              while (st.isNotEmpty) {
                int c = st.removeLast();
                int cy = c ~/ width, cx = c % width;
                area++;
                if (cx < minX) minX = cx; if (cx > maxX) maxX = cx;
                if (cy < minY) minY = cy; if (cy > maxY) maxY = cy;
                if (cx == 0 || cx == width-1 || cy == 0 || cy == height-1) touchesBorder = true;
                for (int ny = cy - 1; ny <= cy + 1; ny++) {
                  for (int nx = cx - 1; nx <= cx + 1; nx++) {
                    if (nx>=0 && nx<width && ny>=0 && ny<height) {
                      int nidx = ny*width + nx;
                      if (mask[nidx] == 1 && labelsI[nidx] == 0) {
                        labelsI[nidx] = label;
                        st.add(nidx);
                      }
                    }
                  }
                }
              }
              int bw = (maxX - minX + 1);
              int bh = (maxY - minY + 1);
              if (bw < 8 || bh < 8) { label++; continue; }
              double ar = (bw < bh ? bw / bh : bh / bw); // 0..1 (1=circle)
              double fill = area / (bw * bh);
              // Score: area + roundness + fill, penalize border-touch
              double score = area.toDouble() + 2000.0 * ar + 2000.0 * (1.0 - (fill - 0.78).abs());
              if (touchesBorder) score *= 0.6;
              if (score > bestScore) {
                bestScore = score; bestLabel = label; bestBBox = [minX,minY,maxX,maxY];
              }
              label++;
            }
          }
        }
        // Build final mask for bestLabel
        List<int> out = List.filled(width * height, 0);
        if (bestLabel != 0) {
          for (int i = 0; i < width * height; i++) if (labelsI[i] == bestLabel) out[i] = 1;
        }
        return { 'mask': out, 'score': bestScore };
      }

      final pickedDark = pickBestComponent(maskDark);
      final pickedLight = pickBestComponent(maskLight);
      final List<int> dropletMaskDark = (pickedDark['mask'] as List).cast<int>();
      final List<int> dropletMaskLight = (pickedLight['mask'] as List).cast<int>();
      final double scoreDark = (pickedDark['score'] as double);
      final double scoreLight = (pickedLight['score'] as double);
      // Choose the one with the higher score
      List<int> dropletMask = scoreDark >= scoreLight ? dropletMaskDark : dropletMaskLight;

      // Extract contour (boundary pixels) from the chosen droplet mask — single layer
      List<math.Point> contour = [];
      for (int y = 1; y < height - 1; y++) {
        for (int x = 1; x < width - 1; x++) {
          int idx = y * width + x;
          if (dropletMask[idx] == 1) {
            bool boundary = false;
            for (int ky = -1; ky <= 1 && !boundary; ky++) {
              for (int kx = -1; kx <= 1; kx++) {
                if (dropletMask[(y + ky) * width + (x + kx)] == 0) {
                  boundary = true;
                  break;
                }
              }
            }
            if (boundary) contour.add(math.Point(x.toDouble(), y.toDouble()));
          }
        }
      }

      if (contour.length < 8) {
        return {'text': '❌ Droplet contour too small (${contour.length} points).', 'annotated': null};
      }

      // Baseline: compute robust baseline by finding lowest droplet y per column
      // within the horizontal span of the droplet, then take the mode (most
      // frequent) y as the substrate baseline. This reduces sensitivity to
      // single noisy contour pixels and yields a straight baseline across the
      // contact region.
      int minContourX = contour.map((p) => p.x.toInt()).reduce(math.min);
      int maxContourX = contour.map((p) => p.x.toInt()).reduce(math.max);

      // lowest y per column (-1 if none)
      List<int> lowestYPerCol = List.filled(width, -1);
      for (int x = minContourX; x <= maxContourX; x++) {
        for (int y = height - 1; y >= 0; y--) {
          if (dropletMask[y * width + x] == 1) {
            lowestYPerCol[x] = y;
            break;
          }
        }
      }

      // Collect valid lowest y's
      List<int> lowestVals = [];
      for (int x = minContourX; x <= maxContourX; x++) {
        int yv = lowestYPerCol[x];
        if (yv >= 0) lowestVals.add(yv);
      }

      double baselineY;
      if (lowestVals.isNotEmpty) {
        lowestVals.sort();
        // Use a high percentile (e.g., 90th) to stay near the true substrate
  int start = (lowestVals.length * 0.98).floor();
        if (start >= lowestVals.length) start = lowestVals.length - 1;
        List<int> topBand = lowestVals.sublist(start);
        // median of the top band for robustness
        int mid = topBand[topBand.length ~/ 2];
        baselineY = mid.toDouble();
        // refine within a small window around this baseline to maximize
        // consensus across columns
        int bestY = baselineY.toInt();
        int bestCount = -1;
        for (int cand = (baselineY - 3).round(); cand <= (baselineY + 3).round(); cand++) {
          int c = 0;
          for (int x = minContourX; x <= maxContourX; x++) {
            int yv = lowestYPerCol[x];
            if (yv >= 0 && (yv - cand).abs() <= 1) c++;
          }
          if (c > bestCount || (c == bestCount && cand > bestY)) {
            bestCount = c;
            bestY = cand;
          }
        }
        baselineY = bestY.toDouble();
      } else {
        // fallback: absolute lowest contour point
        baselineY = contour.map((p) => p.y.toDouble()).reduce(math.max);
      }

      // Contact points and region for polynomial fit
      double leftX = double.infinity, rightX = -double.infinity;
      List<math.Point> leftPoints = [], rightPoints = [];
      double midX = width / 2.0;

      // determine left/right contact columns where lowestY ~= baselineY
      for (int x = minContourX; x <= maxContourX; x++) {
        int yv = lowestYPerCol[x];
        if (yv >= 0 && (yv - baselineY).abs() <= 2.0) {
          if (x < leftX) leftX = x.toDouble();
          if (x > rightX) rightX = x.toDouble();
        }
      }

      // if direct equality didn't find contacts, relax criterion to within 3 px
      if (leftX == double.infinity || rightX < 0) {
        for (int x = minContourX; x <= maxContourX; x++) {
          int yv = lowestYPerCol[x];
          if (yv >= 0 && (yv - baselineY).abs() <= 3.0) {
            if (x < leftX) leftX = x.toDouble();
            if (x > rightX) rightX = x.toDouble();
          }
        }
      }

      // collect local points above baseline for polynomial fit (left/right)
      for (var p in contour) {
        final px = p.x.toDouble();
        final py = p.y.toDouble();
        if (py <= baselineY + 10 && py > baselineY - 80) {
          if (px < midX) leftPoints.add(math.Point(px, py));
          else rightPoints.add(math.Point(px, py));
        }
      }

      if (leftX == double.infinity || rightX <= leftX + 6) {
        return {
          'text':
              '❌ Could not locate contact points reliably. Ensure the droplet touches the surface and the line is visible.',
          'annotated': null
        };
      }

      print('📍 contacts: left=${leftX.toStringAsFixed(0)} right=${rightX.toStringAsFixed(0)} baselineY=${baselineY.toStringAsFixed(0)}');

      // Prepare xs, ys (points above baseline) for circle fit
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

      // Fit circle and compute angles
      var circle = AngleUtils.circleFit(xs, ys);
      double thetaCircle = AngleUtils.calculateCircleAngle(circle, baselineY);

      // Compute ideal circle-baseline intersections for precise contact points
      double cxC = circle[0], cyC = circle[1], rC = circle[2];
      double hC = baselineY - cyC;
      double dxC = 0.0;
      if (rC.isFinite) {
        double disc = rC * rC - hC * hC;
        dxC = disc > 0 ? math.sqrt(disc) : 0.0;
      }
      double circLeftX = cxC - dxC;
      double circRightX = cxC + dxC;

      // Validate circle-baseline intersections; if invalid, fall back to
      // detected contact extremes from the baseline scan.
      double spanLeftX = circLeftX;
      double spanRightX = circRightX;
      bool invalidIntersections = !spanLeftX.isFinite || !spanRightX.isFinite ||
          (spanRightX - spanLeftX).abs() < 5 ||
          spanLeftX < (minContourX - 5) || spanRightX > (maxContourX + 5);
      if (invalidIntersections) {
        spanLeftX = leftX;
        spanRightX = rightX;
      }

  // Use math.Point lists directly with AngleUtils.polynomialAngle
  // Anchor contact X at circle-baseline intersection for precision.
  double thetaPolyLeft = AngleUtils.polynomialAngle(leftPoints, spanLeftX, baselineY, true);
  double thetaPolyRight = AngleUtils.polynomialAngle(rightPoints, spanRightX, baselineY, false);
      double thetaPoly = (thetaPolyLeft + thetaPolyRight) / 2.0;
      double thetaFinal = (thetaCircle + thetaPoly) / 2.0;

      // bootstrap uncertainty
      List<double> bs = [];
      final rnd = math.Random();
      for (int t = 0; t < 12; t++) {
        List<int> idxs = List.generate(xs.length, (_) => rnd.nextInt(xs.length));
        List<double> sX = idxs.map((i) => xs[i]).toList();
        List<double> sY = idxs.map((i) => ys[i]).toList();
        try {
          var c2 = AngleUtils.circleFit(sX, sY);
          double th = AngleUtils.calculateCircleAngle(c2, baselineY);
          bs.add(th);
        } catch (_) {}
      }
      double uncertainty = 0.0;
      if (bs.length >= 2) {
        double meanBs = bs.reduce((a, b) => a + b) / bs.length;
        double varianceVal = bs.map((t) => math.pow(t - meanBs, 2)).reduce((a, b) => a + b) / (bs.length - 1);
        double sd = math.sqrt(varianceVal);
        uncertainty = 1.96 * sd / math.sqrt(bs.length);
      }

      // Annotate image (draw contour, white baseline, blue arc, tangents & labels)
      imglib.Image annotated = src.clone();

      // droplet boundary (green): draw all contour pixels strictly above the
      // baseline to avoid painting the flat substrate, without restricting by
      // horizontal span so both left and right sides are fully visible.
      for (var p in contour) {
        int px = p.x.toInt();
        int py = p.y.toInt();
        if (py <= baselineY - 1 &&
            px >= 0 && px < annotated.width && py >= 0 && py < annotated.height) {
          annotated.setPixelRgba(px, py, 0, 255, 0, 255);
        }
      }

      // baseline (white)
      int by = baselineY.toInt();
      for (int x = 0; x < annotated.width; x++) {
        int yy = by;
        if (yy >= 0 && yy < annotated.height) annotated.setPixelRgba(x, yy, 255, 255, 255, 255);
      }

      // draw fitted circle (blue arc only over droplet span)
      try {
        double cx_ = circle[0], cy_ = circle[1], r = circle[2];
        if (r.isFinite && r > 1 && cx_.isFinite && cy_.isFinite) {
          int steps = (2 * math.pi * r).ceil().clamp(16, 2000);
          for (int i = 0; i < steps; i++) {
            double ang = (i / steps) * 2.0 * math.pi;
            int px = (cx_ + r * math.cos(ang)).round();
            int py = (cy_ + r * math.sin(ang)).round();
            // Only draw circle where it overlaps the droplet span given by ideal
            // circle-baseline intersections and above baseline.
            if (px >= (spanLeftX - 2).toInt() && px <= (spanRightX + 2).toInt() &&
                py <= baselineY &&
                px >= 0 && px < annotated.width && py >= 0 && py < annotated.height) {
              annotated.setPixelRgba(px, py, 0, 0, 255, 255);
            }
          }
        }
      } catch (_) {}

  // Tangents at contact points using circle geometry (perpendicular to radius)
  final leftContact = math.Point<double>(spanLeftX, baselineY);
  final rightContact = math.Point<double>(spanRightX, baselineY);
  _drawTangent(annotated, circle[0], circle[1], circle[2], leftContact, [0, 230, 0], length: 50.0, offset: 2.0);
  _drawTangent(annotated, circle[0], circle[1], circle[2], rightContact, [255, 0, 0], length: 50.0, offset: 2.0);

  // Compute per-side contact angles using local polynomial fit (more robust
  // for interior-angle convention). These angles are measured inside the
  // droplet by AngleUtils.
  double thetaLeft = AngleUtils.polynomialAngle(leftPoints, leftX, baselineY, true);
  double thetaRight = AngleUtils.polynomialAngle(rightPoints, rightX, baselineY, false);

  // Override final angle as average of per-side angles
  thetaFinal = (thetaLeft + thetaRight) / 2.0;

  // Angle labels near contact points
      final lText = 'θL=${thetaLeft.toStringAsFixed(1)}°';
      final rText = 'θR=${thetaRight.toStringAsFixed(1)}°';
      int lx = (leftContact.x + 6).clamp(0, annotated.width - 1).round();
      int rx = (rightContact.x - 60).clamp(0, annotated.width - 60).round();
      int ly = (leftContact.y - 35).clamp(0, annotated.height - 1).round();
      int ry = (rightContact.y - 35).clamp(0, annotated.height - 1).round();
  imglib.drawString(annotated, lText, font: imglib.arial14, x: lx, y: ly);
  imglib.drawString(annotated, rText, font: imglib.arial14, x: rx, y: ry);

      // Save annotated image
      Directory tmp = await getTemporaryDirectory();
      String outPath = '${tmp.path}/contact_angle_${DateTime.now().millisecondsSinceEpoch}.png';
      File outFile = File(outPath);
      await outFile.writeAsBytes(imglib.encodePng(annotated));

      String surfaceType;
      if (thetaFinal < 90) surfaceType = 'Hydrophilic';
      else if (thetaFinal < 150) surfaceType = 'Hydrophobic';
      else surfaceType = 'Superhydrophobic';

  String resultText = '''🎯 Contact Angle (avg): ${thetaFinal.toStringAsFixed(2)}° ± ${uncertainty.toStringAsFixed(2)}°\n\nPer-side angles (tangent vs baseline):\n• Left (θL): ${thetaLeft.toStringAsFixed(1)}°\n• Right (θR): ${thetaRight.toStringAsFixed(1)}°\n\nFits (info):\n• Circle fit (global): ${thetaCircle.toStringAsFixed(1)}°\n• Polynomial (local avg): ${thetaPoly.toStringAsFixed(1)}°\n• Surface: $surfaceType\n\nQuality:\n• Contour points: ${contour.length}\n• Baseline method: mode-of-lowest-y (robust)\n${inverted ? '• Background: Dark (auto-corrected)' : '• Background: Light'}\n''';

      print('✅ Done. Angle ${thetaFinal.toStringAsFixed(2)}°, saved annotated -> $outPath');

      // Return extended map with numeric fields for UI & CSV export
      return {
        'text': resultText,
        'annotated': outFile,
        'annotated_path': outPath,
        'angle_numeric': thetaFinal,
        'uncertainty_numeric': uncertainty,
        'theta_circle': thetaCircle,
  'theta_poly': thetaPoly,
  'theta_left': thetaLeft,
  'theta_right': thetaRight,
        'contour_count': contour.length,
        'baseline_y': baselineY,
        'filename': imageFile.path.split(Platform.pathSeparator).last,
        'surface_type': surfaceType,
      };
    } catch (e, st) {
      print('❌ Processing failed: $e\n$st');
      return {
        'text':
            '❌ Processing failed: ${e.toString()}\n\nTry: better contrast, cropped droplet, or attach sample image.',
        'annotated': null
      };
    }
  }
}
