// lib/capture/usb_capture.dart
import 'dart:io';
import 'dart:developer' as developer;

/// Mode A — Remote Trigger Capture via ADB.
///
/// Triggers photo capture on a USB-connected phone, waits for the new image,
/// pulls it to local storage, and optionally cleans up device storage.
/// Supports multiple connected devices via serial number.
class UsbCapture {
  /// Default device DCIM path where camera saves photos.
  final String deviceDcimPath;

  /// Max retries for capture + pull.
  final int maxRetries;

  /// Timeout waiting for new image on device.
  final Duration captureTimeout;

  UsbCapture({
    this.deviceDcimPath = '/sdcard/DCIM/Camera',
    this.maxRetries = 3,
    this.captureTimeout = const Duration(seconds: 15),
  });

  static void _log(String msg) {
    developer.log(msg, name: 'UsbCapture');
  }

  /// List connected ADB device serial numbers.
  Future<List<String>> listDevices() async {
    try {
      final result = await Process.run('adb', ['devices']);
      final lines = (result.stdout as String)
          .split('\n')
          .where((l) => l.contains('\tdevice'))
          .map((l) => l.split('\t').first.trim())
          .where((s) => s.isNotEmpty)
          .toList();
      _log('Found ${lines.length} ADB device(s): $lines');
      return lines;
    } catch (e) {
      _log('ADB not available: $e');
      return [];
    }
  }

  /// Check if ADB is available on this system.
  Future<bool> isAvailable() async {
    try {
      final result = await Process.run('adb', ['version']);
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  /// List files currently in device DCIM directory.
  Future<List<String>> _listDeviceFiles({String? serial}) async {
    final args = <String>[
      if (serial != null) ...['-s', serial],
      'shell',
      'ls',
      '-t',
      deviceDcimPath,
    ];
    try {
      final result = await Process.run('adb', args);
      if (result.exitCode != 0) return [];
      return (result.stdout as String)
          .split('\n')
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty && (l.endsWith('.jpg') || l.endsWith('.jpeg') || l.endsWith('.png')))
          .toList();
    } catch (e) {
      _log('Failed to list device files: $e');
      return [];
    }
  }

  /// Trigger a camera capture on the connected device.
  Future<bool> _triggerCapture({String? serial}) async {
    final args = <String>[
      if (serial != null) ...['-s', serial],
      'shell',
      'input',
      'keyevent',
      'KEYCODE_CAMERA',
    ];
    try {
      final result = await Process.run('adb', args);
      return result.exitCode == 0;
    } catch (e) {
      _log('Failed to trigger capture: $e');
      return false;
    }
  }

  /// Pull a file from the device to a local directory.
  Future<File?> _pullFile(
    String deviceFilePath,
    String localDir, {
    String? serial,
  }) async {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final ext = deviceFilePath.split('.').last;
    final localPath = '$localDir/usb_capture_$timestamp.$ext';
    final args = <String>[
      if (serial != null) ...['-s', serial],
      'pull',
      deviceFilePath,
      localPath,
    ];
    try {
      final result = await Process.run('adb', args);
      if (result.exitCode == 0 && File(localPath).existsSync()) {
        _log('Pulled image to: $localPath');
        return File(localPath);
      }
    } catch (e) {
      _log('Failed to pull file: $e');
    }
    return null;
  }

  /// Delete a file from the device.
  Future<void> cleanupDevice(String deviceFilePath, {String? serial}) async {
    final args = <String>[
      if (serial != null) ...['-s', serial],
      'shell',
      'rm',
      deviceFilePath,
    ];
    try {
      await Process.run('adb', args);
      _log('Cleaned up device file: $deviceFilePath');
    } catch (e) {
      _log('Failed to cleanup: $e');
    }
  }

  /// Full capture flow: trigger → wait → pull → return local file.
  ///
  /// Returns a map with:
  /// - 'file': the local [File]
  /// - 'latency_ms': time from trigger to file ready
  /// - 'device_path': path on device
  Future<Map<String, dynamic>> capture({
    required String localDir,
    String? serial,
    bool cleanup = false,
  }) async {
    final stopwatch = Stopwatch()..start();
    Exception? lastError;

    for (int attempt = 0; attempt < maxRetries; attempt++) {
      try {
        _log('Capture attempt ${attempt + 1}/$maxRetries');

        // Snapshot current files before capture
        final beforeFiles = await _listDeviceFiles(serial: serial);

        // Trigger capture
        final triggered = await _triggerCapture(serial: serial);
        if (!triggered) {
          throw Exception('Failed to trigger camera');
        }

        // Wait for a new file to appear
        String? newFile;
        final deadline = DateTime.now().add(captureTimeout);
        while (DateTime.now().isBefore(deadline)) {
          await Future.delayed(const Duration(milliseconds: 500));
          final afterFiles = await _listDeviceFiles(serial: serial);
          final diff = afterFiles.where((f) => !beforeFiles.contains(f)).toList();
          if (diff.isNotEmpty) {
            newFile = diff.first;
            break;
          }
        }

        if (newFile == null) {
          throw Exception('Timed out waiting for new image');
        }

        final devicePath = '$deviceDcimPath/$newFile';
        _log('New image detected: $devicePath');

        // Pull to local
        final localFile = await _pullFile(devicePath, localDir, serial: serial);
        if (localFile == null) {
          throw Exception('Failed to pull image from device');
        }

        stopwatch.stop();
        final latencyMs = stopwatch.elapsedMilliseconds;
        _log('Capture complete in ${latencyMs}ms');

        if (cleanup) {
          await cleanupDevice(devicePath, serial: serial);
        }

        return {
          'file': localFile,
          'latency_ms': latencyMs,
          'device_path': devicePath,
          'attempt': attempt + 1,
        };
      } catch (e) {
        lastError = e is Exception ? e : Exception(e.toString());
        _log('Attempt ${attempt + 1} failed: $e');
      }
    }

    throw lastError ?? Exception('All capture attempts failed');
  }
}
