import 'package:flutter_test/flutter_test.dart';
import 'package:pharmazen_mobile_app/app/app.dart';

void main() {
  testWidgets('home screen renders search actions and bottom nav', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const PharmaZenApp());

    expect(find.text('Search'), findsOneWidget);
    expect(find.text('Drug by generic'), findsOneWidget);
    expect(find.text('Drug by category'), findsOneWidget);
    expect(find.text('Drug by Indication'), findsOneWidget);

    expect(find.text('Profile'), findsOneWidget);
    expect(find.text('Cart'), findsOneWidget);
    expect(find.text('Prescription'), findsOneWidget);
    expect(find.text('Favorites'), findsOneWidget);
  });
}