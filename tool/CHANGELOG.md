# Changelog

## 1.0.0

- Generate and check the production plugin protocol independently of the spike.
- Build pinned plugin and embedded JetStream tooling before plugin and e2e tiers.

- Added reproducible generation for the canonical event Dart messages, strict
  bundled payload JSON Schema and generated validation bounds.
- Added a committed v1.0 Buf descriptor baseline and compatibility checks for
  standard validation rules, explicit JSON names, presence and enum domains.
- Added build-time draft-2020-12 payload fixture validation with pinned Ajv
  8.17.1 and ajv-formats 3.0.1.
- Fix `doctor` selecting Serverpod's update notification instead of its installed-version line;
  an update banner alone is not version evidence.
- Inspect the resolved Serverpod CLI entry point with `--version`, avoiding implicit pub dependency
  refreshes and CLI update checks during offline `doctor` runs.
- Skip Flutter's implicit pub refresh in analysis and check tasks; resolve workspace dependencies
  explicitly before running the warmed-cache gate without network access.
- Run the resolved Serverpod generator directly after offline scratch resolution, avoiding unrelated
  native-hook downloads while retaining pinned versions and complete generated-output comparisons.
