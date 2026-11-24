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
quoted; copied numbers and booleans use their JSON text (`42`, `true`). Null
or absent values omit optional fields and fail the required summary. Copied
text obeys canonical display bounds. Constants that cannot fit the canonical
field fail activation. A link must be a valid HTTP(S) URL; arbitrary templates
are not supported.

### Bounds

- Bootstrap file: 64 KiB. Serialized `mappings` list: 64 KiB. At most 64
  mappings, each at most 32 KiB of canonical JSON.
- Per mapping: at most 128 identity fields, 128 labels, and 16 links. Pointers
  are at most 512 UTF-8 bytes. Each value table has at most 256 entries with
  input keys at most 256 UTF-8 bytes.
- A delivery is subject to its source's body cap (default 1 MiB) and can hold
  at most 1,000 alerts.
