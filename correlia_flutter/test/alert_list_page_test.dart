import 'package:correlia_client/correlia_client.dart';
import 'package:correlia_flutter/src/alert_feed_controller.dart';
import 'package:correlia_flutter/src/alert_list_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:url_launcher/link.dart';

import 'console_fakes.dart';

void main() {
  late FakeConsoleApi api;
  late FakeTimers timers;
  late AlertFeedController controller;
  setUp(() {
    api = FakeConsoleApi();
    timers = FakeTimers();
    controller = AlertFeedController(
      api: api,
      clock: () => testNow,
      timerFactory: timers.create,
    );
  });
  tearDown(() async {
    controller.dispose();
    await api.close();
  });
  Future<void> show(WidgetTester tester) async {
    await controller.start();
    await tester.pumpWidget(
      MaterialApp(home: AlertListPage(controller: controller)),
    );
  }

  testWidgets('new_alert_appears_live', (tester) async {
    await show(tester);
    api.pages.add(page([alertView(1)]));
    api.streams.single.add(FeedWakeUp());
    await tester.pump();
    expect(find.text('Disk full'), findsOneWidget);
    expect(find.textContaining('monitor-a'), findsWidgets);
    expect(find.textContaining('1h'), findsWidgets);
  });
  testWidgets('resolved_alert_leaves_the_list', (tester) async {
    api.initial = AlertSnapshot(
      alerts: [alertView(1)],
      omittedCount: 0,
      cursor: 'v1.1.0',
    );
    await show(tester);
    api.pages.add(page([alertView(1, version: 2, status: 'resolved')]));
    await controller.pull();
    await tester.pump();
    expect(find.text('Disk full'), findsNothing);
    expect(find.text('No firing alerts'), findsOneWidget);
  });
  testWidgets('snapshot_bound_exceeded', (tester) async {
    api.initial = AlertSnapshot(
      alerts: [alertView(1)],
      omittedCount: 1,
      cursor: 'v1.1.0',
    );
    await show(tester);
    expect(find.textContaining('1 not shown'), findsOneWidget);
  });
  testWidgets('filter_narrows_the_list', (tester) async {
    api.initial = AlertSnapshot(
      alerts: [
        alertView(1),
        alertView(2, summary: 'CPU high'),
      ],
      omittedCount: 0,
      cursor: 'v1.1.0',
    );
    await show(tester);
    await tester.enterText(find.byType(TextField), 'disk');
    await tester.pump();
    expect(find.text('Disk full'), findsOneWidget);
    expect(find.text('CPU high'), findsNothing);
    api.pages.add(page([alertView(2, version: 2, summary: 'CPU very high')]));
    await controller.pull();
    await tester.pump();
    expect(find.text('CPU very high'), findsNothing);
  });
  testWidgets('filter_matches_nothing', (tester) async {
    api.initial = AlertSnapshot(
      alerts: [alertView(1)],
      omittedCount: 0,
      cursor: 'v1.1.0',
    );
    await show(tester);
    await tester.enterText(find.byType(TextField), 'unmatched');
    await tester.pump();
    expect(find.text('No alerts match'), findsOneWidget);
    expect(find.text('Disk full'), findsNothing);
  });
  testWidgets('generator_link_and_selectable_text', (tester) async {
    api.initial = AlertSnapshot(
      alerts: [
        alertView(1, generatorUrl: 'https://monitor.example/alert'),
        alertView(2, summary: 'CPU high'),
      ],
      omittedCount: 0,
      cursor: 'v1.1.0',
    );
    await show(tester);
    expect(find.byType(SelectionArea), findsOneWidget);
    final link = tester.widget<Link>(find.byType(Link));
    expect(link.uri, Uri.parse('https://monitor.example/alert'));
    expect(link.target, LinkTarget.blank);
    final semantics = tester.ensureSemantics();
    expect(
      find.bySemanticsLabel('warning: Disk full; source monitor-a'),
      findsOneWidget,
    );
    semantics.dispose();
  });
  testWidgets('server_restart_shows_disconnected_then_resumes', (tester) async {
    api.initial = AlertSnapshot(
      alerts: [alertView(1)],
      omittedCount: 0,
      cursor: 'v1.1.0',
    );
    await show(tester);
    api.failure = StateError('offline');
    await controller.pull();
    await tester.pump();
    expect(find.textContaining('Disconnected'), findsOneWidget);
    expect(find.text('Disk full'), findsOneWidget);
    api.failure = null;
    api.pages.add(
      page([
        alertView(1, version: 2, status: 'resolved'),
        alertView(2, summary: 'CPU high'),
      ], cursor: 'v1.4.2'),
    );
    timers.timers.last.fire();
    await tester.pumpAndSettle();
    expect(find.textContaining('Disconnected'), findsNothing);
    expect(find.text('Disk full'), findsNothing);
    expect(find.text('CPU high'), findsOneWidget);
    expect(api.cursors.last, 'v1.1.0');
  });
}
