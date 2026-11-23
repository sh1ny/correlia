BEGIN;

--
-- ACTION CREATE TABLE
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
-- ACTION CREATE TABLE
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
-- ACTION CREATE TABLE
--
CREATE TABLE "icinga2_stream_resync" (
    "id" bigserial PRIMARY KEY,
    "sourceId" uuid NOT NULL,
    "requestSeq" bigint NOT NULL DEFAULT 0
);

-- Indexes
CREATE UNIQUE INDEX "icinga2_stream_resync__sourceId__unique_idx" ON "icinga2_stream_resync" USING btree ("sourceId");

--
-- ACTION CREATE TABLE
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
