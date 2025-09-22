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

      // Build droplet mask
      List<int> dropletMask = List.filled(width * height, 0);
      for (int i = 0; i < width * height; i++) {
        if (labels[i] == largestLabel) dropletMask[i] = 1;
      }

      // Extract contour (boundary pixels)
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

      // Baseline: lowest y in contour (max y) - ensure double
      double baselineY = contour.map((p) => p.y.toDouble()).reduce(math.max);

      // Contact points near baseline and region for polynomial fit
      double leftX = double.infinity, rightX = -double.infinity;
      List<math.Point> leftPoints = [], rightPoints = [];
      double midX = width / 2.0;
      for (var p in contour) {
        final px = p.x.toDouble();
        final py = p.y.toDouble();
        if ((py - baselineY).abs() < 10.0) {
          if (px < leftX) leftX = px;
          if (px > rightX) rightX = px;
        }
        if (py <= baselineY + 10 && py > baselineY - 80) {
          if (px < midX + 50) leftPoints.add(math.Point(px, py));
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

      // Use math.Point lists directly with AngleUtils.polynomialAngle
      double thetaPolyLeft = AngleUtils.polynomialAngle(leftPoints, leftX, baselineY, true);
      double thetaPolyRight = AngleUtils.polynomialAngle(rightPoints, rightX, baselineY, false);
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

      // Annotate image (draw contour, baseline, contacts, circle)
      imglib.Image annotated = src.clone();

      // draw droplet boundary (green)
      for (var p in contour) {
        int px = p.x.toInt();
        int py = p.y.toInt();
        if (px >= 0 && px < annotated.width && py >= 0 && py < annotated.height) {
          annotated.setPixelRgba(px, py, 0, 255, 0, 255);
        }
      }

      // baseline (red horizontal)
      int by = baselineY.toInt();
      for (int x = 0; x < annotated.width; x++) {
        int yy = by;
        if (yy >= 0 && yy < annotated.height) annotated.setPixelRgba(x, yy, 255, 0, 0, 255);
      }

      // contact points (magenta)
      annotated.setPixelRgba(leftX.toInt(), by, 255, 0, 255, 255);
      annotated.setPixelRgba(rightX.toInt(), by, 255, 0, 255, 255);

      // draw fitted circle (circumference points)
      try {
        double cx_ = circle[0], cy_ = circle[1], r = circle[2];
        if (r.isFinite && r > 1 && cx_.isFinite && cy_.isFinite) {
          int steps = (2 * math.pi * r).ceil().clamp(16, 2000);
          for (int i = 0; i < steps; i++) {
            double ang = (i / steps) * 2.0 * math.pi;
            int px = (cx_ + r * math.cos(ang)).round();
            int py = (cy_ + r * math.sin(ang)).round();
            if (px >= 0 && px < annotated.width && py >= 0 && py < annotated.height) {
              annotated.setPixelRgba(px, py, 0, 255, 255, 255);
            }
          }
        }
      } catch (_) {}

      // Save annotated image
      Directory tmp = await getTemporaryDirectory();
      String outPath = '${tmp.path}/contact_angle_${DateTime.now().millisecondsSinceEpoch}.png';
      File outFile = File(outPath);
      await outFile.writeAsBytes(imglib.encodePng(annotated));

      String surfaceType;
      if (thetaFinal < 90) surfaceType = 'Hydrophilic';
      else if (thetaFinal < 150) surfaceType = 'Hydrophobic';
      else surfaceType = 'Superhydrophobic';

      String resultText = '''🎯 Contact Angle: ${thetaFinal.toStringAsFixed(2)}° ± ${uncertainty.toStringAsFixed(2)}°\n\nMethods:\n• Circle fit: ${thetaCircle.toStringAsFixed(1)}°\n• Polynomial: ${thetaPoly.toStringAsFixed(1)}°\n• Surface: $surfaceType\n\nQuality:\n• Contour points: ${contour.length}\n• Baseline method: bottom-of-contour\n${inverted ? '• Background: Dark (auto-corrected)' : '• Background: Light'}\n''';

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
