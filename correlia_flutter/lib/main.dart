import 'package:flutter/material.dart';

import 'client.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeClient();
  runApp(const CorreliaApp());
}

/// Builds a theme for the given [brightness].
ThemeData _buildTheme(Brightness brightness) {
  return ThemeData(
    colorScheme: ColorScheme.fromSeed(
      seedColor: Colors.blue,
      brightness: brightness,
    ),
  );
}

/// Root widget of the Correlia operator console.
///
/// A placeholder until the console is built in a later milestone.
class CorreliaApp extends StatelessWidget {
  /// Creates the console root widget.
  const CorreliaApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Correlia',
      theme: _buildTheme(Brightness.light),
      darkTheme: _buildTheme(Brightness.dark),
      themeMode: ThemeMode.system,
      home: const Scaffold(body: Center(child: Text('Correlia'))),
    );
  }
}
