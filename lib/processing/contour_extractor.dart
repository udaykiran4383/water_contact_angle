part of '../image_processor.dart';

  /// Extract the most plausible connected contour from edge points.
  /// A pure "largest component" heuristic is brittle when substrate/frame edges
  /// dominate; we instead score components by geometry and border proximity.
List<math.Point<double>> _extractLargestContour(
      List<math.Point<double>> edges, int width, int height) {
    if (edges.isEmpty) return [];

    // Create a grid for fast lookup (quantized to 2-pixel cells)
    int cellSize = 2;
    int gridW = (width / cellSize).ceil();
    Map<int, List<int>> grid = {};

    for (int i = 0; i < edges.length; i++) {
      int gx = (edges[i].x / cellSize).floor();
      int gy = (edges[i].y / cellSize).floor();
      int key = gy * gridW + gx;
      grid.putIfAbsent(key, () => []).add(i);
    }

    // Find connected components
    List<bool> visited = List.filled(edges.length, false);
    List<List<int>> components = [];

    for (int i = 0; i < edges.length; i++) {
      if (visited[i]) continue;

      List<int> component = [];
      List<int> stack = [i];
      visited[i] = true;

      while (stack.isNotEmpty) {
        int cur = stack.removeLast();
        component.add(cur);

        int gx = (edges[cur].x / cellSize).floor();
        int gy = (edges[cur].y / cellSize).floor();

        // Check neighbors in 3x3 grid cells
        for (int dy = -1; dy <= 1; dy++) {
          for (int dx = -1; dx <= 1; dx++) {
            int key = (gy + dy) * gridW + (gx + dx);
            var neighbors = grid[key];
            if (neighbors == null) continue;

            for (int ni in neighbors) {
              if (visited[ni]) continue;
              double dist = math.sqrt(math.pow(edges[ni].x - edges[cur].x, 2) +
                  math.pow(edges[ni].y - edges[cur].y, 2));
              if (dist < 5.0) {
                visited[ni] = true;
                stack.add(ni);
              }
            }
          }
        }
      }

      components.add(component);
    }

    List<int> best = [];
    double bestScore = double.negativeInfinity;
    final imageCenterX = width * 0.5;

    for (final comp in components) {
      if (comp.length < 12) continue;

      double minX = double.infinity;
      double maxX = double.negativeInfinity;
      double minY = double.infinity;
      double maxY = double.negativeInfinity;
      double sumX = 0.0;
      int borderTouches = 0;
      int hardBorderTouches = 0;
      int nearBottom = 0;
      int leftBorderTouches = 0;
      int rightBorderTouches = 0;

      for (final idx in comp) {
        final p = edges[idx];
        minX = math.min(minX, p.x);
        maxX = math.max(maxX, p.x);
        minY = math.min(minY, p.y);
        maxY = math.max(maxY, p.y);
        sumX += p.x;
        if (p.x <= 3.0 ||
            p.x >= width - 4.0 ||
            p.y <= 3.0 ||
            p.y >= height - 4.0) {
          borderTouches++;
        }
        if (p.x <= 1.5 || p.x >= width - 2.5) {
          hardBorderTouches++;
        }
        if (p.x <= 4.0) leftBorderTouches++;
        if (p.x >= width - 5.0) rightBorderTouches++;
        if (p.y >= height * 0.78) nearBottom++;
      }

      final w = maxX - minX;
      final h = maxY - minY;
      final meanX = sumX / comp.length;
      final centerPenalty =
          (meanX - imageCenterX).abs() / math.max(1.0, width * 0.5);
      final widthPenalty = w > width * 0.92
          ? (w - width * 0.92) / math.max(1.0, width.toDouble())
          : 0.0;

      final aspectPenalty = (h / math.max(1.0, w)) < 0.2
          ? 500.0 * (0.2 - (h / math.max(1.0, w)))
          : 0.0;

      final borderFrac = borderTouches / math.max(1.0, comp.length.toDouble());
      final hardBorderFrac =
          hardBorderTouches / math.max(1.0, comp.length.toDouble());
      final unilateralBorder = leftBorderTouches == 0 || rightBorderTouches == 0;
      final likelyFrameEdge = unilateralBorder &&
          hardBorderFrac > 0.12 &&
          h > height * 0.45;

      if (likelyFrameEdge) {
        continue;
      }

      double score = comp.length +
          8.0 * h +
          0.25 * nearBottom -
          2.2 * borderTouches -
          90.0 * borderFrac -
          210.0 * hardBorderFrac -
          40.0 * centerPenalty -
          180.0 * widthPenalty -
          aspectPenalty;
      if (h < 10.0) score -= 120.0;

      if (score > bestScore) {
        bestScore = score;
        best = comp;
      }
    }

    if (best.isEmpty) {
      List<int> largest = [];
      for (final comp in components) {
        if (comp.length > largest.length) largest = comp;
      }
      best = largest;
    }

    if (best.isNotEmpty) {
      int hardBorderTouches = 0;
      for (final idx in best) {
        final p = edges[idx];
        if (p.x <= 1.5 || p.x >= width - 2.5) {
          hardBorderTouches++;
        }
      }
      final hardBorderFrac =
          hardBorderTouches / math.max(1.0, best.length.toDouble());
      if (hardBorderFrac > 0.22) {
        return [];
      }
    }

    return best.map((i) => edges[i]).toList();
  }

  /// Isolates the droplet arc in baseline-aligned coordinates.
  /// Keeps the full above-baseline arc and selects the most plausible connected
  /// component (high vertical extent, centered, both flank supports).
List<math.Point<double>> _extractDropContourAligned(
    List<math.Point<double>> contourAligned,
  ) {
    if (contourAligned.length < 20) return [];

    final maxY = contourAligned.map((p) => p.y).reduce(math.max);
    final minX = contourAligned.map((p) => p.x).reduce(math.min);
    final maxX = contourAligned.map((p) => p.x).reduce(math.max);
    final minY = contourAligned.map((p) => p.y).reduce(math.min);
    final yRange = (maxY - minY).abs();
    final xRange = (maxX - minX).abs();
    if (xRange < 4.0 || yRange < 4.0) return [];

    // Keep the droplet arc above the baseline using an adaptive clearance.
    // Low-angle drops need a smaller clearance; high-angle drops tolerate a
    // larger one. This avoids hard-coding a single y-threshold.
    final negHeights =
        contourAligned.where((p) => p.y < 0.0).map((p) => -p.y).toList()
          ..sort();
    double upperCutoff = 0.35;
    if (negHeights.length >= 20) {
      final qIdx =
          (negHeights.length * 0.14).floor().clamp(0, negHeights.length - 1);
      upperCutoff = (negHeights[qIdx] * 0.70).clamp(0.10, 0.90);
    }
    var candidates =
        contourAligned.where((p) => p.y < -upperCutoff).toList();
    if (candidates.length < 16) {
      candidates = contourAligned.where((p) => p.y < -0.08).toList();
      if (candidates.length < 16) {
        return candidates;
      }
    }

    // Remove near-border vertical edge artifacts (window/frame edges) that can
    // dominate apex detection in screenshot-like images.
    final candMinX = candidates.map((p) => p.x).reduce(math.min);
    final candMaxX = candidates.map((p) => p.x).reduce(math.max);
    final candMinY = candidates.map((p) => p.y).reduce(math.min);
    final candMaxY = candidates.map((p) => p.y).reduce(math.max);
    final candXRange = math.max(1e-6, candMaxX - candMinX);
    final candYRange = math.max(1e-6, candMaxY - candMinY);
    final byX = <int, List<math.Point<double>>>{};
    for (final p in candidates) {
      byX.putIfAbsent(p.x.round(), () => <math.Point<double>>[]).add(p);
    }
    final artifactColumns = <int>{};
    for (final entry in byX.entries) {
      final xKey = entry.key;
      final pts = entry.value;
      if (pts.length < 10) continue;
      final minColY = pts.map((p) => p.y).reduce(math.min);
      final maxColY = pts.map((p) => p.y).reduce(math.max);
      final colSpan = maxColY - minColY;
      final isNearSide =
          xKey <= candMinX + 0.12 * candXRange || xKey >= candMaxX - 0.12 * candXRange;
      if (isNearSide && colSpan > 0.60 * candYRange) {
        artifactColumns.add(xKey);
      }
    }
    if (artifactColumns.isNotEmpty) {
      final filtered = candidates
          .where((p) =>
              !artifactColumns.any((x) => (p.x - x).abs() <= 2.0))
          .toList();
      if (filtered.length >= 16) {
        candidates = filtered;
      }
    }

    const cellSize = 2.0;
    final localMinX = candidates.map((p) => p.x).reduce(math.min);
    final localMinY = candidates.map((p) => p.y).reduce(math.min);
    final gridW =
        (((candidates.map((p) => p.x).reduce(math.max) - localMinX) / cellSize)
                .ceil()) +
            3;

    final grid = <int, List<int>>{};
    for (int i = 0; i < candidates.length; i++) {
      final gx = ((candidates[i].x - localMinX) / cellSize).floor();
      final gy = ((candidates[i].y - localMinY) / cellSize).floor();
      final key = gy * gridW + gx;
      grid.putIfAbsent(key, () => <int>[]).add(i);
    }

    const maxNeighborDistance = 4.8;
    const maxNeighborDistanceSq = maxNeighborDistance * maxNeighborDistance;
    final visited = List<bool>.filled(candidates.length, false);
    List<math.Point<double>> bestComponent = [];
    double bestScore = double.negativeInfinity;
    final globalCenterX = (minX + maxX) * 0.5;

    for (int i = 0; i < candidates.length; i++) {
      if (visited[i]) continue;

      final stack = <int>[i];
      visited[i] = true;
      final componentIdx = <int>[];

      while (stack.isNotEmpty) {
        final cur = stack.removeLast();
        componentIdx.add(cur);
        final gx = ((candidates[cur].x - localMinX) / cellSize).floor();
        final gy = ((candidates[cur].y - localMinY) / cellSize).floor();

        for (int dy = -1; dy <= 1; dy++) {
          for (int dx = -1; dx <= 1; dx++) {
            final key = (gy + dy) * gridW + (gx + dx);
            final neighbors = grid[key];
            if (neighbors == null) continue;
            for (final ni in neighbors) {
              if (visited[ni]) continue;
              final dxp = candidates[ni].x - candidates[cur].x;
              final dyp = candidates[ni].y - candidates[cur].y;
              if (dxp * dxp + dyp * dyp <= maxNeighborDistanceSq) {
                visited[ni] = true;
                stack.add(ni);
              }
            }
          }
        }
      }

      if (componentIdx.length < 14) continue;

      final component = componentIdx.map((idx) => candidates[idx]).toList();
      final cMinX = component.map((p) => p.x).reduce(math.min);
      final cMaxX = component.map((p) => p.x).reduce(math.max);
      final cMinY = component.map((p) => p.y).reduce(math.min);
      final cMaxY = component.map((p) => p.y).reduce(math.max);
      final height = cMaxY - cMinY;
      final width = cMaxX - cMinX;
      if (height < 12.0) continue;
      if (width < xRange * 0.04) continue;
      if (width > xRange * 0.72) continue;

      final meanX =
          component.map((p) => p.x).reduce((a, b) => a + b) / component.length;
      final nearBaselineCount = component.where((p) => p.y > -8.0).length;
      final apexX = component.reduce((a, b) => a.y < b.y ? a : b).x;
      final apexTooCloseToBorder =
          apexX < minX + xRange * 0.06 || apexX > maxX - xRange * 0.06;
      if (apexTooCloseToBorder) {
        continue;
      }
      final leftNearBaseline =
          component.where((p) => p.y > -8.0 && p.x < apexX - 0.8).length;
      final rightNearBaseline =
          component.where((p) => p.y > -8.0 && p.x > apexX + 0.8).length;
      final centerPenalty =
          (meanX - globalCenterX).abs() / math.max(1.0, xRange * 0.5);
      final widthPenalty = width > xRange * 0.85
          ? (width - xRange * 0.85) / math.max(1.0, xRange)
          : 0.0;
      final flankPenalty =
          (leftNearBaseline == 0 || rightNearBaseline == 0) ? 180.0 : 0.0;
      final flankImbalance = (leftNearBaseline - rightNearBaseline).abs() /
          math.max(1.0, (leftNearBaseline + rightNearBaseline).toDouble());
      final imbalancePenalty = 25.0 * flankImbalance;

      final borderNear = component
          .where((p) => p.x < minX + 1.5 || p.x > maxX - 1.5)
          .length;
      final borderNearFrac =
          borderNear / math.max(1.0, component.length.toDouble());

      if (borderNearFrac > 0.25) {
        continue;
      }

      final score = component.length +
          6.0 * height +
          1.8 * nearBaselineCount -
          85.0 * borderNearFrac -
          65.0 * centerPenalty -
          120.0 * widthPenalty -
          flankPenalty -
          imbalancePenalty;

      if (score > bestScore) {
        bestScore = score;
        bestComponent = component;
      }
    }

    if (bestComponent.isNotEmpty) {
      final apexX = bestComponent.reduce((a, b) => a.y < b.y ? a : b).x;
      final leftNearBaseline =
          bestComponent.where((p) => p.y > -10.0 && p.x < apexX - 0.8).length;
      final rightNearBaseline =
          bestComponent.where((p) => p.y > -10.0 && p.x > apexX + 0.8).length;
      if (leftNearBaseline >= 2 && rightNearBaseline >= 2) {
        return bestComponent;
      }
    }

    // Fallback: keep a center-focused band to avoid border components when the
    // strict component scorer cannot identify a clean droplet arc.
    final cMinY = candidates.map((p) => p.y).reduce(math.min);
    final cMaxY = candidates.map((p) => p.y).reduce(math.max);
    final cYSpan = math.max(1e-6, cMaxY - cMinY);
    final topBand = candidates.where((p) => p.y <= cMinY + 0.35 * cYSpan).toList();
    if (topBand.isNotEmpty) {
      final centerGuess =
          topBand.map((p) => p.x).reduce((a, b) => a + b) / topBand.length;
      final xMin = candidates.map((p) => p.x).reduce(math.min);
      final xMax = candidates.map((p) => p.x).reduce(math.max);
      final halfWindow = ((xMax - xMin) * 0.30)
          .clamp(40.0, math.max(70.0, (xMax - xMin) * 0.45))
          .toDouble();
      final focused = candidates
          .where((p) => (p.x - centerGuess).abs() <= halfWindow)
          .toList();
      if (focused.length >= 16) {
        return focused;
      }
    }

    return candidates;
  }
