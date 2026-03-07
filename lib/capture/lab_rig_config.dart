// lib/capture/lab_rig_config.dart
import 'dart:io';
import 'dart:developer' as developer;

import 'package:image/image.dart' as imglib;

/// Configuration for LAB_RIG acquisition mode.
///
/// When MODE = "LAB_RIG", the system:
/// - locks focus/exposure when possible
/// - enables burst capture (N frames)
/// - computes blur score and rejects blurry frames
/// - enforces fixed ROI
/// - recomputes baseline each frame
/// - logs every capture
class LabRigConfig {
  /// Number of frames per burst capture.
  final int burstCount;

  /// Laplacian-variance threshold below which a frame is considered blurry.
  final double blurThreshold;

  /// Whether to attempt locking focus/exposure.
  final bool lockExposure;

  /// Optional fixed region of interest [left, top, width, height].
  /// Null means no ROI enforcement (full frame).
  final List<int>? fixedROI;

  /// Whether to recompute baseline on each frame.
  final bool recomputeBaseline;

  /// Enable verbose capture logging.
  final bool logCaptures;

  const LabRigConfig({
    this.burstCount = 5,
    this.blurThreshold = 100.0,
    this.lockExposure = true,
    this.fixedROI,
    this.recomputeBaseline = true,
    this.logCaptures = true,
  });

  /// Default production configuration.
  static const LabRigConfig production = LabRigConfig(
    burstCount: 5,
    blurThreshold: 100.0,
    lockExposure: true,
    recomputeBaseline: true,
    logCaptures: true,
  );
}

/// Processor for LAB_RIG mode burst captures.
class LabRigProcessor {
  static void _log(String msg) {
    developer.log(msg, name: 'LabRig');
  }

  /// Extract luminance from a pixel using the image v4 API.
  /// Handles both RGBA and other pixel formats gracefully.
  static int _getLuminance(imglib.Pixel px) {
    try {
      return px.luminance.toInt().clamp(0, 255);
    } catch (_) {
      // Fallback: read first channel
      try {
        return px.r.toInt().clamp(0, 255);
      } catch (_) {
        return 128;
      }
    }
  }

  /// Compute blur score using Laplacian variance.
  ///
  /// Higher values = sharper image.
  /// A typical threshold for "acceptable" is ~100.0.
  static double computeBlurScore(imglib.Image image) {
    final int w = image.width;
    final int h = image.height;
    if (w < 5 || h < 5) return 0.0;

    // Convert to grayscale values
    final gray = List<double>.filled(w * h, 0.0);
    for (int y = 0; y < h; y++) {
      for (int x = 0; x < w; x++) {
        gray[y * w + x] = _getLuminance(image.getPixel(x, y)).toDouble();
      }
    }

    // Laplacian kernel: [0, 1, 0; 1, -4, 1; 0, 1, 0]
    double sumLaplacian = 0.0;
    double sumLaplacianSq = 0.0;
    int count = 0;

    for (int y = 1; y < h - 1; y++) {
      for (int x = 1; x < w - 1; x++) {
        final lap = gray[(y - 1) * w + x] +
            gray[(y + 1) * w + x] +
            gray[y * w + (x - 1)] +
            gray[y * w + (x + 1)] -
            4.0 * gray[y * w + x];
        sumLaplacian += lap;
        sumLaplacianSq += lap * lap;
        count++;
      }
    }

    if (count == 0) return 0.0;
    final mean = sumLaplacian / count;
    final variance = (sumLaplacianSq / count) - (mean * mean);
    return variance.abs();
  }

  /// Apply fixed ROI crop to an image.
  static imglib.Image applyROI(imglib.Image image, List<int> roi) {
    if (roi.length < 4) {
      _log('Invalid ROI (need [left, top, width, height]), skipping');
      return image;
    }
    final left = roi[0].clamp(0, image.width - 1);
    final top = roi[1].clamp(0, image.height - 1);
    final w = roi[2].clamp(1, image.width - left);
    final h = roi[3].clamp(1, image.height - top);
    return imglib.copyCrop(image, x: left, y: top, width: w, height: h);
  }

  /// Select the best frame from a burst based on blur score.
  ///
  /// Returns map with:
  /// - 'best_file': the File with highest blur score
  /// - 'best_index': index in the input list
  /// - 'blur_scores': list of all blur scores
  /// - 'rejected_count': number of frames below threshold
  /// - 'inter_frame_variance': variance of blur scores (stability metric)
  static Future<Map<String, dynamic>> selectBestFrame(
    List<File> frames,
    LabRigConfig config,
  ) async {
    if (frames.isEmpty) {
      throw ArgumentError('No frames provided');
    }

    final blurScores = <double>[];

    for (final frame in frames) {
      final bytes = await frame.readAsBytes();
      var image = imglib.decodeImage(bytes);
      if (image == null) {
        blurScores.add(0.0);
        continue;
      }

      // Apply ROI if configured
      if (config.fixedROI != null) {
        image = applyROI(image, config.fixedROI!);
      }

      final score = computeBlurScore(image);
      blurScores.add(score);

      if (config.logCaptures) {
        _log('Frame ${blurScores.length}: blur=${score.toStringAsFixed(1)}'
            '${score < config.blurThreshold ? ' [REJECTED]' : ' [OK]'}');
      }
    }

    if (blurScores.isEmpty) {
      throw StateError('No frames could be decoded');
    }

    // Find best frame
    int bestIndex = 0;
    double bestScore = blurScores[0];
    for (int i = 1; i < blurScores.length; i++) {
      if (blurScores[i] > bestScore) {
        bestScore = blurScores[i];
        bestIndex = i;
      }
    }

    // Count rejected frames
    final rejectedCount =
        blurScores.where((s) => s < config.blurThreshold).length;

    // Inter-frame variance (stability metric)
    double interFrameVariance = 0.0;
    if (blurScores.length >= 2) {
      final mean = blurScores.reduce((a, b) => a + b) / blurScores.length;
      double sumSq = 0.0;
      for (final s in blurScores) {
        sumSq += (s - mean) * (s - mean);
      }
      interFrameVariance = sumSq / (blurScores.length - 1);
    }

    _log('Best frame: #$bestIndex (blur=${bestScore.toStringAsFixed(1)}), '
        'rejected: $rejectedCount/${frames.length}');

    return {
      'best_file': frames[bestIndex],
      'best_index': bestIndex,
      'blur_scores': blurScores,
      'rejected_count': rejectedCount,
      'inter_frame_variance': interFrameVariance,
    };
  }

  /// Reject blurry frames from a list, returning only acceptable ones.
  static Future<List<File>> rejectBlurryFrames(
    List<File> frames,
    double threshold,
  ) async {
    final accepted = <File>[];
    for (final frame in frames) {
      final bytes = await frame.readAsBytes();
      final image = imglib.decodeImage(bytes);
      if (image == null) continue;

      final score = computeBlurScore(image);
      if (score >= threshold) {
        accepted.add(frame);
      }
    }
    _log('Accepted ${accepted.length}/${frames.length} frames '
        '(threshold=$threshold)');
    return accepted;
  }
}
