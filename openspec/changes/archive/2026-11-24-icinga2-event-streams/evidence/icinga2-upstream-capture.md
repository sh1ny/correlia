# Icinga 2 upstream Event Streams capture

Run through `mise exec -- tool/icinga2_capture.sh --stream 2.13.14 2.14.10 2.15.7 2.16.6`. The fixture manifests record the official image IDs and digests, exact documented grants, and the phase and HTTP status of each omitted-grant case. This is upstream evidence for task 2.1; it does not include a built Correlia consumer run (task 11.4).

| Release | Stream HTTP framing | Older check submission | Unknown host attribute | Missing event grant | Missing host/service grant |
|---|---|---:|---|---:|---:|
| 2.13.14 | Close-delimited | 200, older result discarded | HTTP 400 | 404 | 404 |
| 2.14.10 | Close-delimited | 409 | HTTP 400 | 404 | 403 |
| 2.15.7 | Close-delimited | 409 | HTTP 400 | 404 | 403 |
| 2.16.6 | Chunked | 409 | HTTP 200, per-object code 400 | 404 | 403 |

All releases emitted the six subscribed types and reported `check_result.vars_after` with `state`, `state_type`, `attempt` and `reachable`. The service query's `attrs.name` is `stream-service`, not the enclosing `name` of `stream-host!stream-service`. A later execution start with an earlier execution end replaced the previous result; the older-start check with a larger end did not replace it. The captures retain that result from both the stream and the service query. Acknowledgement clears contain neither author nor comment.

The separate zero-match probe on 2.13.14 and 2.16.6 returned HTTP 404 with `No objects found.`; the same body was observed on a denied host query on 2.13.14. D3 therefore treats object-query 404 as failure, not as evidence of an empty result.

Unbounded upstream queue capacity is not inferred from a finite capture. In the upstream `lib/remote/eventqueue.cpp` at each exact captured tag, the inbox enqueue directly appends to the queue without a capacity check (2.13.14 and 2.14.10 line 196; 2.15.7 line 186; 2.16.6 line 181). The capture verifies wire behavior, not a safe upstream memory bound.
