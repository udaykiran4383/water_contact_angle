// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:water_contact_angle/main.dart';

void main() {
  testWidgets('App renders HomePage with title', (WidgetTester tester) async {
    // Build app
    await tester.pumpWidget(MyApp());

    // Verify the AppBar title exists
    expect(find.text('Contact Angle Analyzer'), findsOneWidget);

    // Verify the header section text is present
    expect(find.text('Sessile Drop Analysis'), findsOneWidget);
  });
}
