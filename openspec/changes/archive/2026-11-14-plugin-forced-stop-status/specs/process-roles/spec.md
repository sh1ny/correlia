# Spec Delta

## ADDED Requirements

### Requirement: Repeated worker stop
Stopping the worker's ingest subsystems SHALL happen once. The first stop request SHALL report any error of that stop, as "Graceful shutdown" requires, after attempting to stop every subsystem. A further stop request, during or after the first, SHALL wait for the first to finish, SHALL complete without error whether the first succeeded or failed, and SHALL NOT stop any component a second time. A pipeline that was never started SHALL stop at once without error.

#### Scenario: Stop called twice
- **WHEN** the ingest workers have been stopped successfully and stop is called again
- **THEN** the second call completes without error and no subsystem's stop runs twice

#### Scenario: Concurrent stops that succeed
- **WHEN** a second stop is called while a first stop, which will succeed, is still stopping the subsystems
- **THEN** both calls complete after the subsystems have stopped, neither throws, and no subsystem's stop runs twice

#### Scenario: Stop again after a failed stop
- **WHEN** a subsystem raises an error while the first stop runs, and stop is called again after the first call has failed
- **THEN** the first call raises that error after the other subsystems were stopped, the second call completes without error, and no subsystem's stop runs twice

#### Scenario: Concurrent stop while the first fails
- **WHEN** a second stop is called while a first stop is running in which a subsystem raises an error
- **THEN** the first call raises that error, the second call completes without error after the first has finished, and no subsystem's stop runs twice

#### Scenario: Pipeline stopped before start
- **WHEN** a pipeline subsystem that was never started is stopped
- **THEN** the stop completes at once without error
