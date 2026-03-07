// lib/capture/capture_manager.dart
import 'dart:io';
import 'dart:developer' as developer;

import 'usb_capture.dart';
import 'webcam_capture.dart';

/// Available capture modes, in automatic-selection priority order.
enum CaptureMode {
  /// Phone exposed as webcam via USB.
  webcamUVC,

  /// ADB remote trigger via USB.
  usbRemote,

  /// Local device camera (ImagePicker).
  localCamera,

  /// Pick from gallery.
  gallery,
}

/// Result of a capture operation.
class CaptureResult {
  final File file;
  final CaptureMode modeUsed;
  final int latencyMs;
  final Map<String, dynamic> metadata;

  CaptureResult({
    required this.file,
    required this.modeUsed,
    required this.latencyMs,
    this.metadata = const {},
  });
}

/// Central capture controller that auto-selects the best available pipeline.
///
/// Priority:
/// 1) Webcam/UVC available → use it
/// 2) USB device available (ADB) → use remote trigger
/// 3) Else → fallback to local capture (handled by caller)
class CaptureManager {
  final UsbCapture _usbCapture;
  final WebcamCapture _webcamCapture;

  CaptureManager({
    UsbCapture? usbCapture,
    WebcamCapture? webcamCapture,
  })  : _usbCapture = usbCapture ?? UsbCapture(),
        _webcamCapture = webcamCapture ?? WebcamCapture();

  static void _log(String msg) {
    developer.log(msg, name: 'CaptureManager');
  }

  /// Detect which capture modes are currently available.
  Future<List<CaptureMode>> detectAvailableModes() async {
    final modes = <CaptureMode>[];

    // Check webcam
    try {
      final webcamAvailable = await _webcamCapture.isAvailable();
      if (webcamAvailable) {
        final devices = await _webcamCapture.enumerateDevices();
        if (devices.isNotEmpty) {
          modes.add(CaptureMode.webcamUVC);
        }
      }
    } catch (e) {
      _log('Webcam detection failed: $e');
    }

    // Check ADB / USB
    try {
      final adbAvailable = await _usbCapture.isAvailable();
      if (adbAvailable) {
        final devices = await _usbCapture.listDevices();
        if (devices.isNotEmpty) {
          modes.add(CaptureMode.usbRemote);
        }
      }
    } catch (e) {
      _log('ADB detection failed: $e');
    }

    // Local camera and gallery are always available as fallbacks
    modes.add(CaptureMode.localCamera);
    modes.add(CaptureMode.gallery);

    _log('Available modes: ${modes.map((m) => m.name).join(', ')}');
    return modes;
  }

  /// Auto-select the best available mode.
  Future<CaptureMode> autoSelectMode() async {
    final modes = await detectAvailableModes();
    return modes.first;
  }

  /// Capture an image using the specified mode (or auto-select).
  ///
  /// For [CaptureMode.localCamera] and [CaptureMode.gallery], this returns
  /// null — the caller should use ImagePicker for those modes.
  Future<CaptureResult?> capture({
    CaptureMode? mode,
    required String outputDir,
    String? usbDeviceSerial,
    bool cleanupDevice = false,
  }) async {
    mode ??= await autoSelectMode();
    _log('Capturing with mode: ${mode.name}');

    switch (mode) {
      case CaptureMode.webcamUVC:
        final webcamResult = await _captureWebcam(outputDir: outputDir);
        if (webcamResult != null) return webcamResult;
        // Fall through to USB if webcam capture failed
        _log('Webcam capture failed, trying USB fallback');
        final usbResult = await _captureUsb(
          outputDir: outputDir,
          serial: usbDeviceSerial,
          cleanup: cleanupDevice,
        );
        if (usbResult != null) return usbResult;
        return null;

      case CaptureMode.usbRemote:
        return _captureUsb(
          outputDir: outputDir,
          serial: usbDeviceSerial,
          cleanup: cleanupDevice,
        );

      case CaptureMode.localCamera:
      case CaptureMode.gallery:
        // These are handled by the caller (ImagePicker in main.dart)
        return null;
    }
  }

  Future<CaptureResult?> _captureWebcam({required String outputDir}) async {
    try {
      final stopwatch = Stopwatch()..start();
      final deviceIndex = await _webcamCapture.autoSelectExternal();
      final file = await _webcamCapture.captureFrame(
        deviceIndex: deviceIndex,
        outputDir: outputDir,
      );
      stopwatch.stop();
      if (file != null) {
        return CaptureResult(
          file: file,
          modeUsed: CaptureMode.webcamUVC,
          latencyMs: stopwatch.elapsedMilliseconds,
          metadata: {'device_index': deviceIndex},
        );
      }
    } catch (e) {
      _log('Webcam capture error: $e');
    }
    return null;
  }

  Future<CaptureResult?> _captureUsb({
    required String outputDir,
    String? serial,
    bool cleanup = false,
  }) async {
    try {
      final result = await _usbCapture.capture(
        localDir: outputDir,
        serial: serial,
        cleanup: cleanup,
      );
      return CaptureResult(
        file: result['file'] as File,
        modeUsed: CaptureMode.usbRemote,
        latencyMs: result['latency_ms'] as int,
        metadata: {
          'device_path': result['device_path'],
          'attempt': result['attempt'],
        },
      );
    } catch (e) {
      _log('USB capture failed: $e');
      return null;
    }
  }

  /// Get the display name for a capture mode.
  static String modeName(CaptureMode mode) {
    switch (mode) {
      case CaptureMode.webcamUVC:
        return 'Webcam/UVC';
      case CaptureMode.usbRemote:
        return 'USB Remote';
      case CaptureMode.localCamera:
        return 'Camera';
      case CaptureMode.gallery:
        return 'Gallery';
    }
  }
}
