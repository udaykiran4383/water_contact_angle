import 'dart:typed_data';

import 'package:image/image.dart' as imglib;
import 'package:flutter_test/flutter_test.dart';
import 'package:water_contact_angle/image_processor.dart';
import 'package:water_contact_angle/processing/young_laplace.dart';

void main() {
  group('ImageProcessor.computePhysicalMetrics', () {
    test('uses explicit calibration and propagates Bo uncertainty', () {
      const calibration = ScaleCalibration(
        metersPerPixel: 4.0e-6,
        relativeUncertainty: 0.02,
      );

      final metrics = ImageProcessor.computePhysicalMetrics(
        radiusPixels: 100.0,
        calibration: calibration,
      );

      const radiusM = 100.0 * 4.0e-6;
      final expectedBo = YoungLaplaceSolver.bondNumber(radiusM);
      final expectedBoUnc = expectedBo * 2.0 * 0.02;

      expect(metrics['is_calibrated'], 1.0);
      expect(metrics['radius_mm'], closeTo(0.4, 1e-12));
      expect(metrics['pixel_size_um'], closeTo(4.0, 1e-12));
      expect(metrics['bond_number_physical'], closeTo(expectedBo, 1e-12));
      expect(
        metrics['bond_number_physical_uncertainty'],
        closeTo(expectedBoUnc, 1e-12),
      );
    });

    test('falls back to approximate scale when calibration is absent', () {
      final metrics = ImageProcessor.computePhysicalMetrics(
        radiusPixels: 50.0,
      );

      expect(metrics['is_calibrated'], 0.0);
      expect(metrics['pixel_size_um'], closeTo(10.0, 1e-12));
      expect(metrics['radius_mm'], closeTo(0.5, 1e-12));
      expect(metrics['bond_number_physical'], greaterThan(0.0));
      expect(metrics['bond_number_physical_uncertainty']!.isNaN, isTrue);
    });
  });

  group('ImageProcessor.detectAutoCalibration', () {
    test('detects scale from JPEG EXIF resolution', () {
      final image = imglib.Image(width: 32, height: 24);
      image.exif.imageIfd.xResolution = [300, 1];
      image.exif.imageIfd.yResolution = [300, 1];
      image.exif.imageIfd.resolutionUnit = 2; // inches

      final bytes = Uint8List.fromList(imglib.encodeJpg(image));
      final decoded = imglib.decodeImage(bytes)!;
      final calibration = ImageProcessor.detectAutoCalibration(decoded, bytes);

      expect(calibration, isNotNull);
      expect(calibration!.source, 'metadata_exif');
      expect(calibration.metersPerPixel, closeTo(0.0254 / 300.0, 1e-10));
    });

    test('detects scale from PNG pHYs metadata', () {
      final image = imglib.Image(width: 16, height: 16);
      final encoder = imglib.PngEncoder(
        pixelDimensions: imglib.PngPhysicalPixelDimensions.dpi(254),
      );
      final bytes = Uint8List.fromList(encoder.encode(image));
      final decoded = imglib.decodeImage(bytes)!;
      final calibration = ImageProcessor.detectAutoCalibration(decoded, bytes);

      expect(calibration, isNotNull);
      expect(calibration!.source, 'metadata_png_phys');
      expect(calibration.metersPerPixel, closeTo(1.0 / 10000.0, 5e-7));
    });
  });
}
