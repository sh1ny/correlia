# integration-icinga2 Specification

## Purpose
Turns Icinga 2 host and service state, acknowledgements, downtimes and flapping, sent by a shipped notification
command, into canonical events, so that Icinga 2 problems and recoveries reach Correlia's alert state with
stable identity and ordering.

## Requirements

### Requirement: Icinga2 webhook document

`/hooks/icinga2/<source>` SHALL accept one JSON object per delivery in Correlia's Icinga2 webhook format,
`format: "correlia.icinga2.v1"`: required object type, host, state, state type, notification type and
time, `service` for a service object; optional `output`, author and comment. A missing required field (`missing_field`), a wrong type (`invalid_type`) or an unknown
field (`unknown_field`) SHALL fail decoding with a bounded field path.

#### Scenario: Service problem notification
- **WHEN** an `icinga2` source receives a delivery for service `disk` on host `db1` with state `CRITICAL`, state type `HARD` and notification type `PROBLEM`
- **THEN** one canonical event of kind `alert`, status `firing` and severity `critical` is produced, with `observer.source_kind` `icinga2`

#### Scenario: Wrong type on a known field
- **WHEN** a delivery's `state` is the number 2 instead of a state name
- **THEN** the raw row fails with error code `invalid_type`, its stored failure path is `state`, and no event, observation key or alert change commits

#### Scenario: Unknown field name is not reflected
- **WHEN** a delivery carries an unknown field named `secret_token_abc`
- **THEN** the raw row fails with error code `unknown_field`, its stored failure path is `*`, and neither the stored failure nor the log contains `secret_token_abc`

#### Scenario: Dotted unknown field name
- **WHEN** a delivery carries an unknown field named `state.state_type`, both of whose segments are documented field names
- **THEN** the persisted failure path is a single `*` and contains neither `state` nor `state_type` from that name

#### Scenario: Unsupported format version
- **WHEN** a delivery declares `format: "correlia.icinga2.v2"`
- **THEN** the raw row fails with error code `unsupported_version` and stored failure path `format`

### Requirement: State change time is required only for state notifications

The webhook document SHALL require `last_state_change` for `PROBLEM` and `RECOVERY` notifications and accept
its absence for every other notification type, validating it like any time when present. The shipped command
SHALL pass it for `PROBLEM` and `RECOVERY` only, from one read per command; with no usable time the sender
SHALL refuse it.

#### Scenario: State notification without a state change time
- **WHEN** a `PROBLEM` delivery has no `last_state_change`
- **THEN** decoding fails with error code `missing_field` and stored failure path `last_state_change`

#### Scenario: Non-state key without the state change time
- **WHEN** two otherwise equal `ACKNOWLEDGEMENT` deliveries differ only in that one carries `last_state_change` and the other does not
- **THEN** both have the same observation key and event id

#### Scenario: Non-state notification for an object with an unusable state change time
- **WHEN** a supported release sends an `ACKNOWLEDGEMENT` through the shipped host command for a host whose last state change time is a negative passive execution end
- **THEN** the delivery carries no `last_state_change`, is accepted with 202 and stores one `ack` event

#### Scenario: Invalid state change time on a non-state delivery
- **WHEN** a `CUSTOM` delivery carries `last_state_change: "0.000000"`
- **THEN** decoding fails with error code `invalid_time` and stored failure path `last_state_change`

#### Scenario: Custom notification without a state change time
- **WHEN** a `CUSTOM` delivery for a service has no `last_state_change` and no `output`
- **THEN** one `comment` event with status `info` is stored, keyed and timed by its notification time, and no alert is created or changed

### Requirement: Webhook text is storable

A host or service name containing a control character (U+0000-U+001F, U+007F), or any text field containing
U+0000, SHALL fail decoding with `invalid_text` on that field, so no text PostgreSQL cannot store reaches a
transaction.

#### Scenario: NUL in a host name
- **WHEN** a delivery's `host` is `db1\u0000x`
- **THEN** the raw row fails with error code `invalid_text` and stored failure path `host`, without an internal retry, and no event, observation key or alert change commits

### Requirement: Webhook body nesting is bounded before parsing

The Icinga2 decoder SHALL check the body's JSON nesting depth against the same bound as the Alertmanager decoder
before parsing it, and SHALL fail a deeper body with a bounded validation outcome, not an internal retry.

#### Scenario: Deeply nested body
- **WHEN** an `icinga2` delivery's body is an array nested 10,000 levels deep
- **THEN** the raw row fails with error code `depth_bound` and stored failure path `body`, without entering the internal retry path

### Requirement: Shipped notification command

Correlia SHALL build a compiled sender, `correlia-icinga2-notify`, for linux-x64 and linux-arm64, publish it for
each architecture with a qualified release pair, and ship host and service `NotificationCommand` definitions that run it to build the webhook document and post it with a bearer
token or an HMAC signature as ADR 0029 defines. The sender SHALL start no child process and SHALL exit non-zero
when the delivery is not accepted, so Icinga 2 logs the failure.

#### Scenario: Notification from a real Icinga 2 in both auth modes
- **WHEN** a supported Icinga 2 release runs the shipped command for a service state change, once with a bearer token file and once with an HMAC key file
- **THEN** Correlia's real ingress accepts both deliveries with 202 and decodes them without error

#### Scenario: Rejected delivery
- **WHEN** the sender posts with a revoked token
- **THEN** Correlia answers 401 and the sender exits with status 1

#### Scenario: Long check output
- **WHEN** a supported release runs the shipped service command after a passive check result with 200 KiB of output
- **THEN** the command starts, the delivery is accepted with 202, the delivered output ends with the sender's truncation marker, and the stored description, cut again at the display bound, ends with the display truncation marker

#### Scenario: Recovery output with dollar signs
- **WHEN** a supported release sends the RECOVERY of a firing service whose check output is `OK: cost below $5, see $host.name$` followed by enough text to be cut
- **THEN** the command starts, the delivered output begins with that text verbatim, ends with the truncation marker, and the alert is resolved

#### Scenario: Oversized custom notification
- **WHEN** a supported release sends a `CUSTOM` notification with a 200 KiB comment and a 4 KiB author
- **THEN** the command starts, a `comment` event is stored with both texts cut and marked, and the alert does not change

#### Scenario: Multibyte character across the cut
- **WHEN** a supported release sends the RECOVERY of a firing service whose check output holds literal `$` signs and a three-byte UTF-8 character that straddles the 8 KiB cut
- **THEN** the command starts, the delivered output is valid UTF-8 holding the `$` signs verbatim and ending in at most one U+FFFD and the truncation marker, the delivery is accepted with 202, and the alert is resolved

#### Scenario: Invalid UTF-8 in check output
- **WHEN** a supported release sends a PROBLEM for a service whose active check plugin prints bytes that are not valid UTF-8, so they reach Icinga 2's check result unrepaired
- **THEN** the command starts, the invalid bytes are delivered as U+FFFD with the valid text around them unchanged, and the delivery is accepted with 202

#### Scenario: Burst of verbose notifications
- **WHEN** a supported release sends 50 PROBLEM notifications for 50 services through the shipped command to a recording receiver that answers 202 to every request with no concurrency limit, after passive check results submitted through the REST API with 512 KiB of output each, every request inside the API's 1 MiB body limit, half of them made only of `$` signs
- **THEN** the receiver records all 50 bodies within 60 s of the last check result, each output cut at 8 KiB with the marker and the `$` outputs delivered as `$` signs

#### Scenario: Runtime options in Icinga's environment
- **WHEN** the Icinga 2 process itself is started with `DART_VM_OPTIONS=--help` and `CORRELIA_URL` set, and sends a service PROBLEM through the shipped command, which launches the sender through `/usr/bin/env -i`
- **THEN** the sender starts with an empty environment, the delivery is accepted with 202, and the command exits 0 only after that 202

#### Scenario: Command definition without env -i
- **WHEN** the sender binary is executed directly, not through `/usr/bin/env -i`, with the single inert variable `CORRELIA_PROBE=1` set
- **THEN** it exits with status 2 and the line `environment`, before reading any file or opening a connection

#### Scenario: Name with an embedded NUL is not delivered
- **WHEN** a supported release has a firing alert for host `db1`, and a host defined with the octal-escaped name `db1\000x` goes DOWN and then UP through the shipped host command
- **THEN** neither notification is delivered, each command exits with status 2 and `invalid_name` in Icinga 2's log, and the alert for `db1` stays firing

#### Scenario: Oversized or invalid name is not delivered
- **WHEN** a supported release notifies for a service whose name is 1025 bytes long, or holds a byte that is not valid UTF-8
- **THEN** the command exits with status 2 and `invalid_name`, and no request reaches Correlia

#### Scenario: Setting not deliverable exactly
- **WHEN** the command's base URL setting is longer than 4 KiB, or its token file path holds a byte that is not valid UTF-8
- **THEN** the command exits with status 2 naming that argument, no file is opened and no connection is made

#### Scenario: NUL in a file path
- **WHEN** the command's `--ca-file` setting is the path of a valid CA file followed by U+0000 and `-next`
- **THEN** the sender exits with status 2 naming `--ca-file`, before any file is checked or opened and before any connection

#### Scenario: Base URL carrying a credential
- **WHEN** the command's base URL setting is `https://user:secret@correlia.example`, ends in `?token=secret`, or is a copied path-token URL `https://correlia.example/hooks/icinga2/<id>/secret`, and a notification is sent through a real Icinga 2
- **THEN** the command exits with status 2 naming `--base-url`, no connection is made, and Icinga 2's log does not contain `secret`

#### Scenario: Multiline settings
- **WHEN** the command's base URL setting is `https://correlia.example` followed by a line break and `https://correlia.example/hooks/icinga2/<id>/SECRET-MARKER`, or its source setting is the source UUID followed by a line break and `SECRET-MARKER`, and a notification is sent through a real Icinga 2
- **THEN** the command exits with status 2 naming that argument, no request is made, and neither the launched arguments nor Icinga 2's log contain `SECRET-MARKER`

#### Scenario: Source that is not a UUID
- **WHEN** the command's source setting is a 43-character credential instead of the source UUID
- **THEN** the command exits with status 2 naming `--source`, and Icinga 2's log does not contain that credential

#### Scenario: NUL in display text
- **WHEN** a supported release sends a CUSTOM notification whose comment and author contain a NUL followed by more text
- **THEN** the delivered comment and author hold U+FFFD in place of the NUL followed by the rest of the text, and the delivery is accepted with 202

#### Scenario: Inherited Correlia settings are ignored
- **WHEN** Icinga 2 runs with `CORRELIA_URL`, `CORRELIA_CA_FILE` and `CORRELIA_HMAC_KEY_FILE` set in its environment to other values, and the shipped command omits the optional `--ca-file` argument
- **THEN** the delivery goes to the URL built from the command's base URL and source, with the command's credential and the distribution trust, and is accepted with 202

### Requirement: Webhook limits are documented

The documentation SHALL state that Icinga 2 does not retry a failed notification, sends none for SOFT states
or while downtime, acknowledgement, dependencies or flapping suppress it, and that the upgrade is offline:
every older process, of every role (`api`, `worker`, `all`), stops before any process of this release starts
and is not restarted afterwards (an older worker decodes every row as Alertmanager).

#### Scenario: Documentation names the limits
- **WHEN** the documentation check reads the Icinga2 section of `docs/ingest-pipeline.md`
- **THEN** it finds the no-retry, SOFT and suppression limits, the convergence conditions and the worker upgrade order

### Requirement: State change time limits are documented

The documentation SHALL state the shipped formatter's input domain (`1 <= seconds < 2^32`, no time after
2106), which time a new object's first problem carries, and that a volatile object with no state value change
yet publishes one event per distinct, eligible HARD time that a command samples, not per check.

#### Scenario: Documentation names the state change time limits
- **WHEN** the documentation check reads the Icinga2 section of `docs/ingest-pipeline.md`
- **THEN** it finds the formatter's input domain, the first-problem time and the volatile-object limit

### Requirement: Downtime removal limits are documented

The documentation SHALL state that the webhook cannot tell a cancelled downtime from an expired one on releases
that send both as `DOWNTIMEEND`, and that removing a downtime that never triggered sends no notification.

#### Scenario: Documentation names the downtime limits
- **WHEN** the documentation check reads the Icinga2 section of `docs/ingest-pipeline.md`
- **THEN** it finds both downtime removal limits

### Requirement: Notification text exposure is documented

The documentation SHALL state that notification texts appear in the process list, in Icinga 2's log line for a
failed command and, with Notice logging, in its launch log for every notification, and that credentials never do.

#### Scenario: Documentation names the text exposure
- **WHEN** the documentation check reads the Icinga2 setup section of `docs/ingest-pipeline.md`
- **THEN** it finds the process list, the failure log and the Notice-level launch log named as places where texts appear

### Requirement: Sender setup constraints are documented

The setup documentation SHALL state that Icinga 2's service environment must not set dynamic loader variables
and, with 256 KiB of arguments, must fit the kernel's argument limit; that every component of each credential and
CA file's resolved path is writable only by root or the Icinga 2 user; and that token and key files are readable
only by the Icinga 2 user.

#### Scenario: Documentation names the setup constraints
- **WHEN** the documentation check reads the Icinga2 setup section of `docs/ingest-pipeline.md`
- **THEN** it finds the loader-variable rule, the argument budget, the directory rule and the `invalid_name` outcome

### Requirement: Sender transport and diagnostics

The sender SHALL run with an empty environment and take every input from its arguments, SHALL require an explicit
`https` URL, or `http` only to a literal loopback address, connect
directly, never follow redirects, trust only the configured CA file or the fixed distribution CA bundle whatever
the environment says, count only HTTP 202 as delivered, and write to Icinga 2 only the status or error class.

#### Scenario: Rejected delivery leaves no secret in Icinga 2 logs
- **WHEN** the shipped command running in a real Icinga 2 is rejected with 401, and Correlia's response body contains a marker text
- **THEN** Icinga 2's log holds the status and the command line with its texts and credential file paths, and neither the marker, the token, the HMAC key nor the signature

#### Scenario: Hostile inherited environment
- **WHEN** the Icinga 2 process runs with `http_proxy`, `ALL_PROXY`, `OPENSSL_CONF`, `SSL_CERT_FILE`, `SSL_CERT_DIR`, `CURL_CA_BUNDLE` and `SSLKEYLOGFILE` set, the proxies pointing at a recording listener and the CA settings naming a CA that signed an `https://` endpoint the configured trust does not include
- **AND** it sends notifications through the shipped command to a loopback `http://` URL and to that `https://` endpoint
- **THEN** the loopback delivery reaches Correlia directly, the recording listener receives nothing, the `https://` endpoint is refused before any request bytes are sent, and no key log file exists

#### Scenario: Configured CA is the only trust
- **WHEN** `--ca-file` names a private CA, and the sender sends once to an endpoint whose certificate that CA signed and once to one trusted only by the distribution bundle
- **THEN** the first is delivered and the second fails with exit status 3

#### Scenario: URL without a scheme or with a loopback name
- **WHEN** `--base-url` is `correlia.example:8080`, or `http://localhost:8080`
- **THEN** the sender exits with status 2 before reading any credential, and no connection is opened

#### Scenario: Plain HTTP to a remote host
- **WHEN** the configured base URL is `http://correlia.example:8080`
- **THEN** the sender exits with status 2 without opening a connection

#### Scenario: Non-regular credential file
- **WHEN** the `--hmac-key-file` argument names a FIFO
- **THEN** the sender exits with status 2 without opening it

#### Scenario: Credential file larger than its check
- **WHEN** the token file passes the type and size check but reading the opened file yields more than 4 KiB (an injected file that grows after the check)
- **THEN** the sender exits with status 2 naming only `--token-file`, having read at most 4 KiB and one byte, and opens no connection

#### Scenario: Blocking file after the check
- **WHEN** the `--ca-file` path passes the check and its open then never completes (an injected FIFO swapped in after the check)
- **THEN** the sender exits with status 3 and the line `deadline` within 10 s

#### Scenario: Credential file readable by others
- **WHEN** the `--token-file` is a regular file with mode 0644, or the `--ca-file` has mode 0666
- **THEN** the sender exits with status 2 and `credential_mode` or `ca_mode`, naming only the argument, before connecting

#### Scenario: Peer never answers
- **WHEN** the endpoint accepts the connection and never sends response headers
- **THEN** the sender exits with status 3 and the line `deadline` within 10 s

#### Scenario: Only 202 counts as delivered
- **WHEN** the configured URL is answered with 200 and an HTML page by a reverse proxy
- **THEN** the sender exits with status 1 and logs only the status

#### Scenario: Redirect is not followed
- **WHEN** the configured URL answers with a redirect to another host
- **THEN** the sender exits with status 1 and sends no second request

#### Scenario: Concurrent signed notifications beyond the cap
- **WHEN** three HMAC notifications for one source overlap in time
- **THEN** the third is answered 503, the command exits non-zero and Icinga 2 logs the status, and the setup documentation names the cap and the loss

### Requirement: Sender credential handling

The sender SHALL read the bearer token file as the configured token text and the HMAC key file in Correlia's
canonical 43-character unpadded base64url form, decoding to exactly 32 bytes, and SHALL keep the token, the key
and the signature out of its output.

#### Scenario: Canonical unpadded key file
- **WHEN** the HMAC key file holds a key in the canonical form the bootstrap configuration accepts, and the sender runs against a real Correlia ingress
- **THEN** the delivery is accepted with 202; a key file of 44 characters, or one decoding to other than 32 bytes, makes the sender exit with status 2 before connecting

#### Scenario: HMAC vectors
- **WHEN** the sender's signing function is run on the RFC 4231 HMAC-SHA-256 test cases
- **THEN** every output equals the published value

### Requirement: Webhook state change time precision

The shipped command SHALL send the notification time, and every last state change time it sends, with their
sub-second fraction, obtained through argument functions in the shipped command, so distinct state
changes within one second are distinct observations.

#### Scenario: Two problems within one second
- **WHEN** a supported release runs the shipped command for HARD CRITICAL, OK and HARD CRITICAL of one service, with both CRITICAL samples in the same integer Unix second, delivered in order
- **THEN** the two CRITICAL deliveries carry distinct, increasing microsecond last state change times in that second, the three observations have three different event ids, and the alert ends firing

#### Scenario: Microsecond values survive the command
- **WHEN** a supported release runs each shipped command with a passive check result whose execution end is a known value with a non-zero microsecond digit (`….123457`), and with the notification time's clock source replaced by one returning a known value of that form, the shipped conversion unchanged
- **THEN** the decoded last state change and notification time equal those values to the microsecond

#### Scenario: Production notification clock keeps microseconds
- **WHEN** a supported release passes known values with distinct last microsecond digits through the shipped time conversion of each command, unchanged, and samples its clock 20 times
- **THEN** every known value decodes to the same microsecond, and at least one clock sample's microsecond part is not a multiple of 10

#### Scenario: Host command keeps sub-second precision
- **WHEN** a supported release runs the shipped host command for DOWN, UP and DOWN of one host, with both DOWN samples in the same integer Unix second
- **THEN** the two DOWN deliveries carry distinct, increasing microsecond last state change times, and the three observations have three different event ids

### Requirement: State change time of a new object

The shipped command's state change time SHALL be the object's `last_state_change` once it has had a state
value change (a nonzero result time in UP for a host; in OK, WARNING or CRITICAL for a service), otherwise,
in state type HARD, its `last_hard_state_change`, and never Icinga 2's initial value. The shipped time formatter's input
domain SHALL be `1 <= seconds < 2^32`.

#### Scenario: First check result of a new host is DOWN
- **WHEN** a supported release runs the shipped host command for the first HARD DOWN of a host defined in configuration at startup and of a host created at runtime through the API, each from a passive result with a known execution end and followed by a second HARD DOWN result and a reminder
- **THEN** each first delivery carries that first HARD result's execution end as the capture driver recorded it, which for the runtime host differs from the daemon start time, one `firing` event is stored per host, its alert fires, and the reminder's raw row commits a `duplicate_observation` outcome

#### Scenario: Earlier result with a negative execution end
- **WHEN** a supported release receives a passive UP result with execution end -1 for a host, then passive SOFT DOWN and HARD DOWN results at current times, and runs the shipped host command
- **THEN** the delivery carries the SOFT DOWN result's execution end, the host's real last state change

#### Scenario: Retained state across a restart
- **WHEN** a supported release restarts the daemon with its retained state while a host from "First check result of a new host is DOWN" stays HARD DOWN, then sends a reminder
- **THEN** the reminder carries the same state change time and its raw row commits a `duplicate_observation` outcome

#### Scenario: Initialized state change time of a runtime-created host
- **WHEN** a supported release evaluates the shipped host helper on a value with state type HARD, `last_state_up` 0, `last_state_change` eight days before now and `last_hard_state_change` one second before now
- **THEN** the helper yields the time of one second before now, and a delivery built from it opens a firing alert instead of being `late`

#### Scenario: Volatile host with no state change yet
- **WHEN** a supported release runs the shipped host command for a HARD DOWN result of a volatile host whose results have all been DOWN, submits a second HARD DOWN result with a distinct, later, eligible execution end only after the first delivery's raw row has committed, then sends a reminder with no result between
- **THEN** the two deliveries are two observations with two `firing` events on one alert, the second moves the alert's fence without increasing its version, and the reminder's raw row commits a `duplicate_observation` outcome

#### Scenario: Time outside the formatter's domain
- **WHEN** a supported release evaluates the shipped time formatter on 0.5, on 4294967296 and on 4294967295.999999
- **THEN** the first two yield the empty string and the third yields `"4294967295.999999"`

### Requirement: Webhook state is the object's state when the command runs

A `PROBLEM` or `RECOVERY` delivery's status and severity SHALL come from its state and state type fields, which
describe the object when the command ran, never from its notification type. Other notification types are
informational whatever state they carry. The notification type SHALL be kept in the
event's annotations as `icinga2.notification_type`.

#### Scenario: Recovery notification sent after a refire
- **WHEN** a `RECOVERY` notification runs after the service already returned to HARD CRITICAL, so it carries state `CRITICAL` and the refire's last state change time
- **THEN** it is decoded as `firing`, and the later `PROBLEM` notification of the same refire is a `duplicate_observation`

#### Scenario: Delayed recovery publishes the live check output
- **WHEN** a supported release delays a `RECOVERY` notification whose triggering result says `OK: disk recovered` until after the service refired with output `CRITICAL: disk full`
- **THEN** the published event is `firing` with description `CRITICAL: disk full`, read from the live object's last check result, and after the refire's `PROBLEM` is deduplicated no published event of that observation carries the OK text

#### Scenario: Delayed notifications in any order
- **WHEN** coherent, eligible, unclamped deliveries of CRITICAL, OK and CRITICAL of one service, three distinct observations with strictly increasing last state change times, are processed in every order
- **THEN** every order ends with the alert firing and its fence owned by the last CRITICAL's observation

### Requirement: Webhook convergence contract

A webhook-fed alert SHALL end in the state of its highest-ranked committed, eligible, state-bearing
observation after event-ID deduplication, in any processing order. That is the object's latest state only if
the latest state was delivered, committed as such, and outranks the rest (coherent, unclamped deliveries;
strictly increasing µs change times). Otherwise the alert MAY stay stale, as documented.

#### Scenario: Lost recovery
- **WHEN** an eligible HARD CRITICAL is delivered and committed, and the OK that follows it is never delivered
- **THEN** the alert stays firing, and a later eligible observation with a new event ID whose ordering key outranks the fence sets the alert to its state

#### Scenario: Late reminder wins the event-ID insert
- **WHEN** a HARD CRITICAL is admitted promptly, a reminder of the same problem with the same last state change is admitted more than 7 days later, and the two rows are processed in each order
- **THEN** with the prompt delivery first the alert fires, the reminder is a `duplicate_observation`, and `last_observed_at` stays at the prompt delivery's observed time; with the reminder first it is stored as `late`, the prompt delivery is a `duplicate_observation`, no alert is created, and the result is outside the latest-state guarantee

#### Scenario: Torn delivery arrives after the coherent one
- **WHEN** a delayed RECOVERY carrying state `OK` with the refire's last state change time arrives after the coherent `CRITICAL` delivery of that refire, and a reminder of the refire follows
- **THEN** the alert is resolved, the reminder is a `duplicate_observation`, and a later eligible observation with a new event ID whose ordering key outranks the fence sets the alert to its state

#### Scenario: Regressing execution end
- **WHEN** a HARD CRITICAL with last state change 10:04 and then an OK with last state change 10:03 are delivered
- **THEN** the OK is classified stale, the alert stays firing, and a later eligible observation with a new event ID whose ordering key outranks the fence sets the alert to its state

#### Scenario: First delivery of an old problem
- **WHEN** a newly enrolled source receives a coherent reminder of a problem whose last state change is 9 days old
- **THEN** it is stored as `late` and no alert is created

#### Scenario: Reversed receipt under the skew clamp
- **WHEN** a coherent CRITICAL with source time 10:30 is received at 10:02 and the newer OK with source time 10:31 is received at 10:01, and they are processed in each order
- **THEN** both orders end firing, because the clamp gives CRITICAL effective time 10:07 and OK 10:06

#### Scenario: Equal state change times
- **WHEN** coherent deliveries A (CRITICAL), B (OK) and C (CRITICAL) of one service all carry the same last state change time, received in that order, and the same rows are processed in each order
- **THEN** A and C are one observation carried by whichever is processed first, each order ends with the status and fence of the observation whose carrier was received last, and the result is outside the convergence guarantee

### Requirement: Icinga2 alert identity

The fingerprint of an Icinga2 event SHALL be computed from the source namespace, kind `icinga2`, the host name
and, for a service, the service name. State, state type, severity, check output, times and acknowledgement or
downtime flags SHALL NOT be identity inputs.

#### Scenario: Host and service are distinct alerts
- **WHEN** host `web1` and its service `http` both report problems
- **THEN** they produce two different fingerprints

#### Scenario: Same names on another source
- **WHEN** two `icinga2` sources with their own namespaces report service `http` on host `web1`
- **THEN** the two fingerprints differ (ID-2)

### Requirement: Icinga2 status and severity mapping

For a `PROBLEM` or `RECOVERY` delivery with a HARD state (or OK/UP), host UP and service OK SHALL map to status
`resolved`, severity `info`; host DOWN and UNREACHABLE and service CRITICAL to `firing`, `critical`; service
WARNING to `firing`, `warning`; service UNKNOWN to `firing`, `unknown`. Every other delivery SHALL have status
`info` and severity `info`. The state name SHALL be kept as `severity_original`, and any other state name SHALL
fail decoding at the state's field path.

#### Scenario: ID-7a WARNING to CRITICAL updates one alert
- **WHEN** service `disk` on host `db1` reports HARD WARNING and later HARD CRITICAL
- **THEN** one alert exists for the service, its severity is `critical`, its version advanced once for the severity change, and the activity ledger records `severity_changed`

#### Scenario: Informational delivery carrying a problem state
- **WHEN** an `ACKNOWLEDGEMENT` delivery for a service carries state `CRITICAL`
- **THEN** its event has status `info`, severity `info` and `severity_original` `CRITICAL`

#### Scenario: Unreachable host
- **WHEN** a `PROBLEM` delivery reports a host HARD UNREACHABLE
- **THEN** the observation is `firing` with severity `critical` and `severity_original` `UNREACHABLE`

#### Scenario: Unknown state name
- **WHEN** a webhook delivery reports service state `DEGRADED`
- **THEN** decoding fails with error code `invalid_state` and stored failure path `state`

### Requirement: Icinga2 alert projection

Every Icinga2 state observation (`PROBLEM` or `RECOVERY`) SHALL derive the alert's summary only from the object
and its state: `<host> <STATE>` or `<host>!<service> <STATE>` (UNREACHABLE shown as DOWN), with no `starts_at`
and no generator link. The description SHALL be `output`, absent when it is. Source-instance projection is
unchanged.

#### Scenario: Same state with different check output
- **WHEN** two observations of one service from the same source report HARD CRITICAL with different check output and different last state change times
- **THEN** the second advances the alert's fence to its own ordering key, the summary is the same after both, and the alert's version and activity do not change

#### Scenario: Missing check output
- **WHEN** a state observation carries no check output
- **THEN** the event has no description and its summary is still `<host>!<service> <STATE>`

### Requirement: SOFT states from the webhook are informational

A `PROBLEM` or `RECOVERY` delivery whose non-OK state is SOFT SHALL become a `state` event with status `info` and no alert-state
effect, because Icinga 2 sends no notification for SOFT transitions and would send none when a SOFT problem
recovers. In such a delivery an OK or UP state SHALL resolve whatever its state type.

#### Scenario: Soft problem sampled by a delayed notification
- **WHEN** a delivery reports SOFT CRITICAL for a service with no alert
- **THEN** an event of kind `state`, status `info` is stored and routed, and no alert is created

#### Scenario: Soft recovery resolves
- **WHEN** a service has a firing alert from a HARD CRITICAL, and a `RECOVERY` delivery then reports OK with state type SOFT
- **THEN** the alert is resolved

### Requirement: Icinga2 webhook observation evidence

A state notification's observation key SHALL be `ObservationKey.native` over the canonical JSON array of the
domain `icinga2.notify.v1`, state, state type and the object's last state change time in integer microseconds as
a decimal string; that time is also the source time. Times SHALL be strings of Unix seconds with exactly six
fraction digits, converted to microseconds exactly; a missing required or invalid time SHALL fail
decoding with a field error before conversion.

#### Scenario: Out-of-range time
- **WHEN** a delivery carries `last_state_change: "253402300800.000000"`
- **THEN** the raw row fails with error code `out_of_range` and that field's path, without an internal retry and with no committed effects

#### Scenario: Time not in the fixed form
- **WHEN** a delivery carries `notification_time: "1.5"`, or `"1e9"`, or the JSON number `1763571234.123456`
- **THEN** the raw row fails with error code `invalid_time` for the strings and `invalid_type` for the number, on `notification_time`, with no committed effects

#### Scenario: Exact microseconds at the top of the range
- **WHEN** two otherwise equal deliveries carry `last_state_change` `"8589934592.000001"` and `"8589934592.000002"`, and a third carries `"253402300799.999999"`
- **THEN** the first two decode to source times one microsecond apart with different event ids, and the third decodes without error

#### Scenario: Fixed key vectors
- **WHEN** the key test computes the keys of committed example deliveries
- **THEN** each key's native string, bytes and event id equal the committed vectors

#### Scenario: Re-notification of an unchanged problem
- **WHEN** Icinga 2 sends the same HARD CRITICAL problem notification twice, 30 minutes apart, with the same last state change time
- **THEN** the second is a `duplicate_observation` that only advances the alert's `last_observed_at`, and no second output intent is created

#### Scenario: Soft to hard without a state value change
- **WHEN** deliveries report SOFT CRITICAL and then HARD CRITICAL with the same last state change time
- **THEN** the two observations have different event ids, and the HARD observation creates the alert

#### Scenario: Zero state change time
- **WHEN** a delivery's `last_state_change` is `"0.000000"`
- **THEN** decoding fails with error code `invalid_time` and stored failure path `last_state_change`

#### Scenario: Missing notification time
- **WHEN** a delivery has no `notification_time`
- **THEN** decoding fails with error code `missing_field` and stored failure path `notification_time`

### Requirement: Acknowledgement, downtime and flapping events

Acknowledgement, downtime, flapping and `CUSTOM` notifications SHALL become `ack`, `downtime`, `state` and
`comment` events with status `info`, the object's fingerprint and notification time as source time. Each SHALL be one command execution keyed by notification type, notification time and author;
same-microsecond executions coalesce. One Correlia user per notification is the supported setup. They SHALL NOT
change alert state, whatever state they carry.

#### Scenario: Custom notification while the service is OK
- **WHEN** a service has a firing alert, and a `CUSTOM` delivery for it carries state `OK`
- **THEN** a `comment` event with status `info` is stored, and the alert stays firing with its fence and version unchanged

#### Scenario: Acknowledgement is published without state change
- **WHEN** an operator acknowledges a firing service in Icinga 2 and the shipped command sends the notification
- **THEN** an `ack` event with status `info` and the service's fingerprint is stored and gets an output intent per route, and the alert's status, severity and version are unchanged

#### Scenario: Two comments from one author
- **WHEN** one author sends two CUSTOM notifications for one service within the same integer Unix second, captured from a real Icinga 2
- **THEN** the two deliveries carry distinct, increasing microsecond notification times in that second, and two `comment` events with different event ids are stored

#### Scenario: Same-microsecond executions coalesce
- **WHEN** two CUSTOM deliveries for one service with the same author and the same notification time but different comments are processed
- **THEN** one `comment` event is stored and the second is a `duplicate_observation`

#### Scenario: Unsupported notification type
- **WHEN** a delivery carries notification type `ESCALATION`
- **THEN** the raw row fails with error code `unsupported_type` and stored failure path `notification_type`, and no event commits

### Requirement: Published author and comment

A non-state event's description SHALL be the comment and its annotation `icinga2.notification_author` the author,
each bounded with the display marker and omitted when empty.

#### Scenario: Published author and comment fields
- **WHEN** a CUSTOM delivery carries a 6000-character comment and a 2000-character author, and another carries neither
- **THEN** the first event's description is the comment cut to 4096 characters with the marker and its `icinga2.notification_author` annotation is the author cut to 1024 with the marker, and the second event has no description and no author annotation

### Requirement: Non-state key uses the delivered author

The author in a non-state observation key SHALL be the delivered author, which the shipped command cuts to 1 KiB.

#### Scenario: Authors equal in their first 1 KiB
- **WHEN** two CUSTOM deliveries for one service share a notification time, and their authors as Icinga 2 holds them differ only after the first 1 KiB, so both arrive as the same cut and marked author
- **THEN** one `comment` event is stored and the second is a `duplicate_observation`, while two authors that differ within their first 1 KiB give two events

### Requirement: Icinga2 display bounds

Host and service names, the check output and author and comment texts SHALL be projected into bounded display
fields with a visible truncation marker; identity SHALL use the complete names. A check output of any length
within the body limit SHALL NOT fail decoding.

#### Scenario: ID-3 maximum-length host and long check output
- **WHEN** a delivery through HTTP ingress has a 256-character host name and a 4097-character check output
- **THEN** it is accepted with 202, the event's summary and description are truncated with the marker, the fingerprint equals the one computed from the complete host name, and no 500 is returned

#### Scenario: Oversize identity value
- **WHEN** a host name longer than the identity component bound arrives
- **THEN** the identity uses the digest form of the complete name and the display projection carries the marker

### Requirement: Supported Icinga 2 releases

Support SHALL be stated per Icinga 2 minor release and architecture, from captures of a real Icinga 2 made by a
committed capture script; the list SHALL NOT be empty. A pair is listed only if the release's six gate captures
pass (same-second host and service state, same-second notification time, production notification clock,
downtime removal, first problem of a new object) and that architecture's exact artifact delivers with 202 an
event the pipeline decodes.

#### Scenario: Each shipped architecture is run
- **WHEN** the capture runs for a release, once per shipped architecture in that release's official image for it
- **THEN** it records the 202 of one real notification through that architecture's exact artifact and the canonical event the pipeline decoded from that row, and a pair without both, or whose row fails decoding, is not listed

#### Scenario: Listed release missing a capture
- **WHEN** the supported-release statement lists a release and architecture pair for which one of the six gates' captures, the architecture's 202 record, or the canonical event decoded from the raw row of that 202 is not committed, or that event does not match the expected one
- **THEN** the version-matrix test fails naming the pair and the missing or mismatched evidence

#### Scenario: 202 recorded but event missing
- **WHEN** a listed pair has its 202 record committed and no canonical event traceable to that row
- **THEN** the version-matrix test fails naming the pair

#### Scenario: Every capture decodes
- **WHEN** the version-matrix test runs over the committed captures
- **THEN** every capture decodes to the expected kinds, statuses, severities and fingerprints, none fails, and the test re-evaluates each listed pair's six gates on the committed evidence: distinct microsecond times and three event ids in each same-second capture, distinct notification times, a clock sample whose microsecond part is not a multiple of 10, informational downtime events, the first-problem predicate, and, for both shipped commands, every committed known timestamp input equal to its decoded value to the microsecond

#### Scenario: Known timestamp mismatch
- **WHEN** a listed pair's captures have distinct same-second times and event ids, but one known timestamp input decodes one microsecond away from its committed value
- **THEN** the version-matrix test fails naming the pair and the production notification clock gate

#### Scenario: Gate evidence present but failing
- **WHEN** a listed pair's captures are all present and decode, but its same-second service capture has both CRITICAL times in one microsecond and only two event ids
- **THEN** the version-matrix test fails naming the pair and that gate

#### Scenario: Multiline recovery and custom notification without output
- **WHEN** a supported release sends the RECOVERY of a firing service whose check output has several lines, and a CUSTOM notification for a service defined in configuration at startup that has no check result yet
- **THEN** the recovery is accepted with 202, its description holds every line, and the alert is resolved; the CUSTOM delivery carries neither `output` nor `last_state_change`, is accepted with 202, stores one `comment` event with status `info`, and creates no alert

#### Scenario: Macro text in a setting is literal
- **WHEN** a supported release runs the shipped command with `CorreliaBaseUrl` set to `https://$host.name$`, and in a second run with a token file path that contains `$` and names a valid token file
- **THEN** the first exits with status 2 naming `--base-url` and no request is made, and the second reads that exact path and is accepted with 202

#### Scenario: Same-named custom variables are ignored
- **WHEN** a supported release runs the shipped service command for HARD CRITICAL, OK and HARD CRITICAL within one second, for a service that defines `correlia_last_state_change` as a fixed valid time and `correlia_base_url` as another endpoint
- **THEN** all three deliveries reach the configured endpoint with the service's real last state change times, and the three observations have three different event ids

#### Scenario: Only one architecture qualifies
- **WHEN** every release passes its gates and has a recorded 202 for linux-x64, and none has one for linux-arm64
- **THEN** the statement lists only linux-x64 pairs, only the linux-x64 artifact is published, and the version-matrix test passes

#### Scenario: Captured downtime removal
- **WHEN** each listed release's captures of a triggered downtime that expires and of a triggered downtime that is removed manually, both for a firing service, are processed
- **THEN** each removal carries the notification type that release actually sends (`DOWNTIMEEND` on stock releases, recorded in the capture), commits an informational `downtime` event that is routed to outputs, and the alert's state, version and fence do not change

#### Scenario: Captured transition sequence
- **WHEN** the capture of a HARD CRITICAL, an acknowledgement, a downtime, flapping and the recovery of one service is decoded
- **THEN** each observation has the key and source time the evidence requirements name, and the alert ends resolved

#### Scenario: Captured host transitions
- **WHEN** each listed release's capture of a host going DOWN and then UP through the shipped host command is decoded
- **THEN** both observations have the host-only fingerprint, statuses firing `critical` and then resolved, and the source times the evidence requirements name, and the alert ends resolved

#### Scenario: No release passes
- **WHEN** no release and architecture pair qualifies: no release passes the six gates, or no architecture has its 202 record on a passing release
- **THEN** the version-matrix test fails, and the webhook contract is not published; an artifact with no qualified pair is not shipped

#### Scenario: A capture changes shape
- **WHEN** a newly captured release adds a field the decoder does not know
- **THEN** the version-matrix test fails naming the release, the capture file and the field

### Requirement: First problem of a new object qualifies a release

The first-problem gate SHALL pass only when each
non-volatile host has exactly one firing event across its first and second HARD DOWN and reminder, carrying
the first HARD result's end, each reminder decodes to that event's id and its own raw row ends with
`duplicate_observation: 1`, and the unchecked CUSTOM omits `output` and `last_state_change`, gets 202, stores one
`comment` event and leaves alert state unchanged.

#### Scenario: Five gates pass but the first problem is lost
- **WHEN** a listed pair's captures pass the other five gates and record the 202 and its decoded event, but the runtime host's first HARD DOWN delivery carries the daemon start time and its decoded row is `late`
- **THEN** the version-matrix test fails naming the pair and the first-problem gate

#### Scenario: Reminder of a first problem is a new observation
- **WHEN** a listed pair's captures pass every other predicate, but the startup host's reminder after the second HARD DOWN result has a different event id from its first delivery
- **THEN** the version-matrix test fails naming the pair and the first-problem gate

#### Scenario: Reminder accepted without a committed duplicate outcome
- **WHEN** a listed pair's captures pass every other predicate, and the startup host's reminder has a 202 and no new event but its raw row has no committed `duplicate_observation` outcome
- **THEN** the version-matrix test fails naming the pair and the first-problem gate

#### Scenario: Second HARD check emits a second event
- **WHEN** a listed pair's captures pass every other predicate, but the startup host's second HARD DOWN produced a second firing event and its reminder is a `duplicate_observation` of that second event
- **THEN** the version-matrix test fails naming the pair and the first-problem gate

### Requirement: First-problem gate evidence

The capture SHALL record the driver's own execution ends, each newly admitted request's terminal raw outcome,
and committed alert state and event counts, and SHALL record transport-deduplicated 202s, rejections and
recorder-only requests as separate kinds; the first-problem gate SHALL be judged on that evidence.

#### Scenario: Transport duplicate counted as a reminder outcome
- **WHEN** a listed pair's reminder evidence is a transport-deduplicated 202 with no newly admitted raw row
- **THEN** the version-matrix test fails naming the pair and the first-problem gate
