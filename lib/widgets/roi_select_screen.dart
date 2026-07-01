import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image/image.dart' as imglib;

import '../processing/silhouette_extractor.dart';
import '../theme/app_theme.dart';
import 'gradient_button.dart';

/// Lets the user draw a region-of-interest box around the drop before
/// measurement (the standard ADSA workflow), to exclude background
/// contamination or neighbouring features. Returns a [DropRoi] in original
/// image pixels, or null for "measure the whole frame".
class RoiSelectScreen extends StatefulWidget {
  final File image;
  const RoiSelectScreen({super.key, required this.image});

  @override
  State<RoiSelectScreen> createState() => _RoiSelectScreenState();
}

class _RoiSelectScreenState extends State<RoiSelectScreen> {
  int? _imgW;
  int? _imgH;
  Offset? _start;
  Offset? _current;
  Size? _box; // latest layout box, captured during build for ROI mapping

  @override
  void initState() {
    super.initState();
    _loadDimensions();
  }

  Future<void> _loadDimensions() async {
    try {
      final bytes = await widget.image.readAsBytes();
      final decoded = imglib.decodeImage(bytes);
      if (decoded != null && mounted) {
        setState(() {
          _imgW = decoded.width;
          _imgH = decoded.height;
        });
      }
    } catch (_) {/* dimensions stay null -> full-frame only */}
  }

  /// Rendered image rectangle (BoxFit.contain) inside a [box] of given size.
  Rect _renderedRect(Size box) {
    final iw = _imgW!.toDouble();
    final ih = _imgH!.toDouble();
    final scale =
        (box.width / iw) < (box.height / ih) ? box.width / iw : box.height / ih;
    final rw = iw * scale;
    final rh = ih * scale;
    return Rect.fromLTWH((box.width - rw) / 2, (box.height - rh) / 2, rw, rh);
  }

  DropRoi? _toDropRoi(Size box) {
    if (_start == null || _current == null || _imgW == null) return null;
    final rr = _renderedRect(box);
    final scale = rr.width / _imgW!;
    double clampX(double v) => v.clamp(rr.left, rr.right);
    double clampY(double v) => v.clamp(rr.top, rr.bottom);
    final x0 = clampX(_start!.dx), x1 = clampX(_current!.dx);
    final y0 = clampY(_start!.dy), y1 = clampY(_current!.dy);
    int px(double v) => ((v - rr.left) / scale).round();
    int py(double v) => ((v - rr.top) / scale).round();
    final l = px(x0 < x1 ? x0 : x1);
    final r = px(x0 < x1 ? x1 : x0);
    final t = py(y0 < y1 ? y0 : y1);
    final b = py(y0 < y1 ? y1 : y0);
    // Require a meaningful box (>= 5% of each dimension).
    if (r - l < _imgW! * 0.05 || b - t < _imgH! * 0.05) return null;
    return DropRoi(l, t, r, b);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Select drop region'),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      extendBodyBehindAppBar: true,
      body: Container(
        decoration:
            const BoxDecoration(gradient: AppTheme.backgroundGradient),
        child: SafeArea(
          child: Column(
            children: [
              const Padding(
                padding: EdgeInsets.all(12),
                child: Text(
                  'Drag a box around the droplet to exclude background '
                  'features, or measure the whole image.',
                  style:
                      TextStyle(color: AppTheme.textSecondary, fontSize: 13),
                  textAlign: TextAlign.center,
                ),
              ),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final box =
                        Size(constraints.maxWidth, constraints.maxHeight);
                    _box = box;
                    final canSelect = _imgW != null && _imgH != null;
                    return GestureDetector(
                      onPanStart: canSelect
                          ? (d) => setState(() {
                                _start = d.localPosition;
                                _current = d.localPosition;
                              })
                          : null,
                      onPanUpdate: canSelect
                          ? (d) => setState(() => _current = d.localPosition)
                          : null,
                      child: Stack(
                        children: [
                          Positioned.fill(
                            child: Image.file(widget.image,
                                fit: BoxFit.contain),
                          ),
                          if (_start != null && _current != null)
                            Positioned.fromRect(
                              rect: Rect.fromPoints(_start!, _current!),
                              child: Container(
                                decoration: BoxDecoration(
                                  border: Border.all(
                                      color: AppTheme.tealAccent, width: 2),
                                  color: AppTheme.tealAccent
                                      .withValues(alpha: 0.12),
                                ),
                              ),
                            ),
                        ],
                      ),
                    );
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    GradientButton(
                      onPressed: () => Navigator.pop(context, _RoiResult(null)),
                      icon: Icons.fullscreen,
                      label: 'Full image',
                      colors: const [Colors.blueGrey, Colors.blueGrey],
                    ),
                    const SizedBox(width: 12),
                    GradientButton(
                      onPressed: () {
                        final roi = _box == null ? null : _toDropRoi(_box!);
                        Navigator.pop(context, _RoiResult(roi));
                      },
                      icon: Icons.crop,
                      label: 'Measure selection',
                      colors: const [AppTheme.tealAccent, AppTheme.cyanLight],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Wrapper so a null ROI (full-image) is distinguishable from "dismissed".
class _RoiResult {
  final DropRoi? roi;
  _RoiResult(this.roi);
}

/// Outcome of the ROI screen. [proceed] is false when the user backed out;
/// when true, [roi] is the selected box or null for the whole frame.
class RoiSelection {
  final bool proceed;
  final DropRoi? roi;
  const RoiSelection(this.proceed, this.roi);
}

/// Presents the ROI screen and returns the user's choice.
Future<RoiSelection> showRoiSelector(BuildContext context, File image) async {
  final result = await Navigator.push<_RoiResult>(
    context,
    MaterialPageRoute(builder: (_) => RoiSelectScreen(image: image)),
  );
  if (result == null) return const RoiSelection(false, null);
  return RoiSelection(true, result.roi);
}
