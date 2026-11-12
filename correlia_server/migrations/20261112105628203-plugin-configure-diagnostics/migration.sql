BEGIN;

--
-- ACTION ALTER TABLE
--
ALTER TABLE "plugin_instance_status" ADD COLUMN "lastPluginErrorClass" text;

--
-- MIGRATION VERSION FOR correlia
--
INSERT INTO "serverpod_migrations" ("module", "version", "timestamp")
    VALUES ('correlia', '20261112105628203-plugin-configure-diagnostics', now())
    ON CONFLICT ("module")
    DO UPDATE SET "version" = '20261112105628203-plugin-configure-diagnostics', "timestamp" = now();

--
-- MIGRATION VERSION FOR serverpod
--
INSERT INTO "serverpod_migrations" ("module", "version", "timestamp")
    VALUES ('serverpod', '20260824182259319', now())
    ON CONFLICT ("module")
    DO UPDATE SET "version" = '20260824182259319', "timestamp" = now();


COMMIT;
