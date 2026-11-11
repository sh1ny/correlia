BEGIN;

--
-- ACTION CREATE TABLE
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
-- ACTION CREATE TABLE
--
CREATE TABLE "ingest_active_config" (
    "id" bigserial PRIMARY KEY,
    "singleton" bigint NOT NULL,
    "snapshotId" text NOT NULL
);

-- Indexes
CREATE UNIQUE INDEX "ingest_active_config__singleton__unique_idx" ON "ingest_active_config" USING btree ("singleton");

--
-- ACTION CREATE TABLE
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
-- ACTION CREATE TABLE
--
CREATE TABLE "ingest_secret_commitment" (
    "id" bigserial PRIMARY KEY,
    "reference" text NOT NULL,
    "digest" text NOT NULL
);

-- Indexes
CREATE UNIQUE INDEX "ingest_secret_commitment__reference__unique_idx" ON "ingest_secret_commitment" USING btree ("reference");

--
-- ACTION CREATE TABLE
--
CREATE TABLE "ingest_source" (
    "id" bigserial PRIMARY KEY,
    "sourceId" uuid NOT NULL,
    "tokenDigest" text NOT NULL,
    "enabled" boolean NOT NULL,
    "allowPathToken" boolean NOT NULL
);

-- Indexes
CREATE UNIQUE INDEX "ingest_source__sourceId__unique_idx" ON "ingest_source" USING btree ("sourceId");

--
-- ACTION CREATE TABLE
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
-- ACTION CREATE TABLE
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
-- ACTION CREATE TABLE
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
-- MIGRATION VERSION FOR correlia
--
INSERT INTO "serverpod_migrations" ("module", "version", "timestamp")
    VALUES ('correlia', '20261111210905779-ingest', now())
    ON CONFLICT ("module")
    DO UPDATE SET "version" = '20261111210905779-ingest', "timestamp" = now();

--
-- MIGRATION VERSION FOR serverpod
--
INSERT INTO "serverpod_migrations" ("module", "version", "timestamp")
    VALUES ('serverpod', '20260824182259319', now())
    ON CONFLICT ("module")
    DO UPDATE SET "version" = '20260824182259319', "timestamp" = now();


COMMIT;
