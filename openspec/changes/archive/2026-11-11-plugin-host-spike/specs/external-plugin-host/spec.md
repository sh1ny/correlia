# External Plugin Host Delta

## Purpose

Defines observable interoperability, security, flow control and child-lifetime guarantees for Correlia's external output plugin host. This initial capability is an experimental spike, not a complete plugin SDK.

## ADDED Requirements

### Requirement: Stock subprocess handshake
The host SHALL start a Linux Go plugin using unmodified stock go-plugin serving, negotiate a supported application version, accept core version 1 with gRPC, and require health service `plugin` to report SERVING before delivery. Invalid, incompatible or incomplete startup SHALL fail within a configured deadline with a diagnostic and child cleanup.

#### Scenario: Plain stock plugin startup
- **WHEN** a plain stock Go fixture without a stdin watcher is launched with matching cookie and supported version in the default AutoMTLS mode
- **THEN** the Dart host reports the selected version and SERVING health and completes an authenticated application RPC without modifying go-plugin

#### Scenario: Invalid or stalled startup
- **WHEN** the cookie is wrong, versions do not overlap, the handshake is malformed or oversized, the child exits, or readiness stalls
- **THEN** startup returns the corresponding error within its deadline, sends no event, and leaves no child owned by that attempt

#### Scenario: Late startup resource acquisition
- **WHEN** startup's deadline expires before an owned child-process or private-directory acquisition returns
- **THEN** startup reports the timeout and its registered completion handler disposes any late result without leaving that attempt's child or scratch behind

### Requirement: Mutual authentication without silent downgrade
The host SHALL authenticate the stock plugin certificate and present its own certificate using go-plugin AutoMTLS, including P-521 interoperability. It SHALL reject an untrusted server or missing or wrong client identity. A failed authentication SHALL NOT trigger plaintext retry; any security fallback requires an explicit owner decision recorded in a superseding ADR.

#### Scenario: Authenticated Unix socket exchange
- **WHEN** a stock Go fixture and Dart host use AutoMTLS over the Linux Unix socket
- **THEN** both validate the peer certificate and a protected application RPC succeeds, with the observed P-521 group of both client and server certificates and the negotiated TLS protocol recorded

#### Scenario: Unauthorized peer or unsupported cryptography
- **WHEN** the server pin is wrong, the client certificate is absent or wrong, or the runtime cannot use the required P-521 certificates
- **THEN** the protected RPC fails, no delivery succeeds, and the error is visible without disabling TLS

### Requirement: Native TLS runtime ownership
The OpenSSL connector SHALL bound native input, staging and plaintext admission, preserve bytes across nonblocking retries, and release resources on initialization failure, deadline or close. Missing dependencies or required cryptographic capabilities SHALL fail closed. The exported host API SHALL require AutoMTLS and exclude test controls. Internal fault controls SHALL NOT replace verification or disable AutoMTLS peer checks.

#### Scenario: Receiver stalls the native stream
- **WHEN** a verified mutual-TLS peer stops consuming bytes and a bounded producer fills plaintext admission
- **THEN** the producer is paused rather than growing the queue, and after receiver release all admitted bytes arrive unchanged despite partial socket writes

#### Scenario: Host pauses the native stream
- **WHEN** the authenticated plaintext consumer pauses while the peer continues sending
- **THEN** network reads stop at the inbound bound rather than accumulating plaintext, and resuming the consumer yields the exact sent bytes

#### Scenario: Native backend is unavailable
- **WHEN** the required native library or ABI cannot be loaded
- **THEN** startup reports that dependency failure, no application delivery succeeds and no alternate plaintext attempt is made

#### Scenario: Native initialization is incomplete
- **WHEN** invalid identity material fails after native initialization has allocated resources
- **THEN** the attempt releases its native allocations and socket ownership; repeated failures do not accumulate live native allocations

#### Scenario: Socket acquisition finishes late
- **WHEN** the startup deadline expires before the raw socket connection returns
- **THEN** startup fails and closes the late socket without allowing it to become a live application connection

#### Scenario: AutoMTLS readiness stalls
- **WHEN** the peer accepts the Unix connection but stalls TLS or authenticated HTTP/2 readiness
- **THEN** the configured startup deadline fails the connection and closes the attempt's network/native resources without delivering an application request

### Requirement: Bounded acknowledged delivery
Output delivery SHALL send immutable canonical events in bounded batches with a configured positive credit window. Only a valid acknowledgement for an outstanding batch on the current connection SHALL release its credit or complete its events. Exhausted credits SHALL stop further sends. Protocol errors SHALL fail the connection while preserving unacknowledged work.

#### Scenario: Receiver withholds acknowledgements
- **WHEN** a receiver withholds acknowledgements until the credit window is full
- **THEN** no additional batch is sent until a valid outstanding acknowledgement arrives, and the observed in-flight count never exceeds the window

#### Scenario: Invalid acknowledgement
- **WHEN** a receiver acknowledges an unknown batch, repeats an acknowledgement, or submits one from a previous connection
- **THEN** no pending event is incorrectly completed and no extra credit is created; an invalid current-connection acknowledgement fails that connection

#### Scenario: Receiver never acknowledges
- **WHEN** outstanding batches receive no acknowledgement before the configured progress deadline
- **THEN** the connection fails with a timeout, unacknowledged work remains pending, and no credit is released as if delivery had succeeded

### Requirement: Plugin crash redelivery
After plugin death, the surviving host SHALL retain unacknowledged events and permit explicit restart and byte-identical redelivery with unchanged event ids. Acknowledged work SHALL not be replayed. An externally accepted batch whose acknowledgement was lost can be delivered again; the guarantee SHALL be at least once, not exactly once or durable across host death.

#### Scenario: Ten thousand events with an uncertain batch
- **WHEN** 10,000 distinct canonical events are delivered and the plugin is killed after recording a batch but before acknowledging it, then restarted
- **THEN** the receiver's reconciled unique event-id and payload set equals the original set, only unacknowledged work is replayed, and no id is associated with changed bytes

#### Scenario: Restart cannot become ready
- **WHEN** restart fails startup or authentication while unacknowledged work remains
- **THEN** the host reports failure and retains that work without claiming it was delivered or silently discarding it

### Requirement: Child lifetime and shutdown
The host SHALL keep child stdin open and write no bytes to it. Normal stop SHALL request the stock shutdown controller and force termination after a bounded grace period. For a first-party fixture wrapping stock serving with a stdin watcher, host SIGKILL SHALL cause child exit within a bounded deadline. This orphan guarantee SHALL NOT be claimed for plain stock plugins without the watcher.

#### Scenario: Host is killed
- **WHEN** a separate Dart host process is killed with SIGKILL after its stdin-watched Go plugin reports ready
- **THEN** an independent observer confirms beforehand that the plugin's parent is the directly launched host, then observes that exact child absent or terminated as a same-identity zombie by the deadline, with a flushed stdin-EOF exit-cause marker and no teardown signal sent before the assertion

#### Scenario: Shutdown does not cooperate
- **WHEN** a child ignores or cannot receive the shutdown RPC
- **THEN** the host terminates its own child after the grace period, reports the forced stop, and reaps it without touching unrelated processes

### Requirement: Reproducible spike verdict
The spike SHALL report the four ADR 0020 criteria independently with Linux tool versions, commands, results, failures and each criterion's security mode. Handshake evidence SHALL survive TLS failure. An explicitly selected test-only 0600-socket/no-AutoMTLS diagnostic mode SHALL NOT count as fallback adoption. Failed criteria and owner-gated choices SHALL remain unresolved until fixed or explicitly dispositioned by the owner.

#### Scenario: All runtime criteria pass
- **WHEN** the real-process plugin tier demonstrates all four criteria
- **THEN** its evidence records each result separately, distinguishes plain-stock startup from stdin-watched cleanup, identifies the built-in TLS failure versus the custom-connector result, and leaves D24/custom-connector interpretation approval independent of automated results

#### Scenario: A criterion fails
- **WHEN** any runtime criterion fails
- **THEN** the report identifies the failed criterion and cause, the spike is not marked passed, and dependent plugin work is not declared unblocked by an unapproved fallback

#### Scenario: TLS feasibility fails independently
- **WHEN** a controlled native signature-capability restriction prevents P-521 AutoMTLS and the operator explicitly selects diagnostic socket-only runs for criteria 3 and 4
- **THEN** criteria 1, 3 and 4 record their own results and selected security mode, criterion 2 remains failed, and no production fallback is recorded as approved
