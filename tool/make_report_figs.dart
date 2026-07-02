// Renders figure assets for the BTP report: a clean synthetic cap and the
// contact-shadow-wedge synthetic (both with exactly known contact angle).
// Usage: dart run tool/make_report_figs.dart

import 'dart:io';
import 'dart:math' as math;

import 'package:image/image.dart' as img;

const int w = 640, h = 480;
const double cx = 320, baseY = 360;
const int ss = 4, fg = 40, bg = 235;

img.Image cap(double thetaDeg, {bool shadow = false, double r = 130}) {
  final theta = thetaDeg * math.pi / 180.0;
  final cyImg = baseY - (-r * math.cos(theta));
  final a = r * math.sin(theta);
  final out = img.Image(width: w, height: h);
  final inv = 1.0 / (ss * ss);
  for (int yy = 0; yy < h; yy++) {
    for (int xx = 0; xx < w; xx++) {
      double acc = 0;
      for (int sy = 0; sy < ss; sy++) {
        final py = yy + (sy + 0.5) / ss;
        for (int sx = 0; sx < ss; sx++) {
          final px = xx + (sx + 0.5) / ss;
          final dx = px - cx, dy = py - cyImg;
          final inDrop = dx * dx + dy * dy <= r * r && py < baseY;
          if (inDrop) {
            acc += fg;
          } else if (py >= baseY) {
            if (shadow) {
              final u = (px - cx).abs() / (1.25 * a);
              final depth = (py - baseY) / 70.0;
              final s = 0.62 *
                  math.exp(-u * u * u * u) *
                  math.exp(-depth.clamp(0.0, 10.0));
              acc += 150 * (1.0 - s);
            } else {
              acc += fg;
            }
          } else {
            acc += bg;
          }
        }
      }
      final g = (acc * inv).round().clamp(0, 255);
      out.setPixelRgb(xx, yy, g, g, g);
    }
  }
  return out;
}

void main() {
  const dir = '/Users/uday/btp/water_contact_angle/report/assets';
  File('$dir/synthetic_clean_125.png')
      .writeAsBytesSync(img.encodePng(cap(125)));
  File('$dir/synthetic_shadow_150.png')
      .writeAsBytesSync(img.encodePng(cap(150, shadow: true, r: 110)));
  stdout.writeln('done');
}
