// Renders the launcher icon: a sessile drop (spherical cap, θ = 120°) on a
// substrate line with the goniometer tangent-and-arc mark and a faint
// reflection — i.e., exactly what the app measures. Supersampled 4×4 per
// pixel for crisp anti-aliased edges at every mipmap density.
//
// Usage: dart run tool/make_icon.dart
// Writes assets/app_icon.png (1024²) and all Android mipmaps.

import 'dart:io';
import 'dart:math' as math;

import 'package:image/image.dart' as img;

// Geometry in the unit square (y down).
const double baseY = 0.685;
const double capTheta = 120.0 * math.pi / 180.0;
const double capR = 0.315;
const double capCx = 0.455;

// θ>90° cap: circle centre sits below the apex, above the baseline.
final double capCy = baseY + capR * math.cos(capTheta); // cos120 < 0 → above

// Right contact point.
final double contactX = capCx + capR * math.sin(capTheta);
const double contactY = baseY;

// Tangent at the right contact, pointing away from the surface (over the
// drop — the classic θ>90° overhang).
final double tanDx = math.cos(math.pi - capTheta);
final double tanDy = -math.sin(math.pi - capTheta);

class Rgba {
  final double r, g, b, a;
  const Rgba(this.r, this.g, this.b, this.a);
}

Rgba over(Rgba top, Rgba bot) {
  final a = top.a + bot.a * (1 - top.a);
  if (a <= 1e-9) return const Rgba(0, 0, 0, 0);
  double c(double t, double u) => (t * top.a + u * bot.a * (1 - top.a)) / a;
  return Rgba(c(top.r, bot.r), c(top.g, bot.g), c(top.b, bot.b), a);
}

double segDist(double px, double py, double ax, double ay, double bx, double by) {
  final dx = bx - ax, dy = by - ay;
  final len2 = dx * dx + dy * dy;
  double t = len2 > 1e-12 ? ((px - ax) * dx + (py - ay) * dy) / len2 : 0.0;
  t = t.clamp(0.0, 1.0);
  final cx = ax + t * dx, cy = ay + t * dy;
  return math.sqrt((px - cx) * (px - cx) + (py - cy) * (py - cy));
}

/// Colour of one sample point in the unit square (premultiplied compositing
/// handled by [over]); alpha 0 outside the rounded-rect plate.
Rgba sample(double x, double y, {required bool roundMask}) {
  // Plate mask.
  const corner = 0.185;
  bool inPlate;
  if (roundMask) {
    final dx = x - 0.5, dy = y - 0.5;
    inPlate = dx * dx + dy * dy <= 0.25;
  } else {
    final qx = (x - 0.5).abs() - (0.5 - corner);
    final qy = (y - 0.5).abs() - (0.5 - corner);
    if (qx <= 0 || qy <= 0) {
      inPlate = x >= 0 && x <= 1 && y >= 0 && y <= 1;
    } else {
      inPlate = qx * qx + qy * qy <= corner * corner;
    }
  }
  if (!inPlate) return const Rgba(0, 0, 0, 0);

  // Background: deep navy, subtle vertical lift.
  final t = y.clamp(0.0, 1.0);
  var c = Rgba(
    (0x10 + (0x1A - 0x10) * (1 - t)) / 255.0,
    (0x1C + (0x2E - 0x1C) * (1 - t)) / 255.0,
    (0x2C + (0x46 - 0x2C) * (1 - t)) / 255.0,
    1.0,
  );

  // Faint reflection of the cap below the baseline (the app's
  // reflection-baseline capability, and it grounds the drop visually).
  if (y > baseY) {
    final my = 2 * baseY - y; // mirror above the line
    final dx = x - capCx, dy = my - capCy;
    if (dx * dx + dy * dy <= capR * capR && my < baseY) {
      final depth = (y - baseY) / (capR * 0.34);
      final a = (0.38 * (1 - depth)).clamp(0.0, 0.38);
      c = over(Rgba(0x35 / 255, 0xD6 / 255, 0xC2 / 255, a), c);
    }
  }

  // Substrate bar.
  if ((y - baseY).abs() <= 0.011 && x >= 0.10 && x <= 0.90) {
    c = over(const Rgba(0x2E / 255, 0xC4 / 255, 0xB6 / 255, 1.0), c);
  }

  // Drop: spherical cap above the baseline, vertical teal→cyan gradient with
  // a soft top-left highlight.
  {
    final dx = x - capCx, dy = y - capCy;
    if (dx * dx + dy * dy <= capR * capR && y < baseY) {
      final apexY = capCy - capR;
      final f = ((y - apexY) / (baseY - apexY)).clamp(0.0, 1.0);
      double r = (0x3D + (0x12 - 0x3D) * f) / 255.0;
      double g = (0xE8 + (0x9E - 0xE8) * f) / 255.0;
      double b = (0xD2 + (0x9B - 0xD2) * f) / 255.0;
      // Highlight.
      final hx = x - (capCx - capR * 0.38), hy = y - (capCy - capR * 0.62);
      final hd = math.sqrt(hx * hx + hy * hy) / (capR * 0.55);
      if (hd < 1.0) {
        final ha = 0.35 * (1 - hd) * (1 - hd);
        r = r + (1 - r) * ha;
        g = g + (1 - g) * ha;
        b = b + (1 - b) * ha;
      }
      c = over(Rgba(r, g, b, 1.0), c);
    }
  }

  // θ arc at the right contact point: from the substrate (pointing right,
  // outside the drop) sweeping up to the tangent direction.
  const strokeW = 0.0155;
  const arcR = 0.135;
  {
    final dx = x - contactX, dy = y - contactY;
    final d = math.sqrt(dx * dx + dy * dy);
    if ((d - arcR).abs() <= strokeW / 2) {
      // Angle measured with y up: 0 = +x (outside), θ = tangent over the drop.
      final ang = math.atan2(-dy, dx);
      if (ang >= -0.02 && ang <= math.pi - capTheta + 0.02) {
        c = over(const Rgba(0.94, 0.98, 0.98, 1.0), c);
      }
    }
  }

  // Tangent segment at the contact point.
  {
    final d = segDist(x, y, contactX - tanDx * 0.02, contactY - tanDy * 0.02,
        contactX + tanDx * 0.24, contactY + tanDy * 0.24);
    if (d <= strokeW / 2) {
      c = over(const Rgba(0.94, 0.98, 0.98, 1.0), c);
    }
  }

  return c;
}

img.Image render(int size, {bool roundMask = false}) {
  const ss = 4;
  final out = img.Image(width: size, height: size, numChannels: 4);
  final inv = 1.0 / (ss * ss);
  for (int py = 0; py < size; py++) {
    for (int px = 0; px < size; px++) {
      double r = 0, g = 0, b = 0, a = 0;
      for (int sy = 0; sy < ss; sy++) {
        for (int sx = 0; sx < ss; sx++) {
          final x = (px + (sx + 0.5) / ss) / size;
          final y = (py + (sy + 0.5) / ss) / size;
          final c = sample(x, y, roundMask: roundMask);
          r += c.r * c.a;
          g += c.g * c.a;
          b += c.b * c.a;
          a += c.a;
        }
      }
      a *= inv;
      if (a > 1e-9) {
        out.setPixelRgba(px, py, ((r * inv / a) * 255).round().clamp(0, 255),
            ((g * inv / a) * 255).round().clamp(0, 255),
            ((b * inv / a) * 255).round().clamp(0, 255),
            (a * 255).round().clamp(0, 255));
      } else {
        out.setPixelRgba(px, py, 0, 0, 0, 0);
      }
    }
  }
  return out;
}

void main() {
  const root = '/Users/uday/btp/water_contact_angle';
  final master = render(1024);
  File('$root/assets/app_icon.png').writeAsBytesSync(img.encodePng(master));
  stdout.writeln('master 1024 done');

  const densities = {
    'mdpi': 48,
    'hdpi': 72,
    'xhdpi': 96,
    'xxhdpi': 144,
    'xxxhdpi': 192,
  };
  for (final e in densities.entries) {
    final dir = '$root/android/app/src/main/res/mipmap-${e.key}';
    final sq = img.copyResize(master,
        width: e.value, height: e.value, interpolation: img.Interpolation.cubic);
    File('$dir/ic_launcher.png').writeAsBytesSync(img.encodePng(sq));
    final round = render(e.value, roundMask: true);
    File('$dir/ic_launcher_round.png').writeAsBytesSync(img.encodePng(round));
    stdout.writeln('${e.key} ${e.value}px done');
  }
}
