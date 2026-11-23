import 'dart:convert';

import 'package:serverpod/serverpod.dart';

import '../../../secrets/secret_store.dart';
import '../../bootstrap.dart';
import '../../config_repository.dart';
import 'supervisor.dart';

/// Resolves secrets only for enabled stream sources in the active revision.
final class StreamTargetLoader {
  StreamTargetLoader(this._pod, this._resolver);

  final Serverpod _pod;
  final SecretResolver _resolver;
  String? _snapshot;
  List<StreamTarget> _cached = const [];

  Future<List<StreamTarget>> load() async {
    final session = await _pod.createSession(enableLogging: false);
    try {
      final active = await IngestConfigRepository(session).activeSnapshot();
      if (active == null) {
        _snapshot = null;
        return _cached = const [];
      }
      final snapshot = active['snapshotId']! as String;
      if (snapshot == _snapshot) return _cached;
      final document =
          jsonDecode(active['publicJson']! as String) as Map<String, Object?>;
      final targets = <StreamTarget>[];
      for (final source in document['sources']! as List<Object?>) {
        if (source case {
          'enabled': true,
          'mode': 'event_streams',
          'id': final String id,
          'namespace': final String namespace,
          'excluded_identity_labels': final List<Object?> labels,
          'state_type_policy': final String policy,
          'max_pending_rows': final int maxPending,
          'api': {
            'url': final String url,
            'username': final String username,
            'password_ref': final String passwordRef,
            'ca_ref': final String caRef,
            'sync_interval_seconds': final int interval,
          },
        }) {
          final commitments = await session.db.unsafeQuery(
            'SELECT reference,commitment FROM secret_record WHERE reference IN (@password,@ca)',
            parameters: QueryParameters.named({
              'password': passwordRef,
              'ca': caRef,
            }),
          );
          final pins = {
            for (final row in commitments) row[0]! as String: row[1]! as String,
          };
          targets.add(
            StreamTarget(
              sourceId: id,
              snapshotId: snapshot,
              namespace: namespace,
              excludedLabels: labels.cast<String>(),
              password: await _resolver.resolve(
                passwordRef,
                pins[passwordRef]!,
              ),
              ca: await _resolver.resolve(caRef, pins[caRef]!),
              options: IcingaStreamOptions(
                url: Uri.parse(url),
                username: username,
                passwordRef: passwordRef,
                caRef: caRef,
                syncInterval: Duration(seconds: interval),
                stateTypePolicy: StreamStateTypePolicy.values.firstWhere(
                  (value) => value.wire == policy,
                ),
                maxPendingRows: maxPending,
              ),
            ),
          );
        }
      }
      _snapshot = snapshot;
      return _cached = targets;
    } finally {
      await session.close();
    }
  }
}
