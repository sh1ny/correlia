BEGIN;

--
-- ACTION ALTER TABLE
--
ALTER TABLE "ingest_source" DROP COLUMN "tokenDigest";
ALTER TABLE "ingest_source" ADD COLUMN "kind" text NOT NULL DEFAULT 'alertmanager'::text;
--
-- ACTION CREATE TABLE
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
-- ACTION CREATE TABLE
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
-- MIGRATION VERSION FOR correlia
--
INSERT INTO "serverpod_migrations" ("module", "version", "timestamp")
    VALUES ('correlia', '20261118163655466-source-secrets', now())
    ON CONFLICT ("module")
    DO UPDATE SET "version" = '20261118163655466-source-secrets', "timestamp" = now();

--
-- MIGRATION VERSION FOR serverpod
--
INSERT INTO "serverpod_migrations" ("module", "version", "timestamp")
    VALUES ('serverpod', '20260824182259319', now())
    ON CONFLICT ("module")
    DO UPDATE SET "version" = '20260824182259319', "timestamp" = now();


COMMIT;
