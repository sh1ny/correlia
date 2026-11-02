# 0003. Flutter web for the operator console

- Status: accepted (2026-11-03)
- Date: 2026-11-03
- Supersedes: none

## Context

The legacy service had no UI. The rebuild needs an operator console: dense alert and incident tables, facets,
live updates, keyboard work, deep links. Options were Flutter web and Jaspr (Dart, DOM-based). Research
(docs/research/stack-research.md): `jaspr_serverpod` supports only Serverpod < 3, Jaspr has no data grid,
and it is effectively maintained by one person. The owner already ships Flutter apps.

## Decision

`correlia_flutter` is a Flutter web app using the generated Serverpod client and streams. From day one it
wraps content in `SelectionArea`, enables accessibility semantics, provides its own in-app search (browser
Ctrl+F cannot see canvas text) and uses `Link` widgets so rows open in new tabs. Served as static files by the
Serverpod web server.

Rejected: Jaspr. Reversal cost: high for the console (rewrite), zero for the server. Jaspr remains the
preferred option for a separate, public status page or shareable incident pages if those are built.

## Consequences

- First load is several MB; acceptable for an operator tool, unacceptable for a public page.
- The same codebase can later produce a mobile on-call app.
