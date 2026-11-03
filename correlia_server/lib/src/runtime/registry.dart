import 'subsystem.dart';

/// Every subsystem Correlia has, in start order.
///
/// Each subsystem is one entry; the role decides which of them run. The
/// console (`api`, `all`) is added here by the console group, background
/// subsystems (`worker`, `all`) by later changes.
List<Subsystem> buildSubsystemRegistry() => const <Subsystem>[];
