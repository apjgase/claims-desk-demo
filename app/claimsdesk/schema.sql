-- Claims Desk: one table. Runs as the application role, inside its own schema,
-- so it works whether the database was created by install.sh or by NDB.
-- Safe to re-run. PostgreSQL 10 or later.

CREATE TABLE IF NOT EXISTS claims (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    -- Set by trigger claims_claim_number. Tables created by 0.3.0 and earlier
    -- have a generated column here instead, which needs PostgreSQL 12.
    claim_number    text          NOT NULL,
    policy_number   text          NOT NULL,
    claimant_name   text          NOT NULL,
    contact_email   text,
    loss_date       date          NOT NULL,
    loss_type       text          NOT NULL
                    CHECK (loss_type IN ('Auto', 'Property', 'Travel', 'Health', 'Other')),
    amount          numeric(12,2) NOT NULL CHECK (amount >= 0),
    description     text          NOT NULL,
    status          text          NOT NULL DEFAULT 'SUBMITTED'
                    CHECK (status IN ('SUBMITTED', 'IN_REVIEW', 'APPROVED', 'REJECTED', 'PAID')),
    adjuster        text,
    -- Filled from stage 3 (Nutanix Files photo, Objects WORM packet); NULL in stage 1.
    photo_path      text,
    packet_url      text,
    -- The VM or pod that wrote the row, so the demo can show which tier served it.
    created_by_host text          NOT NULL,
    created_at      timestamptz   NOT NULL DEFAULT now(),
    updated_at      timestamptz   NOT NULL DEFAULT now(),
    CONSTRAINT claims_claim_number_key UNIQUE (claim_number)
);

CREATE INDEX IF NOT EXISTS claims_status_idx     ON claims (status);
CREATE INDEX IF NOT EXISTS claims_created_at_idx ON claims (created_at DESC);

CREATE OR REPLACE FUNCTION claims_claim_number() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    NEW.claim_number := 'CLM-' || CASE WHEN NEW.id < 1000000 THEN lpad(NEW.id::text, 6, '0')
                                       ELSE NEW.id::text END;
    RETURN NEW;
END
$$;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_trigger
                   WHERE tgname = 'claims_claim_number' AND tgrelid = 'claims'::regclass)
       AND EXISTS (SELECT 1 FROM information_schema.columns
                   WHERE table_schema = current_schema() AND table_name = 'claims'
                     AND column_name = 'claim_number' AND is_generated = 'NEVER') THEN
        CREATE TRIGGER claims_claim_number BEFORE INSERT ON claims
            FOR EACH ROW EXECUTE PROCEDURE claims_claim_number();
    END IF;
END
$$;
