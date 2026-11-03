import 'package:correlia_flutter/placeholder_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shows the product name and that the console comes in M2', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: PlaceholderPage()));

    expect(find.text('Correlia'), findsOneWidget);
    expect(find.textContaining('console coming in M2'), findsOneWidget);
  });
}
