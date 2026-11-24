# Event Streams implementation run notes

## A4: embedded PostgreSQL version (task 7.1)

On 2026-11-23 a `withServerpod` database test ran `SHOW server_version` against the project's owned embedded test cluster. PostgreSQL reported `16.13`; the probe passed. `transaction_timeout` is not available on this server. Use the D13 statement and lock timeouts and the dedicated connection's local stop deadline; do not set `transaction_timeout` on PostgreSQL 16.

## A3: TCP keepalive over HTTPS (task 10.1)

On 2026-11-23 the loopback HTTPS spike passed on Linux x64 with pinned Dart 3.13.7.
The factory set and read back `SO_KEEPALIVE=1`, `TCP_KEEPIDLE=60`, `TCP_KEEPINTVL=10`
and `TCP_KEEPCNT=6` on the kernel socket, then completed the verified HTTPS exchange.
Returning the plain socket closed before HTTP headers: the custom factory must do
`SecureSocket.secure` with the configured CA and URI host before handing the socket
to `HttpClient`. `HttpClient` can still own HTTP framing; no custom framing is needed.

A follow-up stalled-handshake probe sent a ClientHello to a raw loopback
listener. `ConnectionTask.cancel()` and `Socket.destroy()` on the original
socket after `SecureSocket.secure` did not produce peer EOF within 300 ms.
Retaining the `RawSocket` passed to `RawSecureSocket.secure` and closing it did
produce peer EOF; the SDK's pending handshake Future did not settle within
2 seconds, so the caller must also complete its own cancellation explicitly.

## Public trust verification (task 10.3)

Owner approved hermetic CI with a child process that trusts a second test CA by default
and verifies that the configured-only consumer rejects it without HTTP or proxy traffic.
The public-root check used a direct `openssl s_client -verify_return_error` handshake to
`example.com:443`, which negotiated TLS 1.3 and reported `Verification: OK`. The same endpoint
returned `{"error":"tls"}` through the production adapter with only the fixture CA configured,
`SSL_CERT_FILE` naming another CA, and both proxy variables pointing at a closed loopback port.
The loopback tests are the proof that rejected trust sends no HTTP credentials or proxy traffic.

## Dedicated PostgreSQL TCP settings (task 10.3)

A disposable Serverpod Embedded Postgres 16.13 cluster using `TcpTransport(port: 0)`
bound only to loopback. The production opener reported
`[correlia_stream_tcp_probe, 16.13, 127.0.0.1/32, 1s, 5s, 5, 1, 3, 10000]`
for database, version, server address, connection-check interval, idle transaction
timeout, TCP idle time, interval, probe count, and TCP user timeout. PostgreSQL
reports the last value as milliseconds; the probe's text assertion expected `10s`
instead. The observed value was the required 10,000 ms. The cluster was stopped
and its data directory deleted.
