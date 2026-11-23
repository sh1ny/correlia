BEGIN;

--
-- Class AlertRow as table alerts
--
CREATE TABLE "alerts" (
    "id" bigserial PRIMARY KEY,
    "tenant" text NOT NULL,
    "fingerprint" text NOT NULL,
    "status" text NOT NULL,
    "severity" text NOT NULL,
    "summary" text NOT NULL,
    "sourceInstance" text NOT NULL,
    "firingSince" timestamp without time zone,
    "generatorUrl" text,
    "fenceEffectiveSeconds" bigint NOT NULL,
    "fenceEffectiveNanos" bigint NOT NULL,
    "fenceObservedSeconds" bigint NOT NULL,
    "fenceObservedNanos" bigint NOT NULL,
    "fenceEventId" text NOT NULL,
    "lastObservedAt" timestamp without time zone NOT NULL,
    "version" bigint NOT NULL,
    "createdAt" timestamp without time zone NOT NULL,
    "updatedAt" timestamp without time zone NOT NULL
);

-- Indexes
CREATE UNIQUE INDEX "alerts_tenant_fingerprint_idx" ON "alerts" USING btree ("tenant", "fingerprint");

--
-- Class DeliveryAttempt as table delivery_attempts
--
CREATE TABLE "delivery_attempts" (
    "id" bigserial PRIMARY KEY,
    "outboxCreatedAt" timestamp without time zone NOT NULL,
    "deliveryId" uuid NOT NULL,
    "attemptNumber" bigint NOT NULL,
    "claimId" uuid NOT NULL,
    "startedAt" timestamp without time zone NOT NULL,
    "finishedAt" timestamp without time zone,
    "outcome" text NOT NULL,
    "errorClass" text
);

-- Indexes
CREATE UNIQUE INDEX "delivery_attempt_identity_idx" ON "delivery_attempts" USING btree ("outboxCreatedAt", "deliveryId", "attemptNumber");

--
-- Class Icinga2AdmittedBatch as table icinga2_admitted_batch
--
CREATE TABLE "icinga2_admitted_batch" (
    "id" bigserial PRIMARY KEY,
    "sourceId" uuid NOT NULL,
    "batchId" uuid NOT NULL,
    "admittedAt" timestamp without time zone NOT NULL
);

-- Indexes
CREATE UNIQUE INDEX "icinga2_admitted_batch_source_id_idx" ON "icinga2_admitted_batch" USING btree ("sourceId", "batchId");
CREATE INDEX "icinga2_admitted_batch_expiry_idx" ON "icinga2_admitted_batch" USING btree ("admittedAt");

--
-- Class Icinga2StreamLeaseRow as table icinga2_stream_lease
--
CREATE TABLE "icinga2_stream_lease" (
    "id" bigserial PRIMARY KEY,
    "sourceId" uuid NOT NULL,
    "holder" text NOT NULL,
    "generation" bigint NOT NULL,
    "expiresAt" timestamp without time zone NOT NULL
);

-- Indexes
CREATE UNIQUE INDEX "icinga2_stream_lease__sourceId__unique_idx" ON "icinga2_stream_lease" USING btree ("sourceId");

--
-- Class Icinga2StreamResyncRow as table icinga2_stream_resync
--
CREATE TABLE "icinga2_stream_resync" (
    "id" bigserial PRIMARY KEY,
    "sourceId" uuid NOT NULL,
    "requestSeq" bigint NOT NULL DEFAULT 0
);

-- Indexes
CREATE UNIQUE INDEX "icinga2_stream_resync__sourceId__unique_idx" ON "icinga2_stream_resync" USING btree ("sourceId");

--
-- Class Icinga2StreamStatusRow as table icinga2_stream_status
--
CREATE TABLE "icinga2_stream_status" (
    "id" bigserial PRIMARY KEY,
    "sourceId" uuid NOT NULL,
    "state" text NOT NULL,
    "connectionId" text,
    "connectionSeq" bigint NOT NULL DEFAULT 0,
    "connectedAt" timestamp without time zone,
    "lastEventAt" timestamp without time zone,
    "gapCount" bigint NOT NULL DEFAULT 0,
    "lastGapSeq" bigint NOT NULL DEFAULT 0,
    "lastGapAt" timestamp without time zone,
    "oversizeLines" bigint NOT NULL DEFAULT 0,
    "lagMs" bigint,
    "lastErrorClass" text,
    "servedResyncSeq" bigint NOT NULL DEFAULT 0,
    "syncTimeoutsInARow" bigint NOT NULL DEFAULT 0,
    "currentSyncId" uuid,
    "lastSyncId" uuid
);

-- Indexes
CREATE UNIQUE INDEX "icinga2_stream_status__sourceId__unique_idx" ON "icinga2_stream_status" USING btree ("sourceId");

--
-- Class IngestActiveConfig as table ingest_active_config
--
CREATE TABLE "ingest_active_config" (
    "id" bigserial PRIMARY KEY,
    "singleton" bigint NOT NULL,
    "snapshotId" text NOT NULL
);

-- Indexes
CREATE UNIQUE INDEX "ingest_active_config__singleton__unique_idx" ON "ingest_active_config" USING btree ("singleton");

--
-- Class IngestConfigSnapshot as table ingest_config_snapshot
--
CREATE TABLE "ingest_config_snapshot" (
    "id" bigserial PRIMARY KEY,
    "snapshotId" text NOT NULL,
    "revision" bigint NOT NULL,
    "publicJson" text NOT NULL
);

-- Indexes
CREATE UNIQUE INDEX "ingest_config_snapshot__snapshotId__unique_idx" ON "ingest_config_snapshot" USING btree ("snapshotId");
CREATE UNIQUE INDEX "ingest_config_snapshot__revision__unique_idx" ON "ingest_config_snapshot" USING btree ("revision");

--
-- Class IngestSecretCommitment as table ingest_secret_commitment
--
CREATE TABLE "ingest_secret_commitment" (
    "id" bigserial PRIMARY KEY,
    "reference" text NOT NULL,
    "digest" text NOT NULL
);

-- Indexes
CREATE UNIQUE INDEX "ingest_secret_commitment__reference__unique_idx" ON "ingest_secret_commitment" USING btree ("reference");

--
-- Class IngestSourceRow as table ingest_source
--
CREATE TABLE "ingest_source" (
    "id" bigserial PRIMARY KEY,
    "sourceId" uuid NOT NULL,
    "kind" text NOT NULL DEFAULT 'alertmanager'::text,
    "mode" text NOT NULL DEFAULT 'webhook'::text,
    "enabled" boolean NOT NULL,
    "allowPathToken" boolean NOT NULL
);

-- Indexes
CREATE UNIQUE INDEX "ingest_source__sourceId__unique_idx" ON "ingest_source" USING btree ("sourceId");

--
-- Class IngestSourceCredential as table ingest_source_credential
--
CREATE TABLE "ingest_source_credential" (
    "id" bigserial PRIMARY KEY,
    "sourceId" uuid NOT NULL,
    "reference" text NOT NULL,
    "type" text NOT NULL,
    "digest" text NOT NULL,
    "notBefore" timestamp without time zone,
    "notAfter" timestamp without time zone
);

-- Indexes
CREATE UNIQUE INDEX "ingest_source_credential_source_ref" ON "ingest_source_credential" USING btree ("sourceId", "reference");

--
-- Class ObservationKeyRow as table observation_keys
--
CREATE TABLE "observation_keys" (
    "id" bigserial PRIMARY KEY,
    "eventId" uuid NOT NULL,
    "fingerprint" text NOT NULL,
    "sourceTime" timestamp without time zone NOT NULL,
    "firstSeenAt" timestamp without time zone NOT NULL,
    "disposition" text NOT NULL
);

-- Indexes
CREATE UNIQUE INDEX "observation_keys__eventId__unique_idx" ON "observation_keys" USING btree ("eventId");

--
-- Class PipelineFailure as table pipeline_failures
--
CREATE TABLE "pipeline_failures" (
    "id" bigserial PRIMARY KEY,
    "rawObservedAt" timestamp without time zone NOT NULL,
    "rawId" uuid NOT NULL,
    "configSnapshotId" text,
    "errorClass" text NOT NULL,
    "fieldPath" text,
    "createdAt" timestamp without time zone NOT NULL
);

--
-- Class PluginDefinitionHealth as table plugin_definition_health
--
CREATE TABLE "plugin_definition_health" (
    "id" bigserial PRIMARY KEY,
    "hostInstanceId" text NOT NULL,
    "outputId" text NOT NULL,
    "definitionDigest" text NOT NULL,
    "failureTimes" text NOT NULL,
    "backoffStep" bigint NOT NULL,
    "nextStartAt" timestamp without time zone,
    "circuit" text NOT NULL,
    "nextProbeAt" timestamp without time zone,
    "lastErrorClass" text
);

-- Indexes
CREATE UNIQUE INDEX "plugin_definition_health_owner_definition_idx" ON "plugin_definition_health" USING btree ("hostInstanceId", "outputId", "definitionDigest");

--
-- Class PluginInstanceStatus as table plugin_instance_status
--
CREATE TABLE "plugin_instance_status" (
    "id" bigserial PRIMARY KEY,
    "hostInstanceId" text NOT NULL,
    "outputId" text NOT NULL,
    "definitionDigest" text NOT NULL,
    "state" text NOT NULL,
    "pluginName" text,
    "pluginVersion" text,
    "pid" bigint,
    "restartCount" bigint NOT NULL,
    "crashesInWindow" bigint NOT NULL,
    "lastErrorClass" text,
    "lastPluginErrorClass" text,
    "version" bigint NOT NULL,
    "heartbeatAt" timestamp without time zone NOT NULL
);

-- Indexes
CREATE UNIQUE INDEX "plugin_instance_status_owner_definition_idx" ON "plugin_instance_status" USING btree ("hostInstanceId", "outputId", "definitionDigest");

--
-- Class SecretRecord as table secret_record
--
CREATE TABLE "secret_record" (
    "id" bigserial PRIMARY KEY,
    "reference" text NOT NULL,
    "algorithm" text NOT NULL,
    "nonce" bytea NOT NULL,
    "ciphertext" bytea NOT NULL,
    "commitment" text NOT NULL,
    "keyCommitment" text NOT NULL,
    "createdAt" timestamp without time zone NOT NULL
);

-- Indexes
CREATE UNIQUE INDEX "secret_record__reference__unique_idx" ON "secret_record" USING btree ("reference");

--
-- Class TransportKey as table transport_keys
--
CREATE TABLE "transport_keys" (
    "id" bigserial PRIMARY KEY,
    "sourceId" uuid NOT NULL,
    "key" text NOT NULL,
    "bodySha256" text NOT NULL,
    "firstSeenAt" timestamp without time zone NOT NULL,
    "expiresAt" timestamp without time zone NOT NULL,
    "rawObservedAt" timestamp without time zone NOT NULL,
    "rawId" uuid NOT NULL
);

-- Indexes
CREATE UNIQUE INDEX "transport_source_key_idx" ON "transport_keys" USING btree ("sourceId", "key");

--
-- Class CloudStorageEntry as table serverpod_cloud_storage
--
CREATE TABLE "serverpod_cloud_storage" (
    "id" bigserial PRIMARY KEY,
    "storageId" text NOT NULL,
    "path" text NOT NULL,
    "addedTime" timestamp without time zone NOT NULL,
    "expiration" timestamp without time zone,
    "byteData" bytea NOT NULL,
    "verified" boolean NOT NULL,
    "contentType" text,
    "cacheControl" text,
    "contentDisposition" text,
    "contentEncoding" text,
    "customMetadata" text
);

-- Indexes
CREATE UNIQUE INDEX "serverpod_cloud_storage_path_idx" ON "serverpod_cloud_storage" USING btree ("storageId", "path");
CREATE INDEX "serverpod_cloud_storage_expiration" ON "serverpod_cloud_storage" USING btree ("expiration");

--
-- Class CloudStorageDirectDownloadEntry as table serverpod_cloud_storage_direct_download
--
CREATE TABLE "serverpod_cloud_storage_direct_download" (
    "id" bigserial PRIMARY KEY,
    "storageId" text NOT NULL,
    "path" text NOT NULL,
    "expiration" timestamp without time zone NOT NULL,
    "authKey" text NOT NULL,
    "downloadFileName" text,
    "contentType" text
);

-- Indexes
CREATE UNIQUE INDEX "serverpod_cloud_storage_direct_download_auth_key" ON "serverpod_cloud_storage_direct_download" USING btree ("authKey");
CREATE INDEX "serverpod_cloud_storage_direct_download_expiration" ON "serverpod_cloud_storage_direct_download" USING btree ("expiration");

--
-- Class CloudStorageDirectUploadEntry as table serverpod_cloud_storage_direct_upload
--
CREATE TABLE "serverpod_cloud_storage_direct_upload" (
    "id" bigserial PRIMARY KEY,
    "storageId" text NOT NULL,
    "path" text NOT NULL,
    "expiration" timestamp without time zone NOT NULL,
    "authKey" text NOT NULL,
    "maxFileSize" bigint NOT NULL DEFAULT 10485760,
    "contentLength" bigint,
    "preventOverwrite" boolean NOT NULL DEFAULT false,
    "contentType" text,
    "cacheControl" text,
    "contentDisposition" text,
    "contentEncoding" text,
    "customMetadata" text
);

-- Indexes
CREATE UNIQUE INDEX "serverpod_cloud_storage_direct_upload_storage_path" ON "serverpod_cloud_storage_direct_upload" USING btree ("storageId", "path");

--
-- Class FutureCallEntry as table serverpod_future_call
--
CREATE TABLE "serverpod_future_call" (
    "id" bigserial PRIMARY KEY,
    "name" text NOT NULL,
    "time" timestamp without time zone NOT NULL,
    "serializedObject" text,
    "serverId" text NOT NULL,
    "identifier" text,
    "scheduling" json
);

-- Indexes
CREATE INDEX "serverpod_future_call_time_idx" ON "serverpod_future_call" USING btree ("time");
CREATE INDEX "serverpod_future_call_serverId_idx" ON "serverpod_future_call" USING btree ("serverId");
CREATE INDEX "serverpod_future_call_identifier_idx" ON "serverpod_future_call" USING btree ("identifier");

--
-- Class FutureCallClaimEntry as table serverpod_future_call_claim
--
CREATE TABLE "serverpod_future_call_claim" (
    "id" bigserial PRIMARY KEY,
    "futureCallId" bigint,
    "lastHeartbeatTime" timestamp without time zone NOT NULL
);

-- Indexes
CREATE UNIQUE INDEX "future_call_unique_idx" ON "serverpod_future_call_claim" USING btree ("futureCallId");

--
-- Class ServerHealthConnectionInfo as table serverpod_health_connection_info
--
CREATE TABLE "serverpod_health_connection_info" (
    "id" bigserial PRIMARY KEY,
    "serverId" text NOT NULL,
    "timestamp" timestamp without time zone NOT NULL,
    "active" bigint NOT NULL,
    "closing" bigint NOT NULL,
    "idle" bigint NOT NULL,
    "granularity" bigint NOT NULL
);

-- Indexes
CREATE UNIQUE INDEX "serverpod_health_connection_info_timestamp_idx" ON "serverpod_health_connection_info" USING btree ("timestamp", "serverId", "granularity");

--
-- Class ServerHealthMetric as table serverpod_health_metric
--
CREATE TABLE "serverpod_health_metric" (
    "id" bigserial PRIMARY KEY,
    "name" text NOT NULL,
    "serverId" text NOT NULL,
    "timestamp" timestamp without time zone NOT NULL,
    "isHealthy" boolean NOT NULL,
    "value" double precision NOT NULL,
    "granularity" bigint NOT NULL
);

-- Indexes
CREATE UNIQUE INDEX "serverpod_health_metric_timestamp_idx" ON "serverpod_health_metric" USING btree ("timestamp", "serverId", "name", "granularity");

--
-- Class LogEntry as table serverpod_log
--
CREATE TABLE "serverpod_log" (
    "id" bigserial PRIMARY KEY,
    "sessionLogId" bigint NOT NULL,
    "messageId" bigint,
    "reference" text,
    "serverId" text NOT NULL,
    "time" timestamp without time zone NOT NULL,
    "logLevel" bigint NOT NULL,
    "message" text NOT NULL,
    "error" text,
    "stackTrace" text,
    "order" bigint NOT NULL
);

-- Indexes
CREATE INDEX "serverpod_log_sessionLogId_idx" ON "serverpod_log" USING btree ("sessionLogId", "order");

--
-- Class MessageLogEntry as table serverpod_message_log
--
CREATE TABLE "serverpod_message_log" (
    "id" bigserial PRIMARY KEY,
    "sessionLogId" bigint NOT NULL,
    "serverId" text NOT NULL,
    "messageId" bigint NOT NULL,
    "endpoint" text NOT NULL,
    "messageName" text NOT NULL,
    "duration" double precision NOT NULL,
    "error" text,
    "stackTrace" text,
    "slow" boolean NOT NULL,
    "order" bigint NOT NULL
);

-- Indexes
CREATE INDEX "serverpod_message_log_sessionLogId_idx" ON "serverpod_message_log" USING btree ("sessionLogId", "order");

--
-- Class MethodInfo as table serverpod_method
--
CREATE TABLE "serverpod_method" (
    "id" bigserial PRIMARY KEY,
    "endpoint" text NOT NULL,
    "method" text NOT NULL
);

-- Indexes
CREATE UNIQUE INDEX "serverpod_method_endpoint_method_idx" ON "serverpod_method" USING btree ("endpoint", "method");

--
-- Class DatabaseMigrationVersion as table serverpod_migrations
--
CREATE TABLE "serverpod_migrations" (
    "id" bigserial PRIMARY KEY,
    "module" text NOT NULL,
    "version" text NOT NULL,
    "timestamp" timestamp without time zone
);

-- Indexes
CREATE UNIQUE INDEX "serverpod_migrations_ids" ON "serverpod_migrations" USING btree ("module");

--
-- Class QueryLogEntry as table serverpod_query_log
--
CREATE TABLE "serverpod_query_log" (
    "id" bigserial PRIMARY KEY,
    "serverId" text NOT NULL,
    "sessionLogId" bigint NOT NULL,
    "messageId" bigint,
    "query" text NOT NULL,
    "duration" double precision NOT NULL,
    "numRows" bigint,
    "error" text,
    "stackTrace" text,
    "slow" boolean NOT NULL,
    "order" bigint NOT NULL
);

-- Indexes
CREATE INDEX "serverpod_query_log_sessionLogId_idx" ON "serverpod_query_log" USING btree ("sessionLogId", "order");

--
-- Class ReadWriteTestEntry as table serverpod_readwrite_test
--
CREATE TABLE "serverpod_readwrite_test" (
    "id" bigserial PRIMARY KEY,
    "number" bigint NOT NULL
);

--
-- Class RuntimeSettings as table serverpod_runtime_settings
--
CREATE TABLE "serverpod_runtime_settings" (
    "id" bigserial PRIMARY KEY,
    "logSettings" json NOT NULL,
    "logSettingsOverrides" json NOT NULL,
    "logServiceCalls" boolean NOT NULL,
    "logMalformedCalls" boolean NOT NULL
);

--
-- Class SessionLogEntry as table serverpod_session_log
--
CREATE TABLE "serverpod_session_log" (
    "id" bigserial PRIMARY KEY,
    "serverId" text NOT NULL,
    "time" timestamp without time zone NOT NULL,
    "module" text,
    "endpoint" text,
    "method" text,
    "duration" double precision,
    "numQueries" bigint,
    "slow" boolean,
    "error" text,
    "stackTrace" text,
    "authenticatedUserId" bigint,
    "userId" text,
    "isOpen" boolean,
    "touched" timestamp without time zone NOT NULL
);

-- Indexes
CREATE INDEX "serverpod_session_log_serverid_idx" ON "serverpod_session_log" USING btree ("serverId");
CREATE INDEX "serverpod_session_log_time_idx" ON "serverpod_session_log" USING btree ("time");
CREATE INDEX "serverpod_session_log_touched_idx" ON "serverpod_session_log" USING btree ("touched");
CREATE INDEX "serverpod_session_log_isopen_idx" ON "serverpod_session_log" USING btree ("isOpen");

--
-- Foreign relations for "serverpod_future_call_claim" table
--
ALTER TABLE ONLY "serverpod_future_call_claim"
    ADD CONSTRAINT "serverpod_future_call_claim_fk_0"
    FOREIGN KEY("futureCallId")
    REFERENCES "serverpod_future_call"("id")
    ON DELETE CASCADE
    ON UPDATE NO ACTION;

--
-- Foreign relations for "serverpod_log" table
--
ALTER TABLE ONLY "serverpod_log"
    ADD CONSTRAINT "serverpod_log_fk_0"
    FOREIGN KEY("sessionLogId")
    REFERENCES "serverpod_session_log"("id")
    ON DELETE CASCADE
    ON UPDATE NO ACTION;

--
-- Foreign relations for "serverpod_message_log" table
--
ALTER TABLE ONLY "serverpod_message_log"
    ADD CONSTRAINT "serverpod_message_log_fk_0"
    FOREIGN KEY("sessionLogId")
    REFERENCES "serverpod_session_log"("id")
    ON DELETE CASCADE
    ON UPDATE NO ACTION;

--
-- Foreign relations for "serverpod_query_log" table
--
ALTER TABLE ONLY "serverpod_query_log"
    ADD CONSTRAINT "serverpod_query_log_fk_0"
    FOREIGN KEY("sessionLogId")
    REFERENCES "serverpod_session_log"("id")
    ON DELETE CASCADE
    ON UPDATE NO ACTION;


--
-- MIGRATION VERSION FOR correlia
--
INSERT INTO "serverpod_migrations" ("module", "version", "timestamp")
    VALUES ('correlia', '20261123201822967-icinga2-stream-admission', now())
    ON CONFLICT ("module")
    DO UPDATE SET "version" = '20261123201822967-icinga2-stream-admission', "timestamp" = now();

--
-- MIGRATION VERSION FOR serverpod
--
INSERT INTO "serverpod_migrations" ("module", "version", "timestamp")
    VALUES ('serverpod', '20260824182259319', now())
    ON CONFLICT ("module")
    DO UPDATE SET "version" = '20260824182259319', "timestamp" = now();


COMMIT;
