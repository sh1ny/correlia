import 'subsystem.dart';

/// Every subsystem Correlia has, in start order.
///
/// Each subsystem is one entry; the role decides which of them run. The
/// background subsystems (`worker`, `all`) are added here by later changes.
/// The console needs the run mode and environment, so `server.dart` adds it.
List<Subsystem> buildSubsystemRegistry() => const <Subsystem>[];
