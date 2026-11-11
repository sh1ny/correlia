import 'package:correlia_server/src/schema/schema_steps.dart';
import 'package:serverpod/serverpod.dart';

/// Initializes schema using a session outside any test rollback transaction.
Future<void> initializeIngestSchema(Session session) =>
    initializeSchema(session);
