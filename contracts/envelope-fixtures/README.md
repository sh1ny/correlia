# Canonical CloudEvents envelope fixtures

Whole structured CloudEvents documents for the envelope contract in [cloudevents.md](../cloudevents.md).
They are wire documents, not payload-schema fixtures: a CloudEvent is never validated against the
payload-only JSON Schema, because that schema describes `data` alone. The payload fixture used by the
build-time schema check lives in `contracts/fixtures/`.

Every document below carries exactly one defect, so a rejection names the defect and nothing else.

## Accepted documents

| File | Expectation |
|---|---|
| `cloud_event.valid.json` | The complete reviewed alert envelope. It decodes to the published event id and fingerprint and re-encodes to the same known attributes. |
| `cloud_event.newer_minor.json` | The same alert with `dataschema` `urn:correlia:schema:event:1.1` and two synthetic `producer_note` fields. The reader accepts the known core, reports the known-core-only scope and ignores both unknown fields. This fixture does not publish a real v1.1 contract. |

## Rejected documents

| File | Defect | Rejection |
|---|---|---|
| `negative/cloud_event.data-base64.json` | `data_base64` instead of a JSON `data` object | path `data_base64`, code `unsupported_attribute` |
| `negative/cloud_event.extension-name.json` | unknown attribute named `BrokerTrace` | path `BrokerTrace`, code `invalid_format` |
| `negative/cloud_event.extension-value.json` | unknown attribute carrying an object | path `brokertrace`, code `invalid_type` |
| `negative/cloud_event.extension-count.json` | 33 unknown attributes | path `event`, code `invalid_count` |
| `negative/cloud_event.dataschema-major.json` | `dataschema` naming major version 2 | path `dataschema`, code `unsupported_major` |
| `negative/cloud_event.traceparent.json` | `traceparent` with an all-zero trace id | path `traceparent`, code `invalid_trace_id` |
| `negative/cloud_event.identity-mismatch.json` | `subject` that is not the payload's fingerprint | path `subject`, code `identity_mismatch` |
| `negative/cloud_event.payload-undeclared-field.json` | an undeclared payload field in an exact-minor document | path `producer_note`, the payload's own rejection |

## Rejected conditions without a file

Each condition is a single-attribute mutation of `cloud_event.valid.json`.

| Mutation | Rejection |
|---|---|
| `specversion` other than `1.0` | path `specversion`, code `unsupported_specversion` |
| `datacontenttype` other than `application/json` | path `datacontenttype`, code `unsupported_content_type` |
| `dataschema` that is malformed, for example a leading-zero minor | path `dataschema`, code `invalid_format` |
| `id` other than the payload's event id | path `id`, code `identity_mismatch` |
| `source` naming another source instance | path `source`, code `identity_mismatch` |
| `type` naming another kind | path `type`, code `identity_mismatch` |
| `partitionkey` other than the payload's fingerprint | path `partitionkey`, code `identity_mismatch` |
| `correliatenant` other than the payload's tenant | path `correliatenant`, code `identity_mismatch` |
| `time` denoting another instant | path `time`, code `identity_mismatch` |
| `time` without a payload source time | path `time`, code `identity_mismatch` |
| `traceparent` that is malformed or carries a zero span id | path `traceparent`, code `invalid_format` or `invalid_trace_id` |
| unknown attribute name with uppercase, punctuation or more than 128 characters | path is the attribute name, code `invalid_format` or `too_long` |
| unknown attribute carrying an array, a fractional number or a number outside the signed 32-bit range | path is the attribute name, code `invalid_type`, `invalid_number` or `out_of_range` |
| unknown attribute carrying a control character, a noncharacter or more than 1024 scalars | path is the attribute name, code `invalid_character`, `invalid_unicode` or `too_long` |
| more than 262144 encoded bytes | path `event`, code `event_too_large` |
| a document nesting deeper than 16 containers | path `event`, code `too_deep` |

A valid unknown attribute is accepted and then ignored: it never reaches the payload and never reappears
in the encoded envelope.
