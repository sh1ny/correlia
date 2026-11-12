# Spec Delta

## Purpose

Show operators, in the Flutter web console, a live list of alerts that follows the change feed without a reload, and define who may read that list before the console has access control.

## ADDED Requirements

### Requirement: Live alert list

The console SHALL show the firing alerts with:
- severity;
- summary;
- source instance;
- time since firing began;
- last observed time.

It loads a snapshot and then follows the change feed on every wake-up and at least every 10 seconds without one. A firing alert SHALL appear without a reload, and a resolved one SHALL leave the list.

#### Scenario: New alert appears live
- **WHEN** the console is open and a webhook makes a new alert fire
- **THEN** the alert appears in the list without a page reload

#### Scenario: Resolved alert leaves the list
- **WHEN** a listed alert is resolved by a newer observation
- **THEN** it is removed from the list without a page reload

#### Scenario: Wake-up stream silent
- **WHEN** an alert fires while the console's wake-up stream delivers nothing but stays connected
- **THEN** the alert appears within one 10 second safety pull

### Requirement: Responses applied in order by version

The console SHALL apply snapshot and feed responses in request order, one feed read at a time. It SHALL remember the last version of each alert it removed. No alert's version SHALL move backwards, and no older response SHALL restore a resolved alert.

#### Scenario: Older version arrives after a newer one
- **WHEN** the console holds an alert at version 3 and receives that alert at version 2
- **THEN** it keeps version 3's status, severity and summary

#### Scenario: Delayed older response after a resolution
- **WHEN** a feed response carrying alert X firing at version 2 arrives after the console has already removed X on its resolution at version 3
- **THEN** X stays out of the list

### Requirement: Bounded partial snapshot

The snapshot SHALL hold at most its limit of firing alerts, ordered by severity and then newest firing, with the count of firing alerts it omits. While the console's list is partial, or once feed additions take the held alerts above the limit, the console SHALL take a new snapshot at the next safety pull and use its omitted count from then on.

#### Scenario: Snapshot bound exceeded
- **WHEN** more firing alerts exist than the snapshot limit
- **THEN** the list shows the limit's worth, ordered by severity and then newest firing, marked partial with a visible count of the alerts not shown

#### Scenario: Complete list grows past the limit
- **WHEN** the snapshot had an omitted count of 0 and feed additions then take the held firing alerts above the limit
- **THEN** by the next safety pull the console takes a new snapshot, holds at most the limit's worth of alerts, and shows the list as partial with the omitted count

#### Scenario: Partial list refills after a resolution
- **WHEN** the list is partial and a displayed alert resolves while an omitted alert is still firing
- **THEN** within one safety pull the console takes a new snapshot that shows the omitted alert and an updated count

### Requirement: Connection loss is visible and recovered

When the wake-up stream or a feed read fails, the console SHALL show a visible disconnected state. It SHALL retry with bounded backoff and resume from its last cursor. The alerts it already shows SHALL stay on screen, marked as possibly out of date. A cursor the server rejects SHALL make the console take a new snapshot.

#### Scenario: Server restart
- **WHEN** the server stops while the console is open and starts again
- **THEN** the console shows disconnected while it is down, then reconnects, resumes from its cursor and shows changes committed while it was down

#### Scenario: Rejected cursor
- **WHEN** the server answers a feed read with an invalid-cursor error
- **THEN** the console takes a new snapshot and replaces its list with it

### Requirement: Development-only unauthenticated read access

Until the console has authentication, its read API and wake-up stream SHALL answer only when all of these hold:
- the run mode is `development` or `test`;
- the peer address is loopback;
- the role is `api` or `all`.

Every other request SHALL be refused with an authorization error and return no alert data. Ingest webhooks SHALL be unaffected.

#### Scenario: Local development access
- **WHEN** the server runs in `development` mode in role `all` and a loopback client calls the snapshot read
- **THEN** it receives the alert snapshot

#### Scenario: Production mode refuses
- **WHEN** the server runs in `production` mode and a loopback client calls the snapshot read or opens the stream
- **THEN** the call is refused with an authorization error and no alert data is returned

#### Scenario: Non-loopback peer refuses
- **WHEN** the server runs in `development` mode and a client from a non-loopback address calls the feed read
- **THEN** the call is refused with an authorization error and no alert data is returned

#### Scenario: Worker role refuses
- **WHEN** the server runs in role `worker` and a client calls the snapshot read
- **THEN** the call is refused with an authorization error

### Requirement: Console usability baseline

As ADR 0003 requires from day one, the alert list SHALL:
- let text be selected and copied;
- expose accessibility semantics for each row (severity, summary, source);
- offer an in-app text filter over summary, source instance and severity, since browser search cannot see canvas text;
- render an alert's generator link as a link that can open in a new tab.

#### Scenario: Filter narrows the list
- **WHEN** the list shows alerts with summaries "disk full" and "cpu high" and the operator types "disk" in the filter
- **THEN** only the "disk full" alert is shown, and a live change to a hidden alert keeps it hidden while it does not match

#### Scenario: Filter matches nothing
- **WHEN** the filter text matches no displayed alert
- **THEN** the list shows a "no alerts match" message instead of rows

#### Scenario: Generator link and selectable text
- **WHEN** an alert has a generator link and another has none
- **THEN** the first row shows a link to that URL, the second shows no link, and the row text can be selected and exposes its severity, summary and source through semantics
