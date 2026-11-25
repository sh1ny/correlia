# A3: Serverpod accepts the preview request limits

Verified before implementing the preview endpoint. Serverpod 4.1.0 read
`maxRequestSize: 2621440` from `correlia_server/config/test.yaml`. Its test
server received two JSON-text arguments sent by the real generated Dart
client to a temporary RPC size probe: a 1,048,576-byte sample and a 32,768-byte
draft, both valid JSON strings packed with escaped backslashes. The test
checked that the server's SHA-256 for each argument matched the exact bytes
before sending. `escape_heavy_sample_and_draft_fit_the_rpc_limit`: 1 passed.

The temporary probe was removed after verification. The committed
`test/db/mapping_preview_rpc_test.dart` exercises the same decoded limits
through the actual preview RPC.
