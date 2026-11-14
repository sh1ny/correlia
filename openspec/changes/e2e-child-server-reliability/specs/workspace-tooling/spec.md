# Spec Delta

## ADDED Requirements

### Requirement: Child server tests budget their own deadlines
Every test that starts server child processes SHALL have its own test timeout, at least the sum of the
readiness and shutdown deadlines the harness allows each child the test starts in sequence, so a harness
deadline always fails before the runner's timeout. No such test SHALL run on the runner's default timeout. A
check in `mise run check` SHALL fail, naming the file and line, when a test that starts a child server has no
timeout of its own.

#### Scenario: Slow but healthy child under full-suite load
- **WHEN** the full suite runs at the default concurrency and a child server takes longer than the runner's
  default timeout to become ready, but less than the harness's readiness deadline
- **THEN** the test does not time out, and its own assertions decide whether it passes

#### Scenario: Child never becomes ready
- **WHEN** a child server is not ready within the harness's readiness deadline, in a test that starts one or
  several children in sequence
- **THEN** the test fails with the harness's readiness error and the child's output, not with a test-runner
  timeout

#### Scenario: New child server test without a timeout
- **WHEN** a test file that starts a child server declares a test with no timeout of its own
- **THEN** `mise run check` fails and names that file and line

### Requirement: Child server startup survives a lost port
When a child exits during startup because a port the harness picked for it is already in use, the harness
SHALL start it again on freshly picked ports, at most a fixed small number of attempts, within the one readiness
deadline. Any other startup failure SHALL fail at once with the child's output. A retry SHALL keep the same
database, cluster root and environment.

#### Scenario: Port taken between pick and bind
- **WHEN** another process binds a child's pre-picked API or web port before the child does
- **THEN** the child is started again on fresh ports and the test proceeds against the new ports

#### Scenario: Port lost on every attempt
- **WHEN** every attempt fails because a port is already in use
- **THEN** the test fails after the last attempt with an error naming the attempts and the last child's output

#### Scenario: Startup fails for another reason
- **WHEN** a child exits during startup for any reason other than a port already in use, such as a migration or
  configuration error
- **THEN** the test fails on the first attempt with the child's output, and no second child is started

### Requirement: A child's exit and readiness describe the child the test owns
A child's reported exit SHALL be the exit of its final attempt: an attempt that failed on a lost port and is
being retried SHALL NOT complete it. The harness SHALL declare a child ready only when its readiness endpoint
answers and the listener on the child's API port belongs to the child's own current process. Stopping or
killing a child SHALL stop further retries and act on its current attempt.

#### Scenario: Caller waits on exit and readiness together
- **WHEN** a test waits for whichever comes first of the child's exit and its readiness, and the first attempt
  fails on a lost port
- **THEN** the test sees neither that attempt's exit nor a failure; it sees the outcome of the retried attempt

#### Scenario: Another server answers on the stolen API port
- **WHEN** the process that took a child's API port answers the readiness endpoint with success
- **THEN** the harness does not declare the child ready on that port, retries the child on fresh ports, and the
  child's reported API port is not the stolen one

#### Scenario: Teardown while a retry is pending
- **WHEN** a test stops or kills a child while a lost-port retry is being started
- **THEN** no further attempt starts, the attempt that was being started is stopped, and the child's exit
  completes once
