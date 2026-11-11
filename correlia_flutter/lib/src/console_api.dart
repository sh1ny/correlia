import 'package:correlia_client/correlia_client.dart';

/// The snapshot, durable feed and wake-up boundary of the console.
abstract interface class ConsoleApi {
  Future<AlertSnapshot> snapshot();
  Future<FeedPage> feed(String cursor, int limit);
  Stream<FeedWakeUp> wakeUps();
}

/// Adapts the generated HTTP and WebSocket client to the console controller.
final class ServerConsoleApi implements ConsoleApi {
  const ServerConsoleApi(this.client);
  final Client client;

  @override
  Future<AlertSnapshot> snapshot() => client.alertConsole.snapshot();
  @override
  Future<FeedPage> feed(String cursor, int limit) =>
      client.alertConsole.feed(cursor, limit);
  @override
  Stream<FeedWakeUp> wakeUps() => client.alertConsole.wakeUps();
}
