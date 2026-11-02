# <Project> Architecture

<!-- The current system shape. Change designs read this first. Keep it brief: a few lines per row; detail lives in ADRs and change designs. -->

## System triage

<!-- Which of T1-T6 apply to the system as a whole, with one line of evidence each. -->

## Components

<!-- mermaid component graph: processes, isolates/workers, stores, external systems, and the direction of calls and data. -->

| Component | Responsibility | Owns (state) | Talks to via (contract) |
|---|---|---|---|

## State ownership

| State | Sole writer | Lifetime | Invalidation / rebuild | Authoritative copy |
|---|---|---|---|---|

## Boundaries and contracts

<!-- Data formats, schemas, IPC/isolate messages, external APIs: where each is defined and how it is versioned. -->

## Resource bounds and failure visibility

| Flow / store | Bound | At the bound | On failure | Who finds out |
|---|---|---|---|---|

## In-force ADRs

<!-- Index of accepted, not superseded ADRs. Update when an ADR is added or superseded. -->

| ADR | Decision | Supersedes |
|---|---|---|
