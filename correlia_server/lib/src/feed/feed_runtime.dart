import '../runtime/process_options.dart';
import 'feed_watermark_subsystem.dart';

/// Process-scoped console configuration shared by generated endpoint instances.
abstract final class FeedRuntime {
  /// The process role, defaulting to denied until startup configures it.
  static ProcessRole role = ProcessRole.worker;

  /// The API instance's poller, absent in a worker process.
  static FeedWatermarkSubsystem? watermark;
}
