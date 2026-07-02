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
  /// Why the last [extract] call returned null (diagnostic/QC aid; empty on
  /// success). Static because extraction is a single-threaded pipeline stage.
  static String lastRejectReason = '';

  /// Why the last [_stepBaseline] attempt returned null (diagnostic).
  static String lastStepReason = '';

  /// Trace of the last [_junctionRefine] bulge arbitration (diagnostic).
  static String lastJunctionInfo = '';

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
    lastRejectReason = '';
    if (width < 40 || height < 40 || gray.length < width * height) {
      lastRejectReason = 'image_too_small';
      return null;
    }

    // Effective scan window: the ROI if supplied, else the whole frame. All
    // statistics, the baseline and the drop search are confined to it.
    final rx0 = roi == null ? 0 : roi.left.clamp(0, width);
    final ry0 = roi == null ? 0 : roi.top.clamp(0, height);
    final rx1 = roi == null ? width : roi.right.clamp(0, width);
    final ry1 = roi == null ? height : roi.bottom.clamp(0, height);
    final effW = rx1 - rx0;
    final effH = ry1 - ry0;
    if (effW < 30 || effH < 30) {
      lastRejectReason = 'roi_too_small';
      return null;
    }
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
    if (darkN == 0) {
      lastRejectReason = 'no_dark_pixels';
      return null;
    }
    final darkMean = darkSum / darkN;
    final contrast = (bg - darkMean); // bright minus dark
    final objectFraction = darkN / total;
    // Background must be clearly brighter than the object, and the object must
    // occupy a sensible fraction (not the whole window, not a speck).
    if (contrast < 35 || objectFraction < 0.005 || objectFraction > 0.85) {
      lastRejectReason = 'low_contrast_or_bad_object_fraction';
      return null;
    }

    bool isObj(int x, int y) => inRoi(x, y) && gray[y * width + x] < otsu;

    // Half-coverage intensity level: the true (anti-aliased) edge of a dark
    // object on the bright background sits where the intensity crosses midway
    // between the two levels. Used for BOTH the horizontal flank edges and the
    // vertical substrate-top crossings that define the baseline.
    final t50 = (bg + darkMean) / 2.0;

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
    String baselineMethod = 'none';

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
        baselineMethod = 'specular';
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
    bool matteFlankSupported = false;
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
          // Integer first-dark rows carry a systematic ~0.5 px bias (the true
          // substrate top is the 50%-coverage crossing, one transition pixel
          // higher); refine to sub-pixel so the baseline — to which the angle
          // is most sensitive (dθ ≈ σ_baseline/contact-half-width) — does not
          // inherit it. Matters most for small drops.
          by.add(_subPixelEdgeY(
              gray, width, height, x, topObj[x].round(), t50));
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
        baselineMethod = 'matte';
        // A REAL substrate band spans the frame, so its "top" columns must
        // include the outer flanks on BOTH sides. When they don't, the
        // cluster is almost certainly the drop's own upper edge (mid-gray
        // substrate brighter than Otsu — glossy stages), and the "baseline"
        // would cut through the drop.
        final flankW = effW * 0.20;
        final leftSupport =
            bx.where((v) => v <= rx0 + flankW).length;
        final rightSupport =
            bx.where((v) => v >= rx1 - flankW).length;
        final minSide = math.max(4, (effW * 0.015).round());
        matteFlankSupported =
            leftSupport >= minSide && rightSupport >= minSide;
      }
    }

    // --- 2c. Substrate-step baseline: visible surface line on the flanks -
    // Glossy/mid-gray stages are BRIGHTER than the Otsu threshold, so the
    // matte path never sees them; but the surface line is still a clear
    // bright→darker vertical step on the columns flanking the drop. Detect
    // the strongest sustained step per flank column (level-agnostic,
    // gradient-based, sub-pixel via parabolic interpolation) and fit a line
    // when BOTH flanks agree. Only consulted when the matte baseline lacks
    // flank support, so proven matte/back-lit rigs are untouched.
    final matteAccepted = haveBaseline && reflectionScore == 0.0;
    if (!haveBaseline || matteAccepted) {
      final sb =
          _stepBaseline(gray, width, height, rx0, ry0, rx1, ry1, topObj);
      // Adoption rule: take the step line outright when there is no matte
      // baseline or the matte cluster lacks flank support. When the matte
      // line IS flank-supported, only override it if the step line sits
      // clearly ABOVE it — the signature of a glossy stage whose mid-gray
      // top surface is visible above a dark front edge (the matte path then
      // latched onto the front edge, below the true contact plane). On a
      // true matte rig both detectors find the same line and matte is kept.
      bool adopt = false;
      bool overridingMatte = false;
      if (sb != null) {
        if (!haveBaseline || !matteFlankSupported) {
          adopt = true;
        } else {
          final xcProbe = (rx0 + rx1) / 2.0;
          final stepC = sb[0] * xcProbe + sb[1];
          final matteC = slope * xcProbe + intercept;
          overridingMatte = stepC < matteC - 10.0;
          adopt = overridingMatte;
        }
      }
      if (adopt) {
        final double matteSlope = slope;
        final double matteIntercept = intercept;
        final int matteInliers = baselineInliers;
        slope = sb![0];
        intercept = sb[1];
        baselineInliers = sb[2].round();
        tol = math.max(tol, 8.0);
        haveBaseline = true;
        baselineMethod = 'step';
        // The flank horizon of a glossy stage viewed by a slightly
        // downward-looking camera (ISO 19403-2 recommends 0–4° down) is the
        // substrate's FAR edge — the true contact line, where the drop meets
        // its reflection, lies below it. Krüss ADVANCE ("contour
        // discontinuity"), the Dropometer (Chen et al. 2018,
        // "slope-sign flip") and DE10214439A1 all locate the contact points
        // as the CORNER of each flank's outermost-x trace: the drop edge and
        // its mirror image meet in a V (θ<90°) or waist (θ>90°) vertex.
        // Detect that corner on each flank with two-segment line fits and,
        // when both flanks agree, move the baseline to the line through the
        // two corners (which also yields the true tilt).
        final xc = (rx0 + rx1) / 2.0;
        final yAtC = slope * xc + intercept;
        // A near-vertical-run (near-90°) junction estimate is only trusted
        // when there is no matte alternative: a drop equator is locally
        // mirror-symmetric too, so the run signal alone cannot overrule a
        // flank-supported matte line.
        final jr = _junctionRefine(
            gray, width, height, rx0, ry0, rx1, ry1, otsu, bg, yAtC,
            allowVerticalRun: !overridingMatte,
            seedSlope: slope,
            matteY: overridingMatte
                ? matteSlope * xc + matteIntercept
                : null);
        if (jr != null && jr[0] * xc + jr[1] > yAtC - 3.0) {
          slope = jr[0];
          intercept = jr[1];
          baselineMethod = 'step+junction';
        } else if (matteIntercept.isFinite &&
            (overridingMatte ||
                matteSlope * xc + matteIntercept > yAtC)) {
          // The corner signal did not confirm a junction. The bare step
          // horizon is known to be biased HIGH (it is the substrate's far
          // edge), so if a matte line exists BELOW it — the contact
          // shadow/band — that line is the better estimate; and a
          // flank-supported matte line always wins over an unconfirmed
          // horizon. (A matte line ABOVE the step horizon is the drop's own
          // top edge — keep the step line then.)
          slope = matteSlope;
          intercept = matteIntercept;
          baselineInliers = matteInliers;
          baselineMethod = 'matte';
        }
      }
    }

    if (!haveBaseline || !intercept.isFinite) {
      lastRejectReason = 'no_baseline';
      return null;
    }
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
        // A dark band along the window top (vignette/fixture shadow) is WIDE
        // and FLAT and its mass HUGS the top rows; penalise only that. A wide
        // drop whose dosing needle reaches the top edge also touches the top
        // and can exceed the aspect gate, but its vertical centre sits well
        // below the top band — keep it.
        final compCenterY = (miny + maxy) / 2.0;
        if (miny <= ry0 + 2 &&
            compW > 1.2 * compH &&
            compCenterY < ry0 + 0.33 * effH) {
          score -= 1e7;
        }
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
    if (bestLabel < 0) {
      lastRejectReason = 'no_drop_component';
      return null;
    }
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
          ly.add(_subPixelEdgeY(
              gray, width, height, x, topObj[x].round(), t50));
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
    if (dropHeight < 8 || dropWidth < 10) {
      lastRejectReason = 'drop_too_small (h=$dropHeight w=$dropWidth)';
      return null;
    }

    // --- 4. Row-scan the outer silhouette of the drop component ----------
    final contour = <math.Point<double>>[];
    final xLo = math.max(0, xd0 - 2);
    final xHi = math.min(width - 1, xd1 + 2);
    final leftEdge = <math.Point<double>>[];
    final rightEdge = <math.Point<double>>[];
    final yTop = math.max(0, apexY.floor());
    // On a tilted stage the contact line sits LOWER on the downhill side than
    // at the drop centre, so the scan must continue to the deepest per-column
    // baseline over the drop span — stopping at the centre row amputates the
    // downhill contact region and biases every near-contact method.
    final baseDeep = math.max(baseAt(xLo.toDouble()), baseAt(xHi.toDouble()));
    // Each row's outer object column is refined to the sub-pixel `t50`
    // crossing — the integer column index alone caps the contour (and thus
    // the ADSA fit) at ±0.5 px. We use the 50%-crossing rather than the Otsu
    // level (which is biased inward for a dark object on a bright, majority
    // background). See sub-pixel edge audit.
    // Rows below the UPHILL contact intersect the drop on one flank only; the
    // other run boundary is where the sloped baseline crosses the row (dark
    // substrate outside, not a drop edge). Accept a flank only when the pixels
    // just outside it are bright background, and collect the one-sided rows
    // separately so the paired arrays stay row-aligned for the needle trim.
    bool brightOutside(int y, int xOut, int dir) {
      final row = y * width;
      for (int k = 0; k < 2; k++) {
        final x = xOut + dir * k;
        if (x < 0 || x >= width) break;
        if (gray[row + x] >= t50) return true;
      }
      return false;
    }

    final leftExtra = <math.Point<double>>[];
    final rightExtra = <math.Point<double>>[];
    for (int y = yTop; y < height; y++) {
      if (y > baseDeep - 1) break;
      int minx = -1, maxx = -1;
      for (int x = xLo; x <= xHi; x++) {
        if (labels[y * width + x] == bestLabel) {
          if (minx < 0) minx = x;
          maxx = x;
        }
      }
      if (minx < 0 || maxx <= minx) continue;
      final yd = y.toDouble();
      final leftOk = brightOutside(y, minx - 1, -1);
      final rightOk = brightOutside(y, maxx + 1, 1);
      if (leftOk && rightOk) {
        final lx = _subPixelEdgeX(gray, width, y, minx, t50, isLeft: true);
        final rx = _subPixelEdgeX(gray, width, y, maxx, t50, isLeft: false);
        leftEdge.add(math.Point(lx, yd));
        rightEdge.add(math.Point(rx, yd));
      } else if (leftOk) {
        leftExtra.add(math.Point(
            _subPixelEdgeX(gray, width, y, minx, t50, isLeft: true), yd));
      } else if (rightOk) {
        rightExtra.add(math.Point(
            _subPixelEdgeX(gray, width, y, maxx, t50, isLeft: false), yd));
      }
    }
    if (leftEdge.length < 6) {
      lastRejectReason = 'too_few_edge_rows (${leftEdge.length}) '
          'method=$baselineMethod baseY=${intercept.toStringAsFixed(1)} '
          'dropW=${dropWidth.toStringAsFixed(0)} apexY=${apexY.toStringAsFixed(0)}';
      return null;
    }

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
      ..addAll(rightEdge)
      ..addAll(leftExtra)
      ..addAll(rightExtra);

    // Contacts = silhouette edges at the lowest valid row on EACH flank (the
    // two flanks reach the tilted baseline at different rows).
    final leftContactX =
        leftExtra.isNotEmpty ? leftExtra.last.x : leftEdge.last.x;
    final rightContactX =
        rightExtra.isNotEmpty ? rightExtra.last.x : rightEdge.last.x;

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
      'baseline_method': baselineMethod,
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

  /// Locate the substrate surface line from the columns FLANKING the drop.
  ///
  /// Unlike the matte path this makes no assumption about the substrate being
  /// darker than the Otsu threshold — a glossy mid-gray stage (Teflon, glass
  /// with reflected light, camera looking a few degrees down per ISO 19403-2)
  /// shows its top edge as a bright→mid-gray transition that can be a GRADUAL
  /// ramp (tens of rows), far too soft for a fixed-window gradient detector.
  /// Per column we therefore find the two intensity PLATEAUS (background
  /// above, substrate below) and localise the sub-pixel crossing of their
  /// midpoint level — precise regardless of ramp width.
  ///
  /// Only columns with NO dark object at all ([topObj] NaN) vote: that
  /// automatically excludes the drop, the dosing needle, and any burned-in
  /// annotation text/lines, all of which are dark. Returns
  /// `[slope, intercept, inlierCount]` or null when the flanks do not agree on
  /// a line (e.g. tight ROI with no visible substrate, or featureless scene).
  static List<double>? _stepBaseline(List<int> gray, int width, int height,
      int rx0, int ry0, int rx1, int ry1, List<double> topObj) {
    lastStepReason = '';
    final effW = rx1 - rx0;
    final effH = ry1 - ry0;
    final flankW = math.max(8, (effW * 0.24).round());
    if (effW < 60 || effH < 40) {
      lastStepReason = 'window_too_small';
      return null;
    }

    final sx = <double>[], sy = <double>[];
    void scanColumn(int x) {
      // Columns containing a dark object (drop, needle, burned-in text) may
      // still see the surface transition ABOVE that object — e.g. a glossy
      // stage whose mid-gray top surface ends in a dark front edge below.
      // Search only the region above the first dark run in that case.
      final int yCap = topObj[x].isFinite
          ? math.min(ry1 - 6, topObj[x].round() - 6)
          : ry1 - 6;
      if (yCap - ry0 < 30) return;
      // Wide-window mean step (captures soft ramps), windows never crossing
      // the dark-object cap so a dark front edge below the surface cannot
      // dominate the response.
      double stepAt(int y) {
        double above = 0, below = 0;
        int n = 0;
        for (int k = 3; k <= 14; k++) {
          if (y - k < ry0 || y + k > yCap + 4) break;
          above += gray[(y - k) * width + x];
          below += gray[(y + k) * width + x];
          n++;
        }
        if (n < 6) return 0.0;
        return (above - below) / n;
      }

      // The surface top is the FIRST sustained downward step from the top of
      // the frame — not the strongest (on stages with a dark front edge, the
      // strongest step is that edge, below the true surface). March down to
      // the first response ≥ threshold, then follow it to its local peak.
      int bestY = -1;
      double bestStep = 0.0;
      for (int y = ry0 + 6; y < yCap; y++) {
        final s = stepAt(y);
        if (s >= 8.0) {
          bestY = y;
          bestStep = s;
          for (int y2 = y + 1; y2 < yCap; y2++) {
            final s2 = stepAt(y2);
            if (s2 >= bestStep) {
              bestStep = s2;
              bestY = y2;
            } else if (s2 < bestStep * 0.7) {
              break;
            }
          }
          break;
        }
      }
      if (bestY < 0) return;
      // Plateau levels well away from the transition (the below-plateau must
      // stay above any dark object in this column).
      final aLo = math.max(ry0, bestY - 34);
      final aHi = math.max(ry0, bestY - 12);
      final bLo = math.min(yCap + 2, bestY + 12);
      final bHi = math.min(yCap + 2, bestY + 34);
      if (aHi - aLo < 8 || bHi - bLo < 8) return;
      final above = <double>[], below = <double>[];
      for (int y = aLo; y <= aHi; y++) {
        above.add(gray[y * width + x].toDouble());
      }
      for (int y = bLo; y <= bHi; y++) {
        below.add(gray[y * width + x].toDouble());
      }
      final a = _median(above);
      final b = _median(below);
      if (a - b < 14.0) return; // no real surface contrast
      // Sub-pixel crossing of the midpoint level, scanning down.
      final mid = (a + b) / 2.0;
      double? yCross;
      for (int y = math.max(ry0, bestY - 16);
          y < math.min(ry1 - 1, bestY + 16);
          y++) {
        final v0 = gray[y * width + x].toDouble();
        final v1 = gray[(y + 1) * width + x].toDouble();
        if (v0 >= mid && v1 < mid) {
          final denom = v0 - v1;
          yCross = denom > 1e-6 ? y + (v0 - mid) / denom : y.toDouble();
          break;
        }
      }
      if (yCross == null) return;
      sx.add(x.toDouble());
      sy.add(yCross);
    }

    for (int x = rx0; x < rx0 + flankW; x++) {
      scanColumn(x);
    }
    final leftN = sx.length;
    for (int x = rx1 - flankW; x < rx1; x++) {
      scanColumn(x);
    }
    final rightN = sx.length - leftN;
    final minSide = math.max(5, (flankW * 0.12).round());
    if (leftN < minSide || rightN < minSide) {
      lastStepReason = 'flank_votes L=$leftN R=$rightN need=$minSide';
      return null;
    }

    // Robust line: median-seeded inlier passes (the flanks can contain other
    // horizontal features — needle shadow, frame vignette — but the surface
    // line is the one BOTH sides agree on).
    final med = _median(sy);
    var ix = <double>[], iy = <double>[];
    for (int i = 0; i < sx.length; i++) {
      if ((sy[i] - med).abs() <= 14.0) {
        ix.add(sx[i]);
        iy.add(sy[i]);
      }
    }
    if (ix.length < 2 * minSide) {
      lastStepReason = 'median_inliers ${ix.length} need=${2 * minSide}';
      return null;
    }
    var line = _lineFit(ix, iy);
    for (int pass = 0; pass < 2; pass++) {
      final nx = <double>[], ny = <double>[];
      for (int i = 0; i < ix.length; i++) {
        if ((iy[i] - (line[0] * ix[i] + line[1])).abs() <= 3.0) {
          nx.add(ix[i]);
          ny.add(iy[i]);
        }
      }
      if (nx.length < 2 * minSide) {
        lastStepReason = 'refine_inliers ${nx.length} need=${2 * minSide}';
        return null;
      }
      line = _lineFit(nx, ny);
      ix = nx;
      iy = ny;
    }
    // Both sides must survive the inlier passes.
    final leftIn = ix.where((v) => v < rx0 + flankW).length;
    final rightIn = ix.where((v) => v >= rx1 - flankW).length;
    if (leftIn < minSide || rightIn < minSide) {
      lastStepReason = 'side_survivors L=$leftIn R=$rightIn need=$minSide';
      return null;
    }
    if (line[0].abs() > 0.45) {
      lastStepReason = 'slope ${line[0].toStringAsFixed(3)}';
      return null;
    }
    double rss = 0.0;
    for (int i = 0; i < ix.length; i++) {
      final e = iy[i] - (line[0] * ix[i] + line[1]);
      rss += e * e;
    }
    if (math.sqrt(rss / ix.length) > 2.2) {
      lastStepReason = 'rms ${math.sqrt(rss / ix.length).toStringAsFixed(2)}';
      return null;
    }
    return [line[0], line[1], ix.length.toDouble()];
  }

  /// Refine a flank-horizon baseline down to the drop/reflection JUNCTION.
  ///
  /// For each flank, trace the outermost dark pixel per row through a window
  /// around the seed row, then find the row where the trace has a corner —
  /// two-segment line fits above/below each candidate row, scored by the
  /// angle between the segments over their residuals (the Krüss/Dropometer
  /// "contour discontinuity" signal). The contact points are the segment
  /// intersections; the returned `[slope, intercept]` line passes through
  /// both corners. Null when either flank lacks a confident corner (e.g.
  /// θ≈90°, where the trace is straight — the caller keeps its seed line).
  static List<double>? _junctionRefine(List<int> gray, int width, int height,
      int rx0, int ry0, int rx1, int ry1, int otsu, double bg, double ySeed,
      {bool allowVerticalRun = true, double seedSlope = 0.0, double? matteY}) {
    // Dark threshold isolating the truly dark drop+reflection (excludes a
    // mid-gray glossy substrate — same construction as the specular path).
    double fg = 255.0;
    for (int y = ry0; y < ry1; y += 2) {
      final base = y * width;
      for (int x = rx0; x < rx1; x += 2) {
        final v = gray[base + x].toDouble();
        if (v < fg) fg = v;
      }
    }
    final thr = math.min(otsu.toDouble(), fg + 0.35 * (bg - fg));

    final int y0i = ySeed.round();
    final int yLo = math.max(ry0 + 1, y0i - 30);
    int yHi = math.min(
        ry1 - 2, y0i + math.max(40, ((ry1 - 1 - y0i) * 0.7).round()));
    // When arbitrating against a matte line, the window must reach it.
    if (matteY != null) {
      yHi = math.max(yHi, math.min(ry1 - 2, matteY.round() + 4));
    }
    if (yHi - yLo < 26) return null;

    // Drop x-extent just above the seed bounds the flank search (excludes
    // distant dark artifacts such as burned-in labels).
    int dx0 = -1, dx1 = -1;
    for (int y = math.max(ry0, y0i - 24); y < y0i - 4; y++) {
      final base = y * width;
      for (int x = rx0; x < rx1; x++) {
        if (gray[base + x] < thr) {
          if (dx0 < 0 || x < dx0) dx0 = x;
          if (x > dx1) dx1 = x;
        }
      }
    }
    if (dx0 < 0 || dx1 - dx0 < 30) return null;
    final xPad = math.max(20, ((dx1 - dx0) * 0.15).round());
    final xLo = math.max(rx0, dx0 - xPad);
    final xHi = math.min(rx1 - 1, dx1 + xPad);

    // Per-flank outermost-x trace (NaN when the row has no dark pixel).
    final n = yHi - yLo + 1;
    final traceL = List<double>.filled(n, double.nan);
    final traceR = List<double>.filled(n, double.nan);
    for (int y = yLo; y <= yHi; y++) {
      final base = y * width;
      int minx = -1, maxx = -1;
      for (int x = xLo; x <= xHi; x++) {
        if (gray[base + x] < thr) {
          if (minx < 0) minx = x;
          maxx = x;
        }
      }
      if (minx >= 0) {
        traceL[y - yLo] = minx.toDouble();
        traceR[y - yLo] = maxx.toDouble();
      }
    }

    // Two-segment corner detection on one trace. Returns [row, x] sub-pixel
    // corner or null.
    List<double>? corner(List<double> tr) {
      const w = 10; // segment length (rows)
      double bestScore = 0.0;
      int bestI = -1;
      List<double>? bestA, bestB;
      for (int i = w; i < n - w; i++) {
        final ax = <double>[], ay = <double>[];
        final bx = <double>[], by = <double>[];
        for (int k = i - w; k < i; k++) {
          if (tr[k].isFinite) {
            ax.add((yLo + k).toDouble());
            ay.add(tr[k]);
          }
        }
        for (int k = i + 1; k <= i + w; k++) {
          if (tr[k].isFinite) {
            bx.add((yLo + k).toDouble());
            by.add(tr[k]);
          }
        }
        if (ax.length < w - 2 || bx.length < w - 2) continue;
        final la = _lineFit(ax, ay); // x = a*y + b (x as function of row)
        final lb = _lineFit(bx, by);
        double rms(List<double> xs, List<double> ys, List<double> l) {
          double s = 0;
          for (int k = 0; k < xs.length; k++) {
            final e = ys[k] - (l[0] * xs[k] + l[1]);
            s += e * e;
          }
          return math.sqrt(s / xs.length);
        }

        final angA = math.atan(la[0]);
        final angB = math.atan(lb[0]);
        final bend = (angA - angB).abs();
        final res = rms(ax, ay, la) + rms(bx, by, lb);
        final score = bend / (res + 0.35);
        if (score > bestScore) {
          bestScore = score;
          bestI = i;
          bestA = la;
          bestB = lb;
        }
      }
      if (bestI < 0 || bestA == null || bestB == null) return null;
      final bend = (math.atan(bestA[0]) - math.atan(bestB[0])).abs();
      // Require a real corner: ≥14° bend and a decent score.
      if (bend < 0.25 || bestScore < 0.55) return null;
      // Sub-pixel corner = intersection of the two segments.
      final denom = bestA[0] - bestB[0];
      double yc = (yLo + bestI).toDouble();
      if (denom.abs() > 1e-9) {
        final yi = (bestB[1] - bestA[1]) / denom;
        if ((yi - yc).abs() <= w) yc = yi;
      }
      return [yc, bestA[0] * yc + bestA[1]];
    }

    // Near-90° fallback (Chen et al. 2018, Dropometer): when drop and
    // reflection edges are both near-vertical the corner vanishes; instead
    // find the longest near-vertical run of the trace straddling the seed
    // and place the contact one-third of the way down it (their empirical
    // rule from ~100 test images).
    List<double>? verticalRun(List<double> tr) {
      int bestStart = -1, bestLen = 0, curStart = -1;
      for (int i = 3; i < n - 3; i++) {
        final ok = tr[i].isFinite &&
            tr[i - 3].isFinite &&
            tr[i + 3].isFinite &&
            ((tr[i + 3] - tr[i - 3]).abs() / 6.0) <= 0.18;
        if (ok) {
          curStart = curStart < 0 ? i : curStart;
          final len = i - curStart + 1;
          if (len > bestLen) {
            bestLen = len;
            bestStart = curStart;
          }
        } else {
          curStart = -1;
        }
      }
      if (bestLen < 14) return null;
      final runTop = yLo + bestStart;
      final runBot = runTop + bestLen;
      // The run must sit at/below the seed horizon (the contact lies below
      // the visible far-edge surface line, never above it).
      if (runTop > y0i + 40 || runBot < y0i - 5) return null;
      final idx = bestStart + bestLen ~/ 3;
      return [(yLo + idx).toDouble(), tr[idx]];
    }

    // Mirror-symmetry axis fallback (Stalder/DropSnake principle — the
    // reflection is data): the junction row is where the flank trace above
    // best mirrors the trace below. Requires a SHARP, well-matched minimum;
    // like the vertical-run rule it is only allowed when there is no matte
    // alternative (a smooth circular arc is locally mirror-symmetric about
    // its equator, so this signal cannot overrule a supported matte line).
    List<double>? mirrorAxis(List<double> tr) {
      final costs = List<double>.filled(n, double.nan);
      double bestCost = double.infinity;
      int bestI = -1;
      for (int i = 14; i < n - 14; i++) {
        if (!tr[i].isFinite) continue;
        double s = 0;
        int c = 0;
        final dMax = math.min(22, math.min(i, n - 1 - i));
        for (int d = 2; d <= dMax; d++) {
          final a = tr[i - d], b = tr[i + d];
          if (!a.isFinite || !b.isFinite) continue;
          s += (a - b).abs();
          c++;
        }
        if (c < 10) continue;
        final cost = s / c;
        costs[i] = cost;
        if (cost < bestCost) {
          bestCost = cost;
          bestI = i;
        }
      }
      if (bestI < 0 || bestCost > 1.6) return null;
      final finite = costs.where((v) => v.isFinite).toList()..sort();
      if (finite.length < 24) return null;
      final medCost = finite[finite.length ~/ 2];
      if (bestCost > 0.45 * medCost) return null;
      return [(yLo + bestI).toDouble(), tr[bestI]];
    }

    final cl = corner(traceL) ??
        (allowVerticalRun
            ? (mirrorAxis(traceL) ?? verticalRun(traceL))
            : null);
    final cr = corner(traceR) ??
        (allowVerticalRun
            ? (mirrorAxis(traceR) ?? verticalRun(traceR))
            : null);
    if (cl == null || cr == null) {
      // Matte-override bulge test: when arbitrating between a step horizon
      // above and a matte (dark front edge) line below, the drop+reflection
      // blob NARROWS between its width maximum (the contact bulge) and the
      // matte line if the true contact is above the matte line — whereas
      // when the matte line IS the contact, the width maximum sits at the
      // matte line itself (this separates a genuine junction from the
      // equator of a θ>90° drop, which is widest mid-window but shows no
      // narrowing at the matte line... it does not narrow below the contact).
      if (matteY != null) {
        final widths = List<double>.filled(n, double.nan);
        double maxW = 0;
        int maxI = -1;
        for (int i = 0; i < n; i++) {
          if (traceL[i].isFinite && traceR[i].isFinite) {
            widths[i] = traceR[i] - traceL[i];
            if (widths[i] > maxW) {
              maxW = widths[i];
              maxI = i;
            }
          }
        }
        final mi = (matteY - yLo).round().clamp(2, n - 1);
        // Sample the width a little ABOVE the matte line — the last few rows
        // before it sit inside the front-edge blur and read spuriously wide.
        final nearMatte = <double>[];
        for (int i = math.max(0, mi - 18); i <= math.max(0, mi - 6); i++) {
          if (widths[i].isFinite) nearMatte.add(widths[i]);
        }
        final wmDbg = nearMatte.length >= 4 ? _median(nearMatte) : double.nan;
        lastJunctionInfo = 'bulge: maxW=${maxW.toStringAsFixed(0)} '
            'yMax=${maxI >= 0 ? yLo + maxI : -1} wm=${wmDbg.toStringAsFixed(0)} '
            'nearN=${nearMatte.length} y0i=$y0i matteY=${matteY.toStringAsFixed(0)} '
            'yLo=$yLo yHi=$yHi';
        if (maxI >= 0 && nearMatte.length >= 4 && maxW > 40) {
          final wm = _median(nearMatte);
          final yMax = yLo + maxI;
          if (wm < 0.88 * maxW &&
              yMax >= y0i + 6 &&
              yMax <= matteY - 8) {
            // Sub-pixel via parabola on the width profile.
            double yb = yMax.toDouble();
            if (maxI > 0 &&
                maxI < n - 1 &&
                widths[maxI - 1].isFinite &&
                widths[maxI + 1].isFinite) {
              final denom =
                  widths[maxI - 1] + widths[maxI + 1] - 2 * widths[maxI];
              if (denom.abs() > 1e-9) {
                final off =
                    0.5 * (widths[maxI - 1] - widths[maxI + 1]) / denom;
                if (off.abs() <= 1.5) yb += off;
              }
            }
            final xcHere = (dx0 + dx1) / 2.0;
            return [seedSlope, yb - seedSlope * xcHere];
          }
        }
      }
      return null;
    }
    final xL = cl[1], yL = cl[0];
    final xR = cr[1], yR = cr[0];
    if ((xR - xL).abs() < 30) return null;
    final slope = (yR - yL) / (xR - xL);
    // These rigs are near-level; a large implied tilt means one flank's
    // "corner" is an artifact (needle shadow, glare) — reject the junction.
    if (slope.abs() > 0.06) return null;
    final intercept = yL - slope * xL;
    return [slope, intercept];
  }

  /// Vertical analogue of [_subPixelEdgeX]: refine an integer first-object row
  /// [yInt] in column [x] (bright background above, dark substrate/object
  /// below) to the sub-pixel row where the intensity crosses [t50]. Falls back
  /// to the integer row when the neighbours don't bracket the level.
  static double _subPixelEdgeY(
      List<int> gray, int width, int height, int x, int yInt, double t50) {
    if (yInt - 1 < 0 || yInt >= height) return yInt.toDouble();
    final vOut = gray[(yInt - 1) * width + x].toDouble(); // above (bright)
    final vIn = gray[yInt * width + x].toDouble(); // below (dark)
    final denom = vOut - vIn;
    if (denom <= 1e-6) return yInt.toDouble();
    final frac = (vOut - t50) / denom; // 0 at yInt-1, 1 at yInt
    if (frac < 0.0 || frac > 1.0) return yInt.toDouble();
    return (yInt - 1) + frac;
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
