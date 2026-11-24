BEGIN;

--
-- ACTION ALTER TABLE
--
ALTER TABLE "ingest_source" ADD COLUMN "mode" text NOT NULL DEFAULT 'webhook'::text;

--
-- MIGRATION VERSION FOR correlia
--
INSERT INTO "serverpod_migrations" ("module", "version", "timestamp")
    VALUES ('correlia', '20261123174848287-icinga2-source-mode', now())
    ON CONFLICT ("module")
    DO UPDATE SET "version" = '20261123174848287-icinga2-source-mode', "timestamp" = now();

--
-- MIGRATION VERSION FOR serverpod
--
INSERT INTO "serverpod_migrations" ("module", "version", "timestamp")
    VALUES ('serverpod', '20260824182259319', now())
    ON CONFLICT ("module")
    DO UPDATE SET "version" = '20260824182259319', "timestamp" = now();


COMMIT;
