# Canonical event payload fixture

`canonical_event.valid.json` is the positive canonical payload fixture. It uses
explicit snake_case JSON names, numeric full-range `raw.size`, nanosecond
timestamps, base64 byte data, bounded maps and anchored whole-value patterns.

The executable build-time fixture suite is explicit and lives under
`tool/schema_validation/fixtures/`. It does not glob this directory, so
CloudEvents envelope fixtures elsewhere under `contracts/` are never validated
against the payload-only schema.
