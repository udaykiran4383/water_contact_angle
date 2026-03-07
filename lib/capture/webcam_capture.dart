// lib/capture/webcam_capture.dart
import 'dart:io';
import 'dart:developer' as developer;

/// Mode B — Webcam/UVC Capture.
///
/// Enumerates available camera devices (including phones exposed as webcams),
/// captures a frame, and auto-prefers external cameras when present.
class WebcamCapture {
  static void _log(String msg) {
    developer.log(msg, name: 'WebcamCapture');
  }

  /// Check if there are any accessible video devices (Linux/macOS).
  Future<bool> isAvailable() async {
    if (Platform.isLinux) {
      final devices = await enumerateDevices();
      return devices.isNotEmpty;
    }
    if (Platform.isMacOS) {
      try {
        final result = await Process.run(
          'system_profiler',
          ['SPCameraDataType'],
        );
        return result.exitCode == 0 &&
            (result.stdout as String).contains('Camera');
      } catch (_) {
        return false;
      }
    }
    // Android/iOS: use the camera plugin directly
    return Platform.isAndroid || Platform.isIOS;
  }

  /// Enumerate available video device indices.
  ///
  /// Returns list of maps with:
  /// - 'index': device index (int)
  /// - 'name': device name or path (String)
  /// - 'is_external': true if likely an external/USB camera (bool)
  Future<List<Map<String, dynamic>>> enumerateDevices() async {
    final devices = <Map<String, dynamic>>[];

    if (Platform.isLinux) {
      for (int i = 0; i < 10; i++) {
        final dev = File('/dev/video$i');
        if (dev.existsSync()) {
          // Try to read device name from sysfs
          String name = 'video$i';
          bool isExternal = false;
          try {
            final nameFile = File('/sys/class/video4linux/video$i/name');
            if (nameFile.existsSync()) {
              name = nameFile.readAsStringSync().trim();
            }
            // Check USB path in sysfs to determine if external
            final devLink = Link('/sys/class/video4linux/video$i');
            if (devLink.existsSync()) {
              final resolved = devLink.resolveSymbolicLinksSync();
              isExternal = resolved.contains('/usb');
            }
          } catch (_) {}
          // Fallback: index > 0 is heuristically more likely external
          if (!isExternal && i > 0) isExternal = true;
          devices.add({
            'index': i,
            'name': name,
            'is_external': isExternal,
          });
        }
      }
    } else if (Platform.isMacOS) {
      try {
        // Use ffmpeg to list AVFoundation devices — more reliable than system_profiler
        final result = await Process.run(
          'ffmpeg',
          ['-f', 'avfoundation', '-list_devices', 'true', '-i', ''],
          // ffmpeg writes device list to stderr with exit code 1
        );
        final output = (result.stderr as String?) ?? '';
        // Parse lines like "[AVFoundation indev @ 0x...] [0] FaceTime HD Camera"
        final regex = RegExp(r'\[(\d+)\]\s+(.+)');
        bool inVideoSection = true;
        int index = 0;
        for (final line in output.split('\n')) {
          // Stop at audio devices section
          if (line.contains('AVFoundation audio devices')) {
            inVideoSection = false;
          }
          if (!inVideoSection) continue;

          final match = regex.firstMatch(line);
          if (match != null) {
            final name = match.group(2)!.trim();
            // Detect external cameras by name patterns
            final nameLower = name.toLowerCase();
            final isExternal = nameLower.contains('usb') ||
                nameLower.contains('external') ||
                nameLower.contains('logitech') ||
                nameLower.contains('elgato') ||
                nameLower.contains('obs') ||
                nameLower.contains('droidcam') ||
                nameLower.contains('iriun') ||
                nameLower.contains('epoccam') ||
                nameLower.contains('camo') ||
                // Phones as webcam typically don't have "facetime" or "built-in"
                (!nameLower.contains('facetime') &&
                    !nameLower.contains('built-in') &&
                    index > 0);
            devices.add({
              'index': index,
              'name': name,
              'is_external': isExternal,
            });
            index++;
          }
        }

        // Fallback to system_profiler if ffmpeg didn't find anything
        if (devices.isEmpty) {
          final profResult = await Process.run(
            'system_profiler',
            ['SPCameraDataType'],
          );
          if (profResult.exitCode == 0) {
            final profOutput = profResult.stdout as String;
            int profIndex = 0;
            for (final line in profOutput.split('\n')) {
              final trimmed = line.trim();
              if (trimmed.isNotEmpty &&
                  !trimmed.startsWith('Camera') &&
                  trimmed.endsWith(':') &&
                  !trimmed.contains('Data Type')) {
                final name = trimmed.replaceAll(':', '').trim();
                final nameLower = name.toLowerCase();
                devices.add({
                  'index': profIndex,
                  'name': name,
                  'is_external': !nameLower.contains('facetime') &&
                      !nameLower.contains('built-in'),
                });
                profIndex++;
              }
            }
          }
        }
      } catch (e) {
        _log('Failed to enumerate macOS cameras: $e');
      }
    }

    _log('Found ${devices.length} video device(s): '
        '${devices.map((d) => '${d['name']}${d['is_external'] ? ' [EXT]' : ''}').join(', ')}');
    return devices;
  }

  /// Auto-select the best camera, preferring external/USB cameras.
  Future<int> autoSelectExternal() async {
    final devices = await enumerateDevices();
    if (devices.isEmpty) return 0;

    // Prefer external cameras
    for (final dev in devices) {
      if (dev['is_external'] == true) {
        _log('Auto-selected external camera: ${dev['name']} (index ${dev['index']})');
        return dev['index'] as int;
      }
    }

    // Fall back to first available
    _log('No external camera found, using default: ${devices.first['name']}');
    return devices.first['index'] as int;
  }

  /// Capture a single frame from the specified camera device.
  ///
  /// Uses ffmpeg to grab one frame from the video device.
  /// Returns the captured image file.
  Future<File?> captureFrame({
    int deviceIndex = 0,
    required String outputDir,
  }) async {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final outputPath = '$outputDir/webcam_$timestamp.jpg';

    try {
      List<String> args;

      if (Platform.isLinux) {
        final inputDevice = '/dev/video$deviceIndex';
        args = [
          '-y',
          '-f', 'v4l2',
          '-i', inputDevice,
          '-frames:v', '1',
          '-q:v', '2',
          outputPath,
        ];
      } else if (Platform.isMacOS) {
        args = [
          '-y',
          '-f', 'avfoundation',
          '-framerate', '30',
          '-i', '$deviceIndex:none',
          '-frames:v', '1',
          '-q:v', '2',
          outputPath,
        ];
      } else {
        _log('Webcam capture not supported on ${Platform.operatingSystem}');
        return null;
      }

      _log('Capturing from device $deviceIndex...');
      final result = await Process.run('ffmpeg', args);
      if (result.exitCode == 0 && File(outputPath).existsSync()) {
        _log('Captured frame to: $outputPath');
        return File(outputPath);
      } else {
        _log('ffmpeg failed (exit=${result.exitCode}): ${result.stderr}');
        return null;
      }
    } catch (e) {
      _log('Webcam capture failed: $e');
      return null;
    }
  }
}
