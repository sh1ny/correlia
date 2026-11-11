import 'dart:async';

import 'package:flutter/material.dart';

import 'client.dart';
import 'src/alert_feed_controller.dart';
import 'src/alert_list_page.dart';
import 'src/console_api.dart';

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
class CorreliaApp extends StatefulWidget {
  /// Creates the console root widget.
  const CorreliaApp({super.key});

  @override
  State<CorreliaApp> createState() => _CorreliaAppState();
}

class _CorreliaAppState extends State<CorreliaApp> {
  late final AlertFeedController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AlertFeedController(api: ServerConsoleApi(client));
    unawaited(_controller.start());
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Correlia',
    theme: _buildTheme(Brightness.light),
    darkTheme: _buildTheme(Brightness.dark),
    themeMode: ThemeMode.system,
    home: AlertListPage(controller: _controller),
  );
}
