import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:sensors_plus/sensors_plus.dart';

/// In-app manual camera tuned for back-lit sessile-drop capture.
///
/// Commercial goniometers win accuracy in the OPTICS, not the sensor: a level,
/// telecentric-ish view of a dark drop on a uniform bright back-light, exposed
/// so the true 50%-intensity edge is preserved (no highlight blooming). A phone
/// approaches this with:
///  • a LIVE LEVEL readout (accelerometer): roll ≈ 0° keeps the baseline
///    horizontal in-frame; pitch 0–4° down is the ISO 19403-2 recommendation
///    so the contact points and reflection are visible;
///  • tap-to-lock FOCUS (autofocus hunting changes magnification) and a
///    lockable EXPOSURE biased down (~−1 EV) so the bright field never clips;
///  • ZOOM from a distance (poor-man's telecentricity — less perspective
///    error than shooting close);
///  • a DRAGGABLE baseline guide to line up with the real contact line;
///  • a post-capture EXPOSURE CHECK (highlight clipping + silhouette
///    contrast) that offers a retake before the frame enters analysis.
///
/// Returns the captured image [File] via Navigator.pop, or null on
/// cancel/error (the caller then falls back to the system picker).
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
  // bright back-light just below clipping and the drop solidly dark,
  // preserving the sharp bright→dark ramp the sub-pixel detector relies on.
  double _exposureOffset = -1.0;
  bool _exposureLocked = false;
  bool _focusLocked = false;

  double _minZoom = 1.0;
  double _maxZoom = 1.0;
  double _zoom = 1.0;

  // Device attitude (deg). Roll: rotation about the optical axis (baseline
  // leveling). Pitch: optical-axis tilt, positive = camera looking down.
  double _rollDeg = 0.0;
  double _pitchDeg = 0.0;
  StreamSubscription<AccelerometerEvent>? _accelSub;

  // Draggable baseline guide (fraction of preview height).
  double _guideY = 0.66;

  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initFuture = _setup();
    _accelSub = accelerometerEventStream(
            samplingPeriod: const Duration(milliseconds: 120))
        .listen((e) {
      // Portrait hold: gravity along +y when upright. Roll = sideways lean,
      // pitch = screen tilting up (camera looking down).
      final roll = math.atan2(e.x, e.y) * 180.0 / math.pi;
      final pitch =
          math.atan2(e.z, math.sqrt(e.x * e.x + e.y * e.y)) * 180.0 / math.pi;
      if (!mounted) return;
      // Light smoothing to stop the readout jittering.
      setState(() {
        _rollDeg = _rollDeg * 0.7 + roll * 0.3;
        _pitchDeg = _pitchDeg * 0.7 + pitch * 0.3;
      });
    });
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
        _minZoom = await controller.getMinZoomLevel();
        _maxZoom = await controller.getMaxZoomLevel();
        _zoom = _zoom.clamp(_minZoom, _maxZoom);
      } catch (_) {}
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
    _accelSub?.cancel();
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
      if (_exposureLocked) {
        await c.setExposureMode(ExposureMode.auto);
        _exposureLocked = false;
      }
      await c.setExposureOffset(v);
    } catch (_) {}
  }

  Future<void> _toggleExposureLock() async {
    final c = _controller;
    if (c == null) return;
    try {
      await c.setExposureMode(
          _exposureLocked ? ExposureMode.auto : ExposureMode.locked);
      if (!_exposureLocked) {
        // Re-apply the offset before locking so the bias is what gets held.
        await c.setExposureOffset(_exposureOffset);
      }
      if (mounted) setState(() => _exposureLocked = !_exposureLocked);
    } catch (_) {}
  }

  Future<void> _setZoom(double v) async {
    final c = _controller;
    setState(() => _zoom = v);
    if (c == null) return;
    try {
      await c.setZoomLevel(v);
    } catch (_) {}
  }

  /// Post-capture exposure QC: the back-light must not clip (blooming eats
  /// the sub-pixel edge) and the silhouette must be genuinely dark.
  /// Returns null when the frame looks good, else a human-readable warning.
  static String? _exposureQc(img.Image im) {
    // Sample on a stride — statistics, not per-pixel work.
    final g = img.grayscale(im);
    int n = 0, clipped = 0;
    final hist = List<int>.filled(256, 0);
    final strideX = math.max(1, g.width ~/ 500);
    final strideY = math.max(1, g.height ~/ 500);
    for (int y = 0; y < g.height; y += strideY) {
      for (int x = 0; x < g.width; x += strideX) {
        final v = g.getPixel(x, y).r.toInt();
        hist[v]++;
        if (v >= 252) clipped++;
        n++;
      }
    }
    if (n == 0) return null;
    int acc = 0, p5 = 0, p95 = 255;
    for (int v = 0; v < 256; v++) {
      acc += hist[v];
      if (acc >= n * 0.05) {
        p5 = v;
        break;
      }
    }
    acc = 0;
    for (int v = 255; v >= 0; v--) {
      acc += hist[v];
      if (acc >= n * 0.05) {
        p95 = v;
        break;
      }
    }
    final clippedFrac = clipped / n;
    if (clippedFrac > 0.02) {
      return 'Back-light is clipping (${(clippedFrac * 100).toStringAsFixed(1)}% '
          'pure-white pixels) — blooming destroys the sub-pixel edge. '
          'Lower the exposure and retake.';
    }
    if (p95 - p5 < 70) {
      return 'Low silhouette contrast (p95−p5 = ${p95 - p5} grey levels). '
          'Check the back-light and that the drop is a dark silhouette.';
    }
    return null;
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

      // Exposure QC before handing the frame to analysis.
      String? warning;
      try {
        final decoded = img.decodeImage(await File(dest).readAsBytes());
        if (decoded != null) warning = _exposureQc(decoded);
      } catch (_) {}

      if (!mounted) return;
      if (warning != null) {
        final useAnyway = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: const Color(0xFF16283E),
            title: const Row(
              children: [
                Icon(Icons.warning_amber_rounded, color: Colors.amberAccent),
                SizedBox(width: 8),
                Expanded(
                  child: Text('Exposure check',
                      style: TextStyle(color: Colors.white, fontSize: 17)),
                ),
              ],
            ),
            content: Text(warning!,
                style: const TextStyle(color: Colors.white70, height: 1.4)),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('Retake'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('Use anyway'),
              ),
            ],
          ),
        );
        if (!mounted) return;
        if (useAnyway != true) {
          setState(() => _busy = false);
          return; // stay on the camera for the retake
        }
      }
      Navigator.of(context).pop(File(dest));
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = 'Capture failed: $e';
        });
      }
    }
  }

  bool get _levelOk => _rollDeg.abs() <= 0.5;
  bool get _pitchOk => _pitchDeg >= -0.5 && _pitchDeg <= 4.0;

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
                    onVerticalDragUpdate: (d) {
                      setState(() {
                        _guideY = (_guideY + d.delta.dy / box.maxHeight)
                            .clamp(0.15, 0.95);
                      });
                    },
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        CameraPreview(c),
                        CustomPaint(
                          painter: _GuidePainter(
                              guideY: _guideY, rollDeg: _rollDeg),
                        ),
                        _levelBadge(),
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

  /// Live attitude badge: roll (baseline leveling, target 0°) and pitch
  /// (optical axis, ISO 19403-2 recommends 0–4° downward).
  Widget _levelBadge() {
    final rollColor = _levelOk
        ? Colors.greenAccent
        : (_rollDeg.abs() <= 2.0 ? Colors.amberAccent : Colors.redAccent);
    final pitchColor = _pitchOk ? Colors.greenAccent : Colors.amberAccent;
    return Positioned(
      top: 8,
      left: 8,
      right: 8,
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.55),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  _levelOk && _pitchOk
                      ? Icons.check_circle
                      : Icons.screen_rotation_alt,
                  size: 15,
                  color: _levelOk && _pitchOk
                      ? Colors.greenAccent
                      : Colors.white70,
                ),
                const SizedBox(width: 8),
                Text('Level ${_rollDeg.abs().toStringAsFixed(1)}°',
                    style: TextStyle(color: rollColor, fontSize: 12)),
                const SizedBox(width: 12),
                Text(
                    'Pitch ${_pitchDeg.toStringAsFixed(1)}°'
                    '${_pitchDeg >= 0 ? '↓' : '↑'}',
                    style: TextStyle(color: pitchColor, fontSize: 12)),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.4),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Text(
              'Drag to move the baseline guide • tap the drop to lock focus • '
              'zoom from a distance instead of moving closer',
              style: TextStyle(color: Colors.white70, fontSize: 10.5),
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }

  Widget _controls() {
    final hasExposure = !(_minExposure == 0 && _maxExposure == 0);
    final hasZoom = _maxZoom > _minZoom + 0.01;
    return Container(
      color: Colors.black,
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              const Icon(Icons.brightness_6, color: Colors.white70, size: 17),
              Expanded(
                child: Slider(
                  value: _exposureOffset.clamp(
                      hasExposure ? _minExposure : -1.0,
                      hasExposure ? _maxExposure : 1.0),
                  min: hasExposure ? _minExposure : -1.0,
                  max: hasExposure ? _maxExposure : 1.0,
                  onChanged: hasExposure ? _setExposure : null,
                ),
              ),
              SizedBox(
                width: 44,
                child: Text('${_exposureOffset.toStringAsFixed(1)} EV',
                    style:
                        const TextStyle(color: Colors.white70, fontSize: 11)),
              ),
              IconButton(
                tooltip: _exposureLocked ? 'Unlock exposure' : 'Lock exposure',
                onPressed: hasExposure ? _toggleExposureLock : null,
                icon: Icon(
                  _exposureLocked ? Icons.lock : Icons.lock_open,
                  size: 18,
                  color:
                      _exposureLocked ? Colors.tealAccent : Colors.white54,
                ),
              ),
            ],
          ),
          if (hasZoom)
            Row(
              children: [
                const Icon(Icons.zoom_in, color: Colors.white70, size: 17),
                Expanded(
                  child: Slider(
                    value: _zoom.clamp(_minZoom, _maxZoom),
                    min: _minZoom,
                    max: math.min(_maxZoom, 10.0),
                    onChanged: _setZoom,
                  ),
                ),
                SizedBox(
                  width: 44,
                  child: Text('${_zoom.toStringAsFixed(1)}×',
                      style:
                          const TextStyle(color: Colors.white70, fontSize: 11)),
                ),
                const SizedBox(width: 40),
              ],
            ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              SizedBox(
                width: 96,
                child: Text(
                  _focusLocked ? 'Focus locked' : 'Tap drop to lock focus',
                  style: TextStyle(
                      color:
                          _focusLocked ? Colors.tealAccent : Colors.white54,
                      fontSize: 11.5),
                ),
              ),
              GestureDetector(
                onTap: _busy ? null : _capture,
                child: Container(
                  width: 66,
                  height: 66,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _busy ? Colors.grey : Colors.white,
                    border: Border.all(
                      color: _levelOk && _pitchOk
                          ? Colors.greenAccent
                          : Colors.tealAccent,
                      width: 4,
                    ),
                  ),
                  child: _busy
                      ? const Padding(
                          padding: EdgeInsets.all(17),
                          child: CircularProgressIndicator(strokeWidth: 3))
                      : const Icon(Icons.camera_alt, color: Colors.black),
                ),
              ),
              SizedBox(
                width: 96,
                child: Text(
                  _exposureLocked ? 'Exposure locked' : '',
                  textAlign: TextAlign.right,
                  style: const TextStyle(
                      color: Colors.tealAccent, fontSize: 11.5),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Alignment overlay: a DRAGGABLE horizontal baseline guide (align with the
/// drop's contact line), a horizon line rotated by the live device roll (when
/// the two coincide the phone is level), a centering vertical and a
/// rule-of-thirds grid.
class _GuidePainter extends CustomPainter {
  final double guideY;
  final double rollDeg;
  _GuidePainter({required this.guideY, required this.rollDeg});

  @override
  void paint(Canvas canvas, Size size) {
    final grid = Paint()
      ..color = Colors.white.withValues(alpha: 0.15)
      ..strokeWidth = 1;
    for (int i = 1; i < 3; i++) {
      final dx = size.width * i / 3;
      final dy = size.height * i / 3;
      canvas.drawLine(Offset(dx, 0), Offset(dx, size.height), grid);
      canvas.drawLine(Offset(0, dy), Offset(size.width, dy), grid);
    }
    // Baseline guide — drag to the drop's contact line.
    final by = size.height * guideY;
    final base = Paint()
      ..color = Colors.tealAccent.withValues(alpha: 0.85)
      ..strokeWidth = 2;
    canvas.drawLine(Offset(0, by), Offset(size.width, by), base);
    // Guide handle ticks.
    for (final x in [size.width * 0.06, size.width * 0.94]) {
      canvas.drawLine(Offset(x, by - 7), Offset(x, by + 7), base);
    }
    // Live horizon (rotated by device roll) around the guide's midpoint:
    // when it lies on the guide line, the phone is level.
    final level = rollDeg.abs() <= 0.5;
    final horizon = Paint()
      ..color = (level ? Colors.greenAccent : Colors.amberAccent)
          .withValues(alpha: 0.8)
      ..strokeWidth = 1.4;
    final cx = size.width / 2;
    final halfW = size.width * 0.28;
    final slope = math.tan(rollDeg * math.pi / 180.0);
    canvas.drawLine(
      Offset(cx - halfW, by + halfW * slope),
      Offset(cx + halfW, by - halfW * slope),
      horizon,
    );
    // Center vertical.
    canvas.drawLine(Offset(cx, 0), Offset(cx, size.height),
        Paint()..color = Colors.white.withValues(alpha: 0.22));
  }

  @override
  bool shouldRepaint(covariant _GuidePainter old) =>
      old.guideY != guideY || old.rollDeg != rollDeg;
}
