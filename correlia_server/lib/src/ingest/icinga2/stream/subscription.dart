/// The state-bearing event types requested by every Event Streams source.
///
/// Deliberately excludes `CheckResult`: consume state changes and use sync
/// for the current result, rather than ingesting every check.
const streamTypes = [
  'StateChange',
  'AcknowledgementSet',
  'AcknowledgementCleared',
  'DowntimeStarted',
  'DowntimeRemoved',
  'Flapping',
];
