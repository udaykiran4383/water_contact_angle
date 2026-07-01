import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

/// In-app manual camera tuned for back-lit sessile-drop capture.
///
/// Commercial goniometers win accuracy in the OPTICS, not the sensor: a level,
/// telecentric-ish view of a dark drop on a uniform bright back-light, exposed
/// so the true 50%-intensity edge is preserved (no highlight blooming). A phone
/// can approach this if we (1) lock focus (autofocus hunting changes scale),
/// (2) bias exposure DOWN so the bright field never clips and the drop stays
/// crisply dark, (3) keep the optical axis level with the drop's baseline to
/// avoid perspective/parallax, and (4) disable flash. This screen exposes those
/// controls plus alignment guides, then returns the captured file.
///
/// Returns the captured image [File] via Navigator.pop, or null on cancel/error
/// (the caller then falls back to the system picker).
class DropCameraScreen extends StatefulWidget {
  const DropCameraScreen({super.key});

  @override
  State<DropCameraScreen> createState() => _DropCameraScreenState();
}

class _DropCameraScreenState extends State<DropCameraScreen>
    with WidgetsBindingObserver {
  CameraController? _controller;
  Future<void>? _initFuture;
  String? _error;

  double _minExposure = 0.0;
  double _maxExposure = 0.0;
  // Bias exposure DOWN by default: a slightly under-exposed frame keeps the
  // bright back-light just below clipping and the drop solidly dark, preserving
  // the sharp bright→dark edge ramp the sub-pixel detector relies on.
  double _exposureOffset = -1.0;
  bool _focusLocked = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initFuture = _setup();
  }

  Future<void> _setup() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        setState(() => _error = 'No camera available');
        return;
      }
      final back = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );
      final controller = CameraController(
        back,
        ResolutionPreset.max, // maximum edge pixels along the drop profile
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );
      await controller.initialize();
      // Back-lit capture hygiene.
      await controller.setFlashMode(FlashMode.off);
      try {
        _minExposure = await controller.getMinExposureOffset();
        _maxExposure = await controller.getMaxExposureOffset();
        _exposureOffset = _exposureOffset.clamp(_minExposure, _maxExposure);
        await controller.setExposureOffset(_exposureOffset);
      } catch (_) {/* device without exposure control */}
      try {
        await controller.setFocusMode(FocusMode.auto);
      } catch (_) {}
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() => _controller = controller);
    } catch (e) {
      setState(() => _error = 'Camera init failed: $e');
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    if (state == AppLifecycleState.inactive) {
      c.dispose();
    } else if (state == AppLifecycleState.resumed) {
      _initFuture = _setup();
    }
  }

  Future<void> _tapToFocus(TapDownDetails d, BoxConstraints box) async {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    final offset = Offset(
      d.localPosition.dx / box.maxWidth,
      d.localPosition.dy / box.maxHeight,
    );
    try {
      await c.setExposurePoint(offset);
      await c.setFocusPoint(offset);
      await c.setFocusMode(FocusMode.locked); // lock so scale stops drifting
      if (mounted) setState(() => _focusLocked = true);
    } catch (_) {}
  }

  Future<void> _setExposure(double v) async {
    final c = _controller;
    setState(() => _exposureOffset = v);
    if (c == null) return;
    try {
      await c.setExposureOffset(v);
    } catch (_) {}
  }

  Future<void> _capture() async {
    final c = _controller;
    if (c == null || !c.value.isInitialized || _busy) return;
    setState(() => _busy = true);
    try {
      final shot = await c.takePicture();
      final dir = await getTemporaryDirectory();
      final dest =
          '${dir.path}/drop_${DateTime.now().millisecondsSinceEpoch}.jpg';
      await File(shot.path).copy(dest);
      if (mounted) Navigator.of(context).pop(File(dest));
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = 'Capture failed: $e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('Capture Drop'),
        actions: [
          IconButton(
            tooltip: 'Cancel',
            icon: const Icon(Icons.close),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
      body: FutureBuilder<void>(
        future: _initFuture,
        builder: (context, snap) {
          if (_error != null) return _errorView();
          final c = _controller;
          if (c == null || !c.value.isInitialized) {
            return const Center(
                child: CircularProgressIndicator(color: Colors.white));
          }
          return Column(
            children: [
              Expanded(
                child: LayoutBuilder(
                  builder: (context, box) => GestureDetector(
                    onTapDown: (d) => _tapToFocus(d, box),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        CameraPreview(c),
                        CustomPaint(painter: _GuidePainter()),
                        _tipBanner(),
                      ],
                    ),
                  ),
                ),
              ),
              _controls(),
            ],
          );
        },
      ),
    );
  }

  Widget _errorView() => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.no_photography, color: Colors.white54, size: 48),
              const SizedBox(height: 12),
              Text(_error ?? 'Camera error',
                  style: const TextStyle(color: Colors.white70),
                  textAlign: TextAlign.center),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Use gallery / system camera instead'),
              ),
            ],
          ),
        ),
      );

  Widget _tipBanner() => Positioned(
        top: 8,
        left: 8,
        right: 8,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.45),
            borderRadius: BorderRadius.circular(8),
          ),
          child: const Text(
            'Level the guide line with the drop\'s baseline • bright even '
            'back-light • tap the drop to lock focus • keep the field just '
            'below white (no glare)',
            style: TextStyle(color: Colors.white, fontSize: 11),
          ),
        ),
      );

  Widget _controls() {
    return Container(
      color: Colors.black,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Column(
        children: [
          Row(
            children: [
              const Icon(Icons.brightness_6, color: Colors.white70, size: 18),
              Expanded(
                child: Slider(
                  value: _exposureOffset.clamp(
                      _minExposure == 0 && _maxExposure == 0
                          ? -1.0
                          : _minExposure,
                      _minExposure == 0 && _maxExposure == 0
                          ? 1.0
                          : _maxExposure),
                  min: _minExposure == 0 && _maxExposure == 0
                      ? -1.0
                      : _minExposure,
                  max: _minExposure == 0 && _maxExposure == 0
                      ? 1.0
                      : _maxExposure,
                  onChanged: (_minExposure == 0 && _maxExposure == 0)
                      ? null
                      : _setExposure,
                ),
              ),
              SizedBox(
                width: 46,
                child: Text('${_exposureOffset.toStringAsFixed(1)} EV',
                    style:
                        const TextStyle(color: Colors.white70, fontSize: 11)),
              ),
            ],
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(_focusLocked ? 'Focus: locked' : 'Focus: tap drop',
                  style: TextStyle(
                      color: _focusLocked ? Colors.tealAccent : Colors.white54,
                      fontSize: 12)),
              GestureDetector(
                onTap: _busy ? null : _capture,
                child: Container(
                  width: 68,
                  height: 68,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _busy ? Colors.grey : Colors.white,
                    border: Border.all(color: Colors.tealAccent, width: 4),
                  ),
                  child: _busy
                      ? const Padding(
                          padding: EdgeInsets.all(18),
                          child: CircularProgressIndicator(strokeWidth: 3))
                      : const Icon(Icons.camera_alt, color: Colors.black),
                ),
              ),
              const SizedBox(width: 60),
            ],
          ),
        ],
      ),
    );
  }
}

/// Alignment overlay: a horizontal baseline guide (align with the drop's
/// contact line so the optical axis stays level → no parallax), a centering
/// vertical line, and a rule-of-thirds grid.
class _GuidePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final grid = Paint()
      ..color = Colors.white.withValues(alpha: 0.18)
      ..strokeWidth = 1;
    for (int i = 1; i < 3; i++) {
      final dx = size.width * i / 3;
      final dy = size.height * i / 3;
      canvas.drawLine(Offset(dx, 0), Offset(dx, size.height), grid);
      canvas.drawLine(Offset(0, dy), Offset(size.width, dy), grid);
    }
    // Baseline guide (lower third) — line up with the drop's contact line.
    final base = Paint()
      ..color = Colors.tealAccent.withValues(alpha: 0.8)
      ..strokeWidth = 2;
    final by = size.height * 0.66;
    canvas.drawLine(Offset(0, by), Offset(size.width, by), base);
    // Center vertical.
    final cx = size.width / 2;
    canvas.drawLine(Offset(cx, 0), Offset(cx, size.height),
        Paint()..color = Colors.white.withValues(alpha: 0.25));
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
