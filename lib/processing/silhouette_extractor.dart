// lib/processing/silhouette_extractor.dart
import 'dart:math' as math;

/// Optional region-of-interest (in original image pixels) constraining the drop
/// search to a user-drawn box — the standard ADSA workflow, used to exclude
/// background contamination or neighbouring features next to the drop.
class DropRoi {
  final int left, top, right, bottom;
  const DropRoi(this.left, this.top, this.right, this.bottom);
  bool contains(int x, int y) =>
      x >= left && x < right && y >= top && y < bottom;
}

/// Robust silhouette extraction for back-lit sessile-drop images.
///
/// Lab capture for contact-angle work is a back-lit drop: a very dark drop
/// against a bright, diffuse background, resting on a darker substrate band or
/// stage block. Gradient/Canny edge detection struggles here because the dark
/// drop merges into the dark substrate (no edge between them) and an internal
/// bright refraction window creates spurious interior edges.
///
/// This extractor instead works from the strong, reliable contrast that *does*
/// exist — bright background vs. dark object:
///   1. Global Otsu threshold splits bright background from dark foreground.
///   2. The substrate baseline is the dominant "top-of-object" level across
///      columns (robust to the drop and to a partial-width stage block), fit as
///      a (possibly tilted) line.
///   3. The drop silhouette is traced by scanning each row above the baseline
///      for the outer-most object pixels — which are the true drop edges and are
///      immune to the interior refraction window.
///
/// Returns null when the scene is not a confident back-lit silhouette, letting
/// the caller fall back to the legacy edge-based pipeline.
class SilhouetteExtractor {
  /// Convention: [gray] is already polarity-normalised so the **background is
  /// bright (high)** and the **object is dark (low)** — the same convention the
  /// caller establishes before edge detection.
  static SilhouetteResult? extract(
    List<int> gray,
    int width,
    int height, {
    bool inverted = false,
    DropRoi? roi,
  }) {
    if (width < 40 || height < 40 || gray.length < width * height) return null;

    // Effective scan window: the ROI if supplied, else the whole frame. All
    // statistics, the baseline and the drop search are confined to it.
    final rx0 = roi == null ? 0 : roi.left.clamp(0, width);
    final ry0 = roi == null ? 0 : roi.top.clamp(0, height);
    final rx1 = roi == null ? width : roi.right.clamp(0, width);
    final ry1 = roi == null ? height : roi.bottom.clamp(0, height);
    final effW = rx1 - rx0;
    final effH = ry1 - ry0;
    if (effW < 30 || effH < 30) return null;
    bool inRoi(int x, int y) => roi == null || roi.contains(x, y);

    // --- 1. Otsu threshold (bright background vs dark object) -------------
    final hist = List<int>.filled(256, 0);
    for (int y = ry0; y < ry1; y++) {
      for (int x = rx0; x < rx1; x++) {
        final v = gray[y * width + x];
        if (v >= 0 && v < 256) hist[v]++;
      }
    }
    final total = effW * effH;
    final otsu = _otsu(hist, total);

    // Background brightness (top band median) and object darkness, to gauge
    // contrast and reject low-contrast / non-silhouette scenes.
    final bg =
        _bandMedian(gray, width, ry0, ry0 + math.max(1, (effH * 0.12).round()),
            x0: rx0, x1: rx1);
    int darkSum = 0, darkN = 0;
    for (int y = ry0; y < ry1; y++) {
      for (int x = rx0; x < rx1; x++) {
        final v = gray[y * width + x];
        if (v < otsu) {
          darkSum += v;
          darkN++;
        }
      }
    }
    if (darkN == 0) return null;
    final darkMean = darkSum / darkN;
    final contrast = (bg - darkMean); // bright minus dark
    final objectFraction = darkN / total;
    // Background must be clearly brighter than the object, and the object must
    // occupy a sensible fraction (not the whole window, not a speck).
    if (contrast < 35 || objectFraction < 0.005 || objectFraction > 0.85) {
      return null;
    }

    bool isObj(int x, int y) => inRoi(x, y) && gray[y * width + x] < otsu;

    // --- 2. Top-of-object per column -------------------------------------
    // First row (scanning down) that begins a run of >=3 object pixels, but
    // only AFTER the column has shown bright background above it. This rejects
    // a dark band along the top of the frame (vignette / fixture shadow) that
    // is not surrounded by background and would otherwise be mistaken for the
    // drop apex.
    final topObj = List<double>.filled(width, double.nan);
    for (int x = rx0; x < rx1; x++) {
      int bright = 0;
      for (int y = ry0; y < ry1 - 2; y++) {
        if (!isObj(x, y)) {
          bright++;
          continue;
        }
        if (bright >= 3 && isObj(x, y + 1) && isObj(x, y + 2)) {
          topObj[x] = y.toDouble();
          break;
        }
      }
    }

    final validTops = <double>[];
    for (int x = rx0; x < rx1; x++) {
      if (topObj[x].isFinite) validTops.add(topObj[x]);
    }

    double slope = 0.0;
    double intercept = double.nan;
    double tol = 10.0;
    double spread = 4.0;
    int baselineInliers = 0;
    double reflectionScore = 0.0;
    bool haveBaseline = false;

    // --- 2a. Specular-stage baseline: drop/reflection mirror symmetry ----
    // A mirror stage (silicon, glass, polished metal) has no dark substrate
    // band, so the per-column "tops" of 2b would latch onto the drop's own
    // upper edge and place a false baseline through the drop middle. The drop
    // and its reflection instead form a dark blob symmetric about the surface
    // plane, with a narrow "waist" at the contact line (for the θ>90° drops this
    // instrument targets). We therefore test for that symmetry FIRST: the check
    // is strict (needs two lobes + a waist), so it returns null on a matte dark
    // stage (full-width dark below the drop breaks the symmetry) and on a lone
    // drop (single lobe) — leaving those to the matte path untouched.
    {
      final sp = _specularBaseline(
          gray, width, height, rx0, ry0, rx1, ry1, otsu, bg);
      if (sp != null) {
        slope = 0.0;
        intercept = sp[0];
        reflectionScore = sp[1];
        tol = 12.0;
        // Confidence proxy: a strong, well-formed symmetry stands in for the
        // per-column substrate inliers the matte path would have counted.
        baselineInliers = (effW * (0.10 + 0.25 * reflectionScore)).round();
        haveBaseline = true;
      }
    }

    // --- 2b. Matte-stage baseline: cluster of per-column "tops" ----------
    // A dark substrate band gives many columns whose first-dark row sits at the
    // surface level; the drop apex sits higher, so a high percentile lands on
    // the substrate.
    if (!haveBaseline && validTops.length >= effW * 0.15) {
      final substrateLevel = _percentile(validTops, 0.70);
      final near =
          validTops.where((v) => (v - substrateLevel).abs() <= 20.0).toList();
      spread = near.length > 3 ? _mad(near, substrateLevel) * 1.4826 : 4.0;
      tol = math.max(6.0, math.min(40.0, spread * 2.5 + 4.0));

      final bx = <double>[], by = <double>[];
      for (int x = rx0; x < rx1; x++) {
        if (topObj[x].isFinite && (topObj[x] - substrateLevel).abs() <= tol) {
          bx.add(x.toDouble());
          by.add(topObj[x]);
        }
      }
      if (bx.length >= math.max(15, effW * 0.08)) {
        var line = _lineFit(bx, by);
        for (int pass = 0; pass < 2; pass++) {
          final ix = <double>[], iy = <double>[];
          for (int i = 0; i < bx.length; i++) {
            final pred = line[0] * bx[i] + line[1];
            if ((by[i] - pred).abs() <= math.max(2.5, tol * 0.6)) {
              ix.add(bx[i]);
              iy.add(by[i]);
            }
          }
          if (ix.length >= 10) line = _lineFit(ix, iy);
        }
        slope = line[0];
        intercept = line[1];
        if (slope.abs() > 0.45) {
          slope = 0.0;
          intercept = substrateLevel;
        }
        baselineInliers = bx.length;
        haveBaseline = true;
      }
    }

    if (!haveBaseline || !intercept.isFinite) return null;
    double baseAt(double x) => slope * x + intercept;

    // --- 3. Connected-component drop selection (strictly ABOVE baseline) -
    // Flood-filling object pixels confined to above the baseline cleanly
    // separates the drop from the substrate band it visually merges with at
    // the contact line, and isolates it from floating frame-edge dark bands.
    bool inDrop(int x, int y) =>
        inRoi(x, y) &&
        x >= 0 &&
        x < width &&
        y >= 0 &&
        y < height &&
        gray[y * width + x] < otsu &&
        y < baseAt(x.toDouble()) - 1.0;

    final labels = List<int>.filled(width * height, 0);
    final stack = <int>[];
    int nextLabel = 0;
    int bestLabel = -1;
    double bestScore = -1;
    int bxMin = 0, bxMax = 0, byMin = 0;
    for (int sy = ry0; sy < ry1; sy++) {
      for (int sx = rx0; sx < rx1; sx++) {
        final sidx = sy * width + sx;
        if (labels[sidx] != 0 || !inDrop(sx, sy)) continue;
        nextLabel++;
        int area = 0, minx = sx, maxx = sx, miny = sy, maxy = sy, support = 0;
        stack
          ..clear()
          ..add(sidx);
        labels[sidx] = nextLabel;
        while (stack.isNotEmpty) {
          final idx = stack.removeLast();
          final cx = idx % width;
          final cy = idx ~/ width;
          area++;
          if (cx < minx) minx = cx;
          if (cx > maxx) maxx = cx;
          if (cy < miny) miny = cy;
          if (cy > maxy) maxy = cy;
          if (cy >= baseAt(cx.toDouble()) - 6.0) support++;
          const dxs = [1, -1, 0, 0];
          const dys = [0, 0, 1, -1];
          for (int k = 0; k < 4; k++) {
            final nx = cx + dxs[k];
            final ny = cy + dys[k];
            if (nx < 0 || nx >= width || ny < 0 || ny >= height) continue;
            final nidx = ny * width + nx;
            if (labels[nidx] == 0 && inDrop(nx, ny)) {
              labels[nidx] = nextLabel;
              stack.add(nidx);
            }
          }
        }
        final compW = (maxx - minx).toDouble();
        final compH = (maxy - miny).toDouble();
        if (area < 30 || compW < 10 || compH < 8) continue;
        final cxComp = (minx + maxx) / 2.0;
        final winCx = (rx0 + rx1) / 2.0;
        final central =
            1.0 - ((cxComp - winCx).abs() / (effW / 2.0)).clamp(0.0, 1.0);
        double score = area.toDouble() + 6.0 * support + 800.0 * central;
        // A dark band along the window top (vignette/fixture shadow) is WIDE and
        // FLAT; penalise only that, not a tall drop whose dosing needle happens
        // to reach the top edge (needle-in-drop is a valid, common capture).
        if (miny <= ry0 + 2 && compW > 1.2 * compH) score -= 1e7;
        if (compW > effW * 0.8) score -= 1e7; // full-width band, not a drop
        if (compH < 12) score -= 1e6;
        if (score > bestScore) {
          bestScore = score;
          bestLabel = nextLabel;
          bxMin = minx;
          bxMax = maxx;
          byMin = miny;
        }
      }
    }
    if (bestLabel < 0) return null;
    final xd0 = bxMin;
    final xd1 = bxMax;
    final dropWidth = (xd1 - xd0).toDouble();
    double apexY = byMin.toDouble();

    // Refine the baseline from substrate columns immediately ADJACENT to the
    // drop. The contact line sits on the local substrate, which on an uneven
    // stage or a soft-edged band can differ from the global median; using the
    // neighbouring substrate gives a more accurate contact level (and thus a
    // more accurate contact angle, to which near-circular drops are sensitive).
    {
      final wWin = (2.0 * dropWidth).clamp(30.0, width.toDouble());
      final lx = <double>[], ly = <double>[];
      for (int x = 0; x < width; x++) {
        if (!topObj[x].isFinite) continue;
        final nearDrop =
            (x >= xd0 - wWin && x < xd0) || (x > xd1 && x <= xd1 + wWin);
        if (!nearDrop) continue;
        if ((topObj[x] - baseAt(x.toDouble())).abs() <=
            math.max(2.5, tol * 0.6)) {
          lx.add(x.toDouble());
          ly.add(topObj[x]);
        }
      }
      if (lx.length >= 10) {
        final lf = _lineFit(lx, ly);
        if (lf[0].abs() <= 0.45) {
          slope = lf[0];
          intercept = lf[1];
        }
      }
    }

    final dropHeight = baseAt((xd0 + xd1) / 2.0) - apexY;
    if (dropHeight < 8 || dropWidth < 10) return null;

    // --- 4. Row-scan the outer silhouette of the drop component ----------
    final contour = <math.Point<double>>[];
    final xLo = math.max(0, xd0 - 2);
    final xHi = math.min(width - 1, xd1 + 2);
    final leftEdge = <math.Point<double>>[];
    final rightEdge = <math.Point<double>>[];
    final yTop = math.max(0, apexY.floor());
    final baseCentre = baseAt((xd0 + xd1) / 2.0);
    // Sub-pixel edge level: the 50%-coverage intensity between the bright
    // background (`bg`) and the dark object (`darkMean`). For an anti-aliased
    // silhouette the true drop boundary sits exactly at this half level, so
    // refining each row's outer object column to where the intensity crosses
    // `t50` recovers the edge to a fraction of a pixel — the integer column
    // index alone caps the contour (and thus the ADSA fit) at ±0.5 px. We use
    // the 50%-crossing rather than the Otsu level (which is biased inward for a
    // dark object on a bright, majority background). See sub-pixel edge audit.
    final t50 = (bg + darkMean) / 2.0;
    for (int y = yTop; y < height; y++) {
      if (y > baseCentre - 1) break;
      int minx = -1, maxx = -1;
      for (int x = xLo; x <= xHi; x++) {
        if (labels[y * width + x] == bestLabel) {
          if (minx < 0) minx = x;
          maxx = x;
        }
      }
      if (minx < 0 || maxx <= minx) continue;
      final yd = y.toDouble();
      final lx = _subPixelEdgeX(gray, width, y, minx, t50, isLeft: true);
      final rx = _subPixelEdgeX(gray, width, y, maxx, t50, isLeft: false);
      leftEdge.add(math.Point(lx, yd));
      rightEdge.add(math.Point(rx, yd));
    }
    if (leftEdge.length < 6) return null;

    // Trim a dispensing needle-in-drop. A dosing needle enters the drop apex as
    // a narrow, roughly-constant-width dark column; the connected component then
    // includes it, so the traced apex is the needle top and the fits see a
    // spurious spike. Detect a sustained narrow run at the top (median width of
    // the upper rows << the drop's maximum width — a real drop apex is never
    // that narrow relative to its widest point) and drop those rows down to the
    // "shoulder" where the true drop widens. No-op for needle-free drops.
    if (leftEdge.length >= 20) {
      final widths = List<double>.generate(
          leftEdge.length, (i) => rightEdge[i].x - leftEdge[i].x);
      final maxW = widths.reduce(math.max);
      final nTop = math.max(4, (widths.length * 0.15).round());
      final topSorted = widths.sublist(0, nTop)..sort();
      final medTop = topSorted[topSorted.length ~/ 2];
      if (maxW > 1e-6 && medTop < 0.28 * maxW) {
        int apexIdx = 0;
        final shoulder = math.max(1.7 * medTop, 0.30 * maxW);
        for (int i = 0; i < widths.length; i++) {
          if (widths[i] > shoulder) {
            apexIdx = i;
            break;
          }
        }
        // Require the narrow column to persist (a real apex widens within a few
        // rows) and to leave enough drop below to fit.
        if (apexIdx >= 6 && leftEdge.length - apexIdx >= 10) {
          leftEdge.removeRange(0, apexIdx);
          rightEdge.removeRange(0, apexIdx);
          apexY = leftEdge.first.y;
        }
      }
    }

    contour
      ..addAll(leftEdge)
      ..addAll(rightEdge);

    // Contacts = silhouette edges at the lowest scanned row.
    final leftContactX = leftEdge.last.x;
    final rightContactX = rightEdge.last.x;

    // --- 5. Confidence ---------------------------------------------------
    final inlierFraction = baselineInliers / effW;
    final contrastScore = ((contrast - 35) / 90).clamp(0.0, 1.0);
    final sizeScore = (dropWidth / (effW * 0.12)).clamp(0.0, 1.0);
    final coverage = (leftEdge.length / math.max(1.0, dropHeight)).clamp(0.0, 1.0);
    final confidence =
        (0.35 * contrastScore + 0.30 * inlierFraction.clamp(0.0, 1.0) +
                0.20 * sizeScore + 0.15 * coverage)
            .clamp(0.0, 1.0);

    final angleRad = math.atan(slope);
    final baselineResult = <String, dynamic>{
      'slope': slope,
      'intercept': intercept,
      'angle': angleRad * 180.0 / math.pi,
      'angle_rad': angleRad,
      'rms': spread,
      'span_fraction': ((xHi - xLo) / effW).clamp(0.0, 1.0),
      'inlier_fraction': inlierFraction.clamp(0.0, 1.0),
      'tilt_penalty': (slope.abs() / 0.45).clamp(0.0, 1.0),
      'confidence': (0.45 + 0.55 * inlierFraction).clamp(0.0, 1.0),
      'reflection_score': reflectionScore,
      'source': 'silhouette',
    };

    return SilhouetteResult(
      contour: contour,
      baselineResult: baselineResult,
      leftContactX: leftContactX,
      rightContactX: rightContactX,
      confidence: confidence,
      otsuThreshold: otsu.toDouble(),
      contrast: contrast,
      dropWidth: dropWidth,
      dropHeight: dropHeight,
    );
  }

  // --- helpers ----------------------------------------------------------

  /// Locate the baseline on a SPECULAR stage (no dark substrate band) as the
  /// axis of mirror symmetry of the drop+reflection silhouette.
  ///
  /// Returns `[baselineY, reflectionScore(0..1)]`, or null when the scene is not
  /// a confident drop-plus-reflection. Method:
  ///   1. `rowDark[y]` = number of dark (object) pixels in each row — the drop
  ///      and its reflection are dark; the reflected back-light is bright.
  ///   2. isolate the tallest contiguous dark blob (drop + reflection);
  ///   3. find the row `y0` minimising the mirror mismatch
  ///      Σ_d (rowDark[y0−d] − rowDark[y0+d])² — the symmetry axis;
  ///   4. require a "waist": rowDark[y0] must be a clear local minimum flanked
  ///      by wider lobes above (drop equator) and below (reflection equator).
  ///      This confirms a θ>90° drop with a reflection and rejects a lone drop
  ///      (single lobe) or arbitrary dark regions;
  ///   5. refine `y0` to sub-pixel by parabolic interpolation of the cost.
  static List<double>? _specularBaseline(List<int> gray, int width, int height,
      int rx0, int ry0, int rx1, int ry1, int otsu, double bg) {
    // Isolate ONLY the truly-dark drop/reflection, not the (mid-bright)
    // reflected back-light which a global Otsu would sweep in as "object". Use
    // a threshold a third of the way from the darkest level to the background.
    double fg = 255.0;
    for (int y = ry0; y < ry1; y += 2) {
      final base = y * width;
      for (int x = rx0; x < rx1; x += 2) {
        final v = gray[base + x].toDouble();
        if (v < fg) fg = v;
      }
    }
    final thr = math.min(otsu.toDouble(), fg + 0.35 * (bg - fg));

    final rowDark = List<double>.filled(height, 0.0);
    final minCount = math.max(6, ((rx1 - rx0) * 0.02).round());
    for (int y = ry0; y < ry1; y++) {
      int c = 0;
      final base = y * width;
      for (int x = rx0; x < rx1; x++) {
        if (gray[base + x] < thr) c++;
      }
      rowDark[y] = c.toDouble();
    }

    // Tallest run of "dark enough" rows = the drop+reflection blob. Tolerate a
    // few bright rows (the thin meniscus/contact line separating drop from its
    // reflection) so the run isn't split at the baseline itself.
    const maxGap = 4;
    int yTop = -1, yBot = -1, bestLen = 0, curStart = -1, curEnd = -1, gap = 0;
    for (int y = ry0; y < ry1; y++) {
      if (rowDark[y] >= minCount) {
        if (curStart < 0) curStart = y;
        curEnd = y;
        gap = 0;
        if (curEnd - curStart + 1 > bestLen) {
          bestLen = curEnd - curStart + 1;
          yTop = curStart;
          yBot = curEnd;
        }
      } else if (curStart >= 0) {
        if (++gap > maxGap) {
          curStart = -1;
          gap = 0;
        }
      }
    }
    if (yTop < 0 || bestLen < 24) return null;

    final lo = yTop + (bestLen * 0.20).round();
    final hi = yBot - (bestLen * 0.20).round();
    if (hi <= lo) return null;
    final maxD = (bestLen * 0.42).round();

    double cost(double y0) {
      double s = 0.0;
      int cnt = 0;
      for (int d = 1; d <= maxD; d++) {
        final ya = y0 - d, yb = y0 + d;
        if (ya < ry0 || yb >= ry1 - 1) break;
        final wa = _interpRow(rowDark, ya);
        final wb = _interpRow(rowDark, yb);
        final e = wa - wb;
        s += e * e;
        cnt++;
      }
      return cnt >= 8 ? s / cnt : double.infinity;
    }

    double bestY = (yTop + yBot) / 2.0, bestCost = double.infinity;
    for (int y0 = lo; y0 <= hi; y0++) {
      final c = cost(y0.toDouble());
      if (c < bestCost) {
        bestCost = c;
        bestY = y0.toDouble();
      }
    }
    if (!bestCost.isFinite) return null;

    // Waist test: the symmetry axis must be a narrow neck between two lobes.
    double maxAbove = 0.0, maxBelow = 0.0;
    for (int y = yTop; y < bestY; y++) {
      if (rowDark[y] > maxAbove) maxAbove = rowDark[y];
    }
    for (int y = bestY.round() + 1; y <= yBot; y++) {
      if (rowDark[y] > maxBelow) maxBelow = rowDark[y];
    }
    final waist = _interpRow(rowDark, bestY);
    if (maxAbove < 8 || maxBelow < 8) return null;
    if (waist > 0.82 * math.min(maxAbove, maxBelow)) return null;

    // Sub-pixel refinement (parabolic on the mirror-mismatch cost).
    final cM = cost(bestY - 1), cP = cost(bestY + 1);
    final denom = cM + cP - 2 * bestCost;
    if (denom.abs() > 1e-9) {
      final off = 0.5 * (cM - cP) / denom;
      if (off.abs() <= 1.0) bestY += off;
    }

    // Symmetry quality vs a deliberately mismatched axis.
    final flat = cost(bestY + maxD * 0.5);
    final score = flat > 1e-6 ? (1.0 - bestCost / flat).clamp(0.0, 1.0) : 0.0;
    if (score < 0.25) return null;
    return [bestY, score];
  }

  /// Linear interpolation of a per-row profile at fractional row [y].
  static double _interpRow(List<double> rows, double y) {
    if (y <= 0) return rows[0];
    if (y >= rows.length - 1) return rows[rows.length - 1];
    final y0 = y.floor();
    final f = y - y0;
    return rows[y0] * (1.0 - f) + rows[y0 + 1] * f;
  }

  /// Refine an integer outer-object column [xInt] at row [y] to the sub-pixel
  /// position where the row intensity crosses the half-coverage level [t50].
  ///
  /// For the left flank the background lies at smaller x (bright) and the object
  /// at larger x (dark); the boundary is between (xInt-1, xInt). For the right
  /// flank it is mirrored, between (xInt, xInt+1). Linear interpolation of the
  /// two bracketing samples to the level `t50` gives the edge to a fraction of a
  /// pixel. Falls back to the integer index when the neighbours don't bracket
  /// `t50` (noise / clipped frame edge), so it can never move the edge outside
  /// the one-pixel transition it was found in.
  static double _subPixelEdgeX(
      List<int> gray, int width, int y, int xInt, double t50,
      {required bool isLeft}) {
    final row = y * width;
    if (isLeft) {
      if (xInt - 1 < 0) return xInt.toDouble();
      final vOut = gray[row + xInt - 1].toDouble(); // background side (bright)
      final vIn = gray[row + xInt].toDouble(); // object side (dark)
      final denom = vOut - vIn;
      if (denom <= 1e-6) return xInt.toDouble();
      final frac = (vOut - t50) / denom; // 0 at xInt-1, 1 at xInt
      if (frac < 0.0 || frac > 1.0) return xInt.toDouble();
      return (xInt - 1) + frac;
    } else {
      if (xInt + 1 >= width) return xInt.toDouble();
      final vIn = gray[row + xInt].toDouble(); // object side (dark)
      final vOut = gray[row + xInt + 1].toDouble(); // background side (bright)
      final denom = vOut - vIn;
      if (denom <= 1e-6) return xInt.toDouble();
      final frac = (t50 - vIn) / denom; // 0 at xInt, 1 at xInt+1
      if (frac < 0.0 || frac > 1.0) return xInt.toDouble();
      return xInt + frac;
    }
  }

  static int _otsu(List<int> hist, int total) {
    double sum = 0;
    for (int t = 0; t < 256; t++) {
      sum += t * hist[t];
    }
    double sumB = 0;
    int wB = 0;
    double maxVar = -1;
    int threshold = 127;
    for (int t = 0; t < 256; t++) {
      wB += hist[t];
      if (wB == 0) continue;
      final wF = total - wB;
      if (wF == 0) break;
      sumB += t * hist[t];
      final mB = sumB / wB;
      final mF = (sum - sumB) / wF;
      final between = wB.toDouble() * wF.toDouble() * (mB - mF) * (mB - mF);
      if (between > maxVar) {
        maxVar = between;
        threshold = t;
      }
    }
    return threshold;
  }

  static double _bandMedian(List<int> gray, int width, int y0, int y1,
      {int x0 = 0, int? x1}) {
    final xEnd = x1 ?? width;
    final vals = <double>[];
    for (int y = y0; y < y1; y++) {
      for (int x = x0; x < xEnd; x += 3) {
        vals.add(gray[y * width + x].toDouble());
      }
    }
    return vals.isEmpty ? 255.0 : _median(vals);
  }

  static double _median(List<double> v) {
    if (v.isEmpty) return 0.0;
    final s = List<double>.from(v)..sort();
    final m = s.length ~/ 2;
    return s.length.isOdd ? s[m] : (s[m - 1] + s[m]) / 2.0;
  }

  static double _percentile(List<double> v, double p) {
    if (v.isEmpty) return 0.0;
    final s = List<double>.from(v)..sort();
    final idx = (p.clamp(0.0, 1.0) * (s.length - 1)).round();
    return s[idx];
  }

  static double _mad(List<double> v, double center) {
    if (v.isEmpty) return 0.0;
    final dev = v.map((x) => (x - center).abs()).toList();
    return _median(dev);
  }

  /// Ordinary least-squares line y = a*x + b. Returns [a, b].
  static List<double> _lineFit(List<double> xs, List<double> ys) {
    final n = xs.length;
    if (n < 2) return [0.0, ys.isEmpty ? 0.0 : ys.first];
    double sx = 0, sy = 0, sxx = 0, sxy = 0;
    for (int i = 0; i < n; i++) {
      sx += xs[i];
      sy += ys[i];
      sxx += xs[i] * xs[i];
      sxy += xs[i] * ys[i];
    }
    final denom = n * sxx - sx * sx;
    if (denom.abs() < 1e-9) return [0.0, sy / n];
    final a = (n * sxy - sx * sy) / denom;
    final b = (sy - a * sx) / n;
    return [a, b];
  }
}

class SilhouetteResult {
  final List<math.Point<double>> contour;
  final Map<String, dynamic> baselineResult;
  final double leftContactX;
  final double rightContactX;
  final double confidence;
  final double otsuThreshold;
  final double contrast;
  final double dropWidth;
  final double dropHeight;

  SilhouetteResult({
    required this.contour,
    required this.baselineResult,
    required this.leftContactX,
    required this.rightContactX,
    required this.confidence,
    required this.otsuThreshold,
    required this.contrast,
    required this.dropWidth,
    required this.dropHeight,
  });
}
