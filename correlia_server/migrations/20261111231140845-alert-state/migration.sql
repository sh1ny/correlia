BEGIN;

--
-- ACTION CREATE TABLE
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
-- MIGRATION VERSION FOR correlia
--
INSERT INTO "serverpod_migrations" ("module", "version", "timestamp")
    VALUES ('correlia', '20261111231140845-alert-state', now())
    ON CONFLICT ("module")
    DO UPDATE SET "version" = '20261111231140845-alert-state', "timestamp" = now();

--
-- MIGRATION VERSION FOR serverpod
--
INSERT INTO "serverpod_migrations" ("module", "version", "timestamp")
    VALUES ('serverpod', '20260824182259319', now())
    ON CONFLICT ("module")
    DO UPDATE SET "version" = '20260824182259319', "timestamp" = now();


COMMIT;
