# Alertmanager decoder fixtures

The examples built by `alertmanager_decoder_test.dart` are authored by Correlia
from the documented Alertmanager webhook v4 format. They are not captures from
a real Alertmanager or evidence of an owner's sender configuration.

## Mapping

| Input | Result |
| --- | --- |
| `version`, group `status`, `alerts` | Required; only string version `4` and firing/resolved group status are accepted. One event is emitted for each supplied alert, using its own status. An empty array produces no events. |
| `receiver`, `groupKey`, `groupLabels`, `commonLabels`, `commonAnnotations`, `notification_reason` | Optional, type-checked group metadata retained in the raw delivery; never substituted for alert fields. |
| `externalURL` | Optional group string; a nonempty valid HTTP(S) URL becomes an `alertmanager` link. |
| `truncatedAlerts` | Optional nonnegative integer, default zero; exposed as upstream omissions, never fabricated into events. |
| Alert `labels` | Required string map. Complete originals, after configured exclusions, feed the existing identity codec; severity participates by default. Canonical label values are bounded display projections. |
| Alert `annotations` | Required string map. Bounded projections are retained; nonempty `summary`, then nonempty label `alertname`, then `Alertmanager alert` determines the summary. `description` determines the description. |
| Label `severity` | Exact `critical`, `error`, `warning`, or `info`; otherwise `unknown`. The bounded original is retained when present. |
| `startsAt`, `endsAt` | Offset-bearing source timestamps; the supplied strings are observation-key evidence. Firing uses start as source time and omits a zero end from canonical time; resolved requires a nonzero end and uses it as source time. Reversed nonzero intervals fail. |
| `generatorURL` | Optional string; a nonempty valid HTTP(S) URL becomes a `generator` link. |
| `fingerprint` | Optional bounded string stored as `correlia.io/alertmanager_fingerprint` evidence; never used for identity or `labels_origin`. |
| No upstream equivalent | Source UUID/kind, raw reference/digest/size, observed and processed clocks, and pinned configuration version come from the pipeline. Resource and enrichment stages remain empty; generation is zero. |

All provided recognized fields are type checked. Unknown group or alert fields,
including custom payload fields, fail with a field path instead of being silently
ignored. An additive upstream format change therefore needs a decoder update;
failed raw bytes must be retained for replay. Label and annotation map counts and
keys, original identity input, and total structured-event size are bounded;
long label and annotation values are projected with a visible truncation marker,
while complete originals remain in raw bytes and original labels still determine
identity. Deliveries are limited to 1,000 alerts and JSON nesting depth 32.
The pipeline separately applies the aggregate batch/fanout storage bound.
