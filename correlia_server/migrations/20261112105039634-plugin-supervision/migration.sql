BEGIN;

--
-- ACTION CREATE TABLE
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
-- ACTION CREATE TABLE
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
    "version" bigint NOT NULL,
    "heartbeatAt" timestamp without time zone NOT NULL
);

-- Indexes
CREATE UNIQUE INDEX "plugin_instance_status_owner_definition_idx" ON "plugin_instance_status" USING btree ("hostInstanceId", "outputId", "definitionDigest");


--
-- MIGRATION VERSION FOR correlia
--
INSERT INTO "serverpod_migrations" ("module", "version", "timestamp")
    VALUES ('correlia', '20261112105039634-plugin-supervision', now())
    ON CONFLICT ("module")
    DO UPDATE SET "version" = '20261112105039634-plugin-supervision', "timestamp" = now();

--
-- MIGRATION VERSION FOR serverpod
--
INSERT INTO "serverpod_migrations" ("module", "version", "timestamp")
    VALUES ('serverpod', '20260824182259319', now())
    ON CONFLICT ("module")
    DO UPDATE SET "version" = '20260824182259319', "timestamp" = now();


COMMIT;
