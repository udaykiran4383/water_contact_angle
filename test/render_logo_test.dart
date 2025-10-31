import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/rendering.dart';
import 'package:water_contact_angle/assests/logo.dart';

void main() {
  testWidgets('render MEMSLogo to assets/app_icon.png and assets/splash_logo.png', (tester) async {
    const size = 512.0; // square icon
    final repaintKey = GlobalKey();

    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          backgroundColor: const Color(0xFFF8FAFC),
          body: Center(
            child: RepaintBoundary(
              key: repaintKey,
              child: const MEMSLogo(size: size),
            ),
          ),
        ),
      ),
    );

    await tester.pumpAndSettle(const Duration(milliseconds: 100));

    final boundary = repaintKey.currentContext!.findRenderObject() as RenderRepaintBoundary;
    final ui.Image image = await boundary.toImage(pixelRatio: 1.0);
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    final bytes = byteData!.buffer.asUint8List();

    // Ensure assets directory exists
    final assetsDir = Directory('assets');
    if (!assetsDir.existsSync()) {
      assetsDir.createSync(recursive: true);
    }

    final appIconFile = File('assets/app_icon.png');
    final splashLogoFile = File('assets/splash_logo.png');

    await appIconFile.writeAsBytes(bytes);
    await splashLogoFile.writeAsBytes(bytes);

    // Basic assertion to keep test green
    expect(appIconFile.existsSync(), true);
    expect(splashLogoFile.existsSync(), true);
  });
}
