import 'dart:typed_data';

import 'package:correlia_server/src/secrets/secret_store.dart';
import 'package:serverpod/serverpod.dart';

final testSecretStore = SecretStore(Uint8List(32));

SecretResolver testSecretResolver(Session session) => SecretResolver(
  store: testSecretStore,
  openSession: () => session.serverpod.createSession(enableLogging: false),
  log: (_) {},
);

Future<void> seedSigningSecret(Session session, String ref, Uint8List key) =>
    session.db.transaction(
      (tx) => testSecretStore.insert(
        session,
        tx,
        ref,
        key,
        plugin: false,
      ),
    );

Never noSigningKey(String reference, String commitment) =>
    throw StateError('Unexpected signing-key lookup: $reference');
