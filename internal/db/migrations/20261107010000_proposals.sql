-- migrate:up
-- What a vision model suggests after a photo: a flag change at a home for a member to accept
-- or decline. Open while closed_hlc is null; a flag written after it, a decline, or a newer
-- proposal for the same item closes it. Derived by the fold from flag.proposed and
-- proposal.declined, never edited by hand.
CREATE TABLE proposals (
  id            TEXT PRIMARY KEY,
  household_id  TEXT NOT NULL REFERENCES households(id) ON DELETE CASCADE,
  home_id       TEXT NOT NULL,
  item_id       TEXT NOT NULL,
  state         TEXT NOT NULL,
  photo_id      TEXT NOT NULL DEFAULT '',
  proposed_hlc  TEXT NOT NULL,
  closed_hlc    TEXT
);
CREATE INDEX proposals_key ON proposals(household_id, home_id, item_id);

-- migrate:down
DROP TABLE proposals;
