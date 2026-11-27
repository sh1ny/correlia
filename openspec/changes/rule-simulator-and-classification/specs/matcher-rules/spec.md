# Spec Delta

## ADDED Requirements

### Requirement: Classify action

Matcher rules SHALL support a `classify` action that sets a noise class hint. It SHALL be validated with the rest of the document before activation, follow the existing patch, ordering and failure-isolation rules, and keep language `matcher`, version `1`.

#### Scenario: Existing documents stay valid
- **WHEN** a matcher document published before this change, with no write to `correlia.noise_class`, is published again
- **THEN** it activates with the same language, version and evaluation results

#### Scenario: New actions in one rule
- **WHEN** one matching rule has a `set_label`, a `link` and a `classify` action
- **THEN** the enriched event carries all three effects as one patch: the `set_label` label and the `classify` hint have origin `matcher`, and the link is added in the same patch (a link has no origin)

#### Scenario: A failing action discards the hint
- **WHEN** a rule's `classify` action is staged and its `extract` action then times out
- **THEN** neither the hint nor the extracted label is applied, and the failure is counted once for that rule

#### Scenario: Upgrade with a file that writes the reserved key
- **WHEN** after the upgrade an operator publishes edited matcher content that no stored snapshot has and that writes `correlia.noise_class` with `set_label` or `extract`
- **THEN** publication fails with a field error naming the reserved key and the fix, and the active snapshot is unchanged

#### Scenario: Exact restart with a pre-change file that writes the reserved key
- **WHEN** the active snapshot's matcher content writes `correlia.noise_class` with `set_label`, and the server restarts with the exact file that published it
- **THEN** startup succeeds and the same snapshot stays active without a new publication

#### Scenario: Rollback to pre-change content that writes the reserved key
- **WHEN** an operator publishes, at a higher revision, matcher content equal to an earlier stored snapshot's that writes `correlia.noise_class` with `set_label`
- **THEN** the guarded rollback succeeds as for any earlier content

#### Scenario: Pinned pre-change snapshot keeps running
- **WHEN** a raw row is pinned to a snapshot whose matcher writes `correlia.noise_class` with `set_label`
- **THEN** the row processes with that write applied as a label, and a simulation of the stored event shows it among the stored labels, apart from any hint the simulated rules set

#### Scenario: Malformed classify action
- **WHEN** a `classify` action has no value, or a value outside the closed set
- **THEN** activation fails with a field error and the active snapshot is unchanged

### Requirement: Short-circuit evaluation is preserved

Condition evaluation SHALL stop an `all` at its first false child and an `any` at its first true child, in the pipeline and the simulator alike, so that a skipped child never runs regex work or causes a rule failure. The pipeline SHALL NOT build a trace.

#### Scenario: A decisive any skips a slow regex
- **WHEN** an `any` condition's first child matches and its second child is a regex that would time out
- **THEN** the rule matches, no regex runs for the second child, and no failure is counted

#### Scenario: A decisive all skips a slow regex
- **WHEN** an `all` condition's first child does not match and its second child is a regex that would time out
- **THEN** the rule does not match, no regex runs, and no failure is counted
