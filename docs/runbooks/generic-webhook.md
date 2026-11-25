# Generic webhook

In a JSON bootstrap configuration with `format_version: 2`, give the source
`"kind": "generic"` and `"mapping": "checks"`. Define `checks` in the root
`mappings` list. The source and mapping activate together; multiple sources can
reference the same mapping. Send JSON to `/hooks/generic/<source-uuid>` with a
configured bearer token or HMAC credential. Path tokens and
`excluded_identity_labels` are not supported on generic sources.

## Mapping format 1

The table lists all keys in a mapping document:

| Key | Meaning |
|---|---|
| `name` | Nonempty name, unique within the file. |
| `mapping_format` | Must be `1`. |
| `items` | Optional pointer to the array of alerts. Without it, the body is one alert. |
| `unmapped_fields` | `reject` (default) fails the delivery on an unmapped leaf; `count` records only the number of unmapped leaves. |
| `identity` | Required map of canonical identity field names to pointers. There must be at least one. |
| `observation_id` | Optional pointer to a sender-provided observation ID. If declared, it must select a string in every alert. |
| `source_time` | Required `{ "pointer": "…", "format": "…" }` object. |
| `status` | Required `{ "pointer": "…", "values": { … }, "default": "…" }` value table. `default` is optional. |
| `severity` | Required value table (same form as status) or `{ "constant": "…" }`. |
| `summary` | Required display assignment. |
| `description` | Optional display assignment. |
| `labels` | Optional map of label names to display assignments. |
| `links` | Optional map of link relations to display assignments for their URLs. |

Example value of the root `mappings` list:

```json
[
  {
    "name": "checks",
    "mapping_format": 1,
    "items": "/data/results",
    "unmapped_fields": "count",
    "identity": {"host": "/labels/kubernetes.io~1name", "check": "/service"},
    "observation_id": "/changeId",
    "source_time": {"pointer": "/time", "format": "rfc3339"},
    "status": {"pointer": "/state", "values": {"OK": "resolved", "DOWN": "firing"}},
    "severity": {"pointer": "/level", "values": {"2": "critical"}, "default": "warning"},
    "summary": {"copy": "/title"},
    "description": {"copy": "/output"},
    "labels": {"team": {"constant": "ops"}},
    "links": {"runbook": {"copy": "/runbook"}}
  }
]
```

Pointers use RFC 6901. An empty pointer selects the root; every other pointer
starts with `/`. Escape `~` as `~0` and `/` within a key as `~1`. Dots are
literal. Array positions use decimal indexes starting at zero, without leading
zeros. `items` is relative to the body; every other pointer is relative to one
alert. An object or array selected for a scalar field fails that field. A leaf
is unmapped unless a pointer selects it or an ancestor, even if the selected
field then fails validation. This rule also applies to metadata beside `items`.

Status outputs are `firing`, `resolved` or `info`. Severity outputs are
`critical`, `error`, `warning`, `info` or `unknown`. Table inputs are strings or
integers, with integers looked up by their decimal text. A `default` applies to
an unlisted input, never to a missing, null or wrong-typed one.

`rfc3339` requires a UTC designator or explicit offset. `epoch_seconds` accepts
JSON integers from 0 to 253402300799; `epoch_millis` accepts integers from 0 to
253402300799999. Fractions, exponents and negatives are refused. Epoch evidence
is rendered as UTC RFC 3339 with no fractional part for seconds and three
fractional digits for milliseconds. RFC 3339 evidence keeps its original text.

For display fields, choose exactly one of `{ "copy": "/field" }` and
`{ "constant": "literal text" }`. A copied string is used as text, not JSON
quoted; copied numbers and booleans use their JSON text (`42`, `true`).
Numbers outside the double range keep their exact token (for example,
`1e309`). Null or absent values omit optional fields and fail the required
summary. Copied text obeys canonical display bounds. Constants that cannot
fit the canonical field fail activation. Links must be valid HTTP(S) URLs;
arbitrary templates are not supported.

A copied summary containing NUL (`U+0000`) fails with `invalid_text` at
its mapping pointer in preview and delivery. Other copied fields keep
their existing text rules.
Schema step 11 enables storage of these canonical events without changing
their bytes. A copied generator URL retains its canonical value; the alert
view renders embedded NUL as `%00`.

### Bounds

- Bootstrap file: 64 KiB. Serialized `mappings` list: 64 KiB. At most 64
  mappings, each at most 32 KiB of canonical JSON.
- Per mapping: at most 128 identity fields, 128 labels, and 16 links. Pointers
  are at most 512 UTF-8 bytes. Each value table has at most 256 entries with
  input keys at most 256 UTF-8 bytes.
- Mapping text may not contain NUL (`U+0000`): PostgreSQL cannot represent
  it in snapshots cast to JSONB or in recorded field paths.
- A delivery is subject to its source's body cap (default 1 MiB) and can hold
  at most 1,000 alerts.

## Identity and observation IDs

Every identity pointer must select a JSON string. Correlia derives the alert
fingerprint from the configured namespace, kind `generic`, and those mapped
identity fields, independently of batching and receipt time.

An `observation_id` must name one immutable state change, not the alert object.
If a sender uses the same ID for a firing alert and its resolve, Correlia records
the resolve as a duplicate rather than applying it. Omit `observation_id` if
the sender cannot provide a per-change ID; Correlia then uses the mapped
status, severity and reported source time for the observation key.

## Upgrade order

Upgrade every `api`, `worker` and `all` process to this release before
publishing a configuration with a generic source. Schema step 10 raises the
configuration publisher gate to version 2 under the publication lock. It
prevents a version-1 binary from publishing a new snapshot; it does not stop
old processes or detect an old process starting with an already active,
identical configuration. An old worker that claims a generic row fails it
with `unsupported_kind`.

Binary downgrade after step 10 is unsupported. Do not publish a generic
source until the upgrade is complete.

## Drain before removing a source

1. Stop senders or rotate the source's credential references to credentials
   no sender holds. Keep the source enabled, with its mapping and outputs
   still configured. Do not leave an old credential active.
2. Confirm there are no pending deliveries for the source. An operator with
   read access can check PostgreSQL using the source UUID as `$1`:

   ```sql
   SELECT count(*) FROM raw_inbox
   WHERE source_id = $1::uuid AND status = 'pending';
   ```

3. Publish the configuration without the source only after that count reaches
   zero. Otherwise rows not yet pinned fail `source_not_configured`; rows
   already pinned use the snapshot and mapping from their first claim.

## Preview a mapping

From loopback in development or test mode on an `api` or `all` process, call
`mappingPreview.preview(sourceId, sample, draftMapping: ...)` using the
generated client. `sample` is JSON text (at most 1 MiB decoded and 100
alerts). Omit `draftMapping` to use the source's active mapping, or pass one
mapping document as JSON text (at most 32 KiB decoded). The active generic
source supplies the source ID and namespace in both cases.

Output includes the valid alerts, field errors and unmapped paths, and
whether the whole delivery would fail. Diagnostics come in body-first
order, then by alert index, UTF-8 path bytes and code. Each path is cut at
a segment boundary within 256 bytes. The response retains at most 100
diagnostics or 64 KiB of diagnostic JSON, whichever fits first, and reports
the number omitted as `overflow`. Preview paths can include sender field
names; durable worker failures redact those names.

If the 16 MiB serialized decode budget is reached, preview keeps the
successful alerts that fit and reports `decode_bound`. Delivery fails the
whole row instead.

The label `computed with preview metadata` means the preview uses the nil
raw UUID and the call time for its raw reference, observation and processing
times. This does not change the source-derived identity, but the byte
length can change eligibility near a size limit. The preview writes and
publishes nothing, does not activate a draft, and does not estimate a
production row's fan-out budget.
