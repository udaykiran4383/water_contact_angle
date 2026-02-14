import 'package:flutter_test/flutter_test.dart';

import 'package:water_contact_angle/main.dart';

void main() {
  testWidgets('renders analyzer home screen', (WidgetTester tester) async {
    await tester.pumpWidget(const MyApp());

    expect(find.text('Contact Angle Analyzer'), findsOneWidget);
    expect(find.text('Sessile Drop Analysis'), findsOneWidget);
    expect(find.text('Gallery'), findsOneWidget);
  });
}
