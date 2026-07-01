// lib/processing/sub_pixel_edge.dart
import 'dart:math' as math;

/// Sub-pixel accurate edge detection for improved contact angle precision.
/// Achieves ~0.1 pixel accuracy through gradient interpolation.
class SubPixelEdgeDetector {
  /// Detect edges with sub-pixel accuracy using Gaussian-weighted gradient.
  ///
  /// Returns list of (x, y) points with sub-pixel coordinates.
  static List<math.Point<double>> detectEdges(
    List<int> grayscale,
    int width,
    int height, {
    double lowThreshold = 30.0,
    double highThreshold = 80.0,
    double sigma = 1.8,
  }) {
    // Step 1: Gaussian blur (already done externally, but ensure smooth gradients)
    var blurred = _gaussianBlur(grayscale, width, height, sigma);

    // Step 2: Compute gradients with Sobel
    var gradientX = List<double>.filled(width * height, 0.0);
    var gradientY = List<double>.filled(width * height, 0.0);
    var gradientMag = List<double>.filled(width * height, 0.0);
    var gradientDir = List<double>.filled(width * height, 0.0);

    for (int y = 1; y < height - 1; y++) {
      for (int x = 1; x < width - 1; x++) {
        // Sobel kernels
        double gx = -blurred[(y - 1) * width + (x - 1)] -
            2 * blurred[y * width + (x - 1)] -
            blurred[(y + 1) * width + (x - 1)] +
            blurred[(y - 1) * width + (x + 1)] +
            2 * blurred[y * width + (x + 1)] +
            blurred[(y + 1) * width + (x + 1)];
        double gy = -blurred[(y - 1) * width + (x - 1)] -
            2 * blurred[(y - 1) * width + x] -
            blurred[(y - 1) * width + (x + 1)] +
            blurred[(y + 1) * width + (x - 1)] +
            2 * blurred[(y + 1) * width + x] +
            blurred[(y + 1) * width + (x + 1)];

        int idx = y * width + x;
        gradientX[idx] = gx / 8.0; // normalize
        gradientY[idx] = gy / 8.0;
        gradientMag[idx] = math.sqrt(gx * gx + gy * gy) / 8.0;
        gradientDir[idx] = math.atan2(gy, gx);
      }
    }

    // Step 3: Non-maximum suppression with sub-pixel refinement
    final thresholds = _adaptiveGradientThresholds(
      gradientMag,
      lowThreshold,
      highThreshold,
    );
    final double lowThresh = thresholds['low']!;
    final double highThresh = thresholds['high']!;
    final candidate = List<bool>.filled(width * height, false);
    final strong = List<bool>.filled(width * height, false);
    final subX = List<double>.filled(width * height, 0.0);
    final subY = List<double>.filled(width * height, 0.0);

    for (int y = 2; y < height - 2; y++) {
      for (int x = 2; x < width - 2; x++) {
        int idx = y * width + x;
        double mag = gradientMag[idx];

        if (mag < lowThresh) continue;

        // Get gradient direction (quantized to 4 directions)
        double dir = gradientDir[idx];
        int dx1, dy1, dx2, dy2;

        // Round direction to nearest 45°
        if ((dir >= -math.pi / 8 && dir < math.pi / 8) ||
            (dir >= 7 * math.pi / 8 || dir < -7 * math.pi / 8)) {
          dx1 = 1;
          dy1 = 0;
          dx2 = -1;
          dy2 = 0;
        } else if (dir >= math.pi / 8 && dir < 3 * math.pi / 8 ||
            dir >= -7 * math.pi / 8 && dir < -5 * math.pi / 8) {
          dx1 = 1;
          dy1 = 1;
          dx2 = -1;
          dy2 = -1;
        } else if (dir >= 3 * math.pi / 8 && dir < 5 * math.pi / 8 ||
            dir >= -5 * math.pi / 8 && dir < -3 * math.pi / 8) {
          dx1 = 0;
          dy1 = 1;
          dx2 = 0;
          dy2 = -1;
        } else {
          dx1 = -1;
          dy1 = 1;
          dx2 = 1;
          dy2 = -1;
        }

        // Non-maximum suppression
        double mag1 = gradientMag[(y + dy1) * width + (x + dx1)];
        double mag2 = gradientMag[(y + dy2) * width + (x + dx2)];

        if (mag >= mag1 && mag >= mag2) {
          // This is a local maximum - refine to sub-pixel
          double refinedX = x.toDouble();
          double refinedY = y.toDouble();

          // Parabolic interpolation for sub-pixel position
          if (mag1 > 0 || mag2 > 0) {
            double denom = 2.0 * (mag1 + mag2 - 2.0 * mag);
            if (denom.abs() > 1e-8) {
              // Parabolic peak offset δ = ½·(mag2 − mag1)/(mag1 − 2·mag + mag2).
              // mag1 sits at +(dx1,dy1) and mag2 at −(dx1,dy1); the previous
              // (mag1 − mag2)/denom had the sign flipped, nudging the edge the
              // wrong way (up to ½ px in the wrong direction) since NMS forces
              // denom ≤ 0. This corrects the sub-pixel refinement direction.
              double offset = (mag2 - mag1) / denom;
              offset = offset.clamp(-0.5, 0.5);
              refinedX += offset * dx1;
              refinedY += offset * dy1;
            }
          }

          candidate[idx] = true;
          strong[idx] = mag >= highThresh;
          subX[idx] = refinedX;
          subY[idx] = refinedY;
        }
      }
    }

    final queue = <int>[];
    final visited = List<bool>.filled(width * height, false);
    for (int idx = 0; idx < strong.length; idx++) {
      if (strong[idx]) {
        visited[idx] = true;
        queue.add(idx);
      }
    }

    if (queue.isEmpty) {
      double maxCandidate = 0.0;
      for (int idx = 0; idx < candidate.length; idx++) {
        if (candidate[idx] && gradientMag[idx] > maxCandidate) {
          maxCandidate = gradientMag[idx];
        }
      }
      if (maxCandidate > 0.0) {
        final rescueThreshold = maxCandidate * 0.92;
        for (int idx = 0; idx < candidate.length; idx++) {
          if (candidate[idx] && gradientMag[idx] >= rescueThreshold) {
            visited[idx] = true;
            queue.add(idx);
          }
        }
      }
    }

    final edges = <math.Point<double>>[];
    int head = 0;
    while (head < queue.length) {
      final idx = queue[head++];
      edges.add(math.Point(subX[idx], subY[idx]));

      final x = idx % width;
      final y = idx ~/ width;
      for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
          if (dx == 0 && dy == 0) continue;
          final nx = x + dx;
          final ny = y + dy;
          if (nx < 0 || nx >= width || ny < 0 || ny >= height) continue;
          final nIdx = ny * width + nx;
          if (!candidate[nIdx] || visited[nIdx]) continue;
          visited[nIdx] = true;
          queue.add(nIdx);
        }
      }
    }

    return edges;
  }

  /// Detect edges with auto-tuned blur and thresholds from image contrast.
  static List<math.Point<double>> detectEdgesAdaptive(
    List<int> grayscale,
    int width,
    int height, {
    bool sensitive = false,
  }) {
    if (grayscale.isEmpty || width < 3 || height < 3) {
      return <math.Point<double>>[];
    }

    double mean = 0.0;
    for (final v in grayscale) {
      mean += v;
    }
    mean /= grayscale.length;

    double variance = 0.0;
    for (final v in grayscale) {
      final d = v - mean;
      variance += d * d;
    }
    variance /= grayscale.length;
    final stdDev = math.sqrt(variance);

    final sigma =
        sensitive ? 1.0 : (stdDev < 18.0 ? 1.7 : (stdDev < 32.0 ? 1.35 : 1.10));
    final low = sensitive ? 12.0 : 18.0;
    final high = sensitive ? 36.0 : 58.0;
    return detectEdges(
      grayscale,
      width,
      height,
      lowThreshold: low,
      highThreshold: high,
      sigma: sigma,
    );
  }

  static Map<String, double> _adaptiveGradientThresholds(
    List<double> gradientMag,
    double baseLow,
    double baseHigh,
  ) {
    final nonZero =
        gradientMag.where((mag) => mag.isFinite && mag > 0.0).toList()..sort();
    if (nonZero.length < 24) {
      return {'low': baseLow, 'high': baseHigh};
    }

    final q70 = _percentile(nonZero, 0.70);
    final q85 = _percentile(nonZero, 0.85);
    final q96 = _percentile(nonZero, 0.96);

    double finalHigh = math.max(4.0, math.max(baseHigh * 0.85, q85));
    finalHigh = math.max(finalHigh, math.min(q96, baseHigh * 1.05));

    double finalLow = math.max(
      2.0,
      math.max(baseLow * 0.80, math.min(q70, finalHigh * 0.55)),
    );

    if (finalLow >= finalHigh) {
      finalLow = math.max(2.0, finalHigh - 1.0);
      if (finalLow >= finalHigh) {
        finalHigh = finalLow + 1.0;
      }
    }

    return {'low': finalLow, 'high': finalHigh};
  }

  static double _percentile(List<double> values, double p) {
    if (values.isEmpty) return 0.0;
    final clamped = p.clamp(0.0, 1.0);
    final idx = clamped * (values.length - 1);
    final lo = idx.floor();
    final hi = idx.ceil();
    if (lo == hi) return values[lo];
    final t = idx - lo;
    return values[lo] * (1.0 - t) + values[hi] * t;
  }

  /// Apply Gaussian blur
  static List<double> _gaussianBlur(
      List<int> input, int width, int height, double sigma) {
    // Create Gaussian kernel
    int kSize = (sigma * 4).ceil();
    if (kSize % 2 == 0) kSize++;
    kSize = kSize.clamp(3, 11);
    int half = kSize ~/ 2;

    var kernel = List<double>.filled(kSize * kSize, 0.0);
    double sum = 0.0;
    for (int ky = -half; ky <= half; ky++) {
      for (int kx = -half; kx <= half; kx++) {
        double val = math.exp(-(kx * kx + ky * ky) / (2 * sigma * sigma));
        kernel[(ky + half) * kSize + (kx + half)] = val;
        sum += val;
      }
    }
    // Normalize
    for (int i = 0; i < kernel.length; i++) {
      kernel[i] /= sum;
    }

    // Apply convolution
    var output = List<double>.filled(width * height, 0.0);
    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        double val = 0.0;
        for (int ky = -half; ky <= half; ky++) {
          for (int kx = -half; kx <= half; kx++) {
            final sx = (x + kx).clamp(0, width - 1).toInt();
            final sy = (y + ky).clamp(0, height - 1).toInt();
            val += input[sy * width + sx] *
                kernel[(ky + half) * kSize + (kx + half)];
          }
        }
        output[y * width + x] = val;
      }
    }

    return output;
  }

  /// Refine existing integer edges to sub-pixel accuracy
  static List<math.Point<double>> refineEdges(List<math.Point<int>> coarseEdges,
      List<int> grayscale, int width, int height) {
    var refined = <math.Point<double>>[];

    for (var edge in coarseEdges) {
      int x = edge.x;
      int y = edge.y;

      if (x < 2 || x >= width - 2 || y < 2 || y >= height - 2) {
        refined.add(math.Point(x.toDouble(), y.toDouble()));
        continue;
      }

      // Compute local gradient
      int idx = y * width + x;
      double gx = (grayscale[idx + 1] - grayscale[idx - 1]) / 2.0;
      double gy = (grayscale[idx + width] - grayscale[idx - width]) / 2.0;
      double gMag = math.sqrt(gx * gx + gy * gy);

      if (gMag < 1.0) {
        refined.add(math.Point(x.toDouble(), y.toDouble()));
        continue;
      }

      // Normal direction
      double nx = gx / gMag;
      double ny = gy / gMag;

      // Sample along normal direction
      double vm1 = _bilinearSample(grayscale, width, height, x - nx, y - ny);
      double v0 = grayscale[idx].toDouble();
      double vp1 = _bilinearSample(grayscale, width, height, x + nx, y + ny);

      // Parabolic fit for sub-pixel offset
      double denom = 2.0 * (vm1 + vp1 - 2.0 * v0);
      double offset = 0.0;
      if (denom.abs() > 1e-8) {
        offset = (vm1 - vp1) / denom;
        offset = offset.clamp(-0.5, 0.5);
      }

      refined.add(math.Point(x + offset * nx, y + offset * ny));
    }

    return refined;
  }

  /// Bilinear interpolation sampling
  static double _bilinearSample(
      List<int> data, int width, int height, double x, double y) {
    int x0 = x.floor().clamp(0, width - 2);
    int y0 = y.floor().clamp(0, height - 2);
    double fx = x - x0;
    double fy = y - y0;

    double v00 = data[y0 * width + x0].toDouble();
    double v10 = data[y0 * width + x0 + 1].toDouble();
    double v01 = data[(y0 + 1) * width + x0].toDouble();
    double v11 = data[(y0 + 1) * width + x0 + 1].toDouble();

    return v00 * (1 - fx) * (1 - fy) +
        v10 * fx * (1 - fy) +
        v01 * (1 - fx) * fy +
        v11 * fx * fy;
  }
}
