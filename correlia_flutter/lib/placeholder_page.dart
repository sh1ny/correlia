import 'package:flutter/material.dart';

/// The only page of the console until it is built in milestone M2.
class PlaceholderPage extends StatelessWidget {
  /// Creates the placeholder page.
  const PlaceholderPage({super.key});

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Correlia', style: textTheme.displayMedium),
            const SizedBox(height: 8),
            Text(
              'The operator console: console coming in M2.',
              style: textTheme.bodyLarge,
            ),
          ],
        ),
      ),
    );
  }
}
