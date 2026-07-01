import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:water_contact_angle/processing/silhouette_extractor.dart';
import 'package:water_contact_angle/processing/young_laplace.dart';

List<int> _gray(File f) {
  final decoded = img.decodeImage(f.readAsBytesSync())!;
  final g = img.grayscale(decoded);
  final w = g.width, h = g.height;
  final gray = List<int>.filled(w * h, 0);
  for (int y = 0; y < h; y++) {
    for (int x = 0; x < w; x++) {
      gray[y * w + x] = g.getPixel(x, y).r.toInt();
    }
  }
  double corner = 0;
  int cn = 0;
  final ch = (h * 0.12).round().clamp(8, 60);
  for (int yy = 0; yy < ch; yy++) {
    for (int x = 0; x < w; x += 5) {
      corner += gray[yy * w + x];
      cn++;
    }
  }
  corner /= cn;
  if (corner < 100) {
    for (int i = 0; i < gray.length; i++) gray[i] = 255 - gray[i];
  }
  return gray;
}

double _adsa(List<int> gray, int w, int h, DropRoi? roi) {
  final s = SilhouetteExtractor.extract(gray, w, h, roi: roi);
  if (s == null) return double.nan;
  final slope = s.baselineResult['slope'] as double;
  final intercept = s.baselineResult['intercept'] as double;
  final cx = (s.leftContactX + s.rightContactX) / 2.0;
  final r = YoungLaplaceSolver.fitContour(s.contour, slope * cx + intercept,
      dropRadiusPixels: (s.rightContactX - s.leftContactX) / 2.0);
  return r['contact_angle']!;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const root = '/Users/uday/btp/water_contact_angle';

  test('ROI does not degrade a clean image', () {
    final f = File('$root/PFOTES/C_3%_2 coat_6a.JPG'); // GT 133.68
    final decoded = img.decodeImage(f.readAsBytesSync())!;
    final w = decoded.width, h = decoded.height;
    final gray = _gray(f);
    final full = _adsa(gray, w, h, null);
    final fullAsRoi = _adsa(gray, w, h, DropRoi(0, 0, w, h));
    final roiAng = _adsa(gray, w, h, DropRoi(200, 60, 480, h));
    // ignore: avoid_print
    print('clean: full=$full fullAsRoi=$fullAsRoi roi=$roiAng w=$w h=$h');
    // Passing the whole frame as an ROI must be identical to no ROI.
    expect((fullAsRoi - full).abs(), lessThan(0.01));
    // A generous ROI around the drop must still recover essentially the same
    // angle (it only changes the local Otsu threshold slightly).
    expect(roiAng.isFinite, isTrue);
    expect((roiAng - full).abs(), lessThan(4.0));
  });

  test('coat_5 full-frame ADSA already matches LBADSA, ROI stays consistent', () {
    // GT 132.44 (LBADSA, Screenshot (589).png). The earlier 112.44 was a
    // transcription typo that made this drop look like a 22-deg outlier and
    // motivated an ROI "contamination fix" that was never actually needed.
    const gt = 132.44;
    final f = File('$root/PFOTES/C_1.5%_2 coat_5.JPG');
    final decoded = img.decodeImage(f.readAsBytesSync())!;
    final w = decoded.width, h = decoded.height;
    final gray = _gray(f);
    final full = _adsa(gray, w, h, null);
    // ignore: avoid_print
    print('coat_5: full=${full.toStringAsFixed(2)} GT=$gt');
    // The automatic full-frame fit agrees with LBADSA to within its own
    // reproducibility — no manual ROI required.
    expect(full.isFinite, isTrue);
    expect((full - gt).abs(), lessThan(5.0),
        reason: 'full-frame ADSA regressed vs LBADSA on coat_5');
    // A generous box ROI that fully contains the drop must not move the answer
    // materially (tight boxes that clip the apex legitimately change it, which
    // is why the ROI UI lets the user frame the whole drop).
    final roiAng = _adsa(gray, w, h, DropRoi(150, 60, 520, h));
    // ignore: avoid_print
    print('coat_5 generous-roi=${roiAng.toStringAsFixed(2)}');
    expect(roiAng.isFinite, isTrue);
    expect((roiAng - full).abs(), lessThan(4.0),
        reason: 'a generous ROI shifted the coat_5 angle unexpectedly');
  });
}
