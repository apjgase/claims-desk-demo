-- Claims Desk: one table. Runs as the application role, inside its own schema,
-- so it works whether the database was created by install.sh or by NDB.
-- Safe to re-run.

CREATE TABLE IF NOT EXISTS claims (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    claim_number    text GENERATED ALWAYS AS (
                        'CLM-' || CASE WHEN id < 1000000 THEN lpad(id::text, 6, '0')
                                       ELSE id::text END
                    ) STORED,
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
