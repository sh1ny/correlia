import 'package:correlia_client/correlia_client.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/link.dart';

import 'alert_feed_controller.dart';

/// The bounded, live firing-alert view of the development console.
final class AlertListPage extends StatefulWidget {
  const AlertListPage({super.key, required this.controller});
  final AlertFeedController controller;

  @override
  State<AlertListPage> createState() => _AlertListPageState();
}

final class _AlertListPageState extends State<AlertListPage> {
  String _filter = '';

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Correlia / Alerts')),
    body: SelectionArea(
      child: ListenableBuilder(
        listenable: widget.controller,
        builder: (context, _) {
          final controller = widget.controller;
          final alerts = controller.alerts;
          final shown = alerts
              .where(
                (alert) =>
                    '${alert.summary} ${alert.sourceInstance} ${alert.severity}'
                        .toLowerCase()
                        .contains(_filter),
              )
              .toList();
          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1440),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Wrap(
                      spacing: 24,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          'Firing alerts',
                          style: Theme.of(context).textTheme.headlineMedium,
                        ),
                        Text('${alerts.length} held'),
                        if (controller.partial)
                          Text(
                            'Partial list · ${controller.omittedCount} not shown',
                          ),
                        Text(
                          controller.disconnected
                              ? 'Disconnected · alerts may be out of date'
                              : 'Live · development only',
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    TextField(
                      decoration: const InputDecoration(
                        labelText: 'Filter alerts',
                        hintText: 'Summary, source or severity',
                        prefixIcon: Icon(Icons.search),
                        border: OutlineInputBorder(),
                      ),
                      onChanged: (value) =>
                          setState(() => _filter = value.toLowerCase()),
                    ),
                    const SizedBox(height: 16),
                    Expanded(
                      child: shown.isEmpty
                          ? Center(
                              child: Text(
                                _filter.isEmpty
                                    ? 'No firing alerts'
                                    : 'No alerts match',
                              ),
                            )
                          : ListView.builder(
                              itemCount: shown.length,
                              itemBuilder: (context, index) => _AlertRow(
                                key: ValueKey(shown[index].id),
                                alert: shown[index],
                                now: controller.clock().toUtc(),
                              ),
                            ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    ),
  );
}

final class _AlertRow extends StatelessWidget {
  const _AlertRow({super.key, required this.alert, required this.now});
  final AlertView alert;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final color = switch (alert.severity) {
      'critical' || 'error' => Theme.of(context).colorScheme.error,
      'warning' => Colors.orange.shade800,
      _ => Theme.of(context).colorScheme.secondary,
    };
    final firingSince = alert.firingSince;
    final generator = alert.generatorUrl;
    return Semantics(
      label:
          '${alert.severity}: ${alert.summary}; source ${alert.sourceInstance}',
      child: Card.outlined(
        margin: const EdgeInsets.only(bottom: 10),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 16,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    alert.severity.toUpperCase(),
                    style: TextStyle(color: color, fontWeight: FontWeight.bold),
                  ),
                  Text(
                    alert.summary,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                'Source ${alert.sourceInstance} · Firing ${firingSince == null ? 'unknown' : _age(now.difference(firingSince))} · Last observed ${alert.lastObservedAt.toUtc().toIso8601String()}',
              ),
              if (generator != null)
                Link(
                  uri: Uri.parse(generator),
                  target: LinkTarget.blank,
                  builder: (context, followLink) => TextButton.icon(
                    onPressed: followLink,
                    icon: const Icon(Icons.open_in_new, size: 16),
                    label: const Text('Open source'),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  String _age(Duration age) {
    if (age.isNegative) return '0s';
    if (age.inDays > 0) return '${age.inDays}d ${age.inHours % 24}h';
    if (age.inHours > 0) return '${age.inHours}h ${age.inMinutes % 60}m';
    if (age.inMinutes > 0) return '${age.inMinutes}m';
    return '${age.inSeconds}s';
  }
}
