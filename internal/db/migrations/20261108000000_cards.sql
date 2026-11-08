-- migrate:up
-- The family's loyalty cards: a name, a colour, a barcode (format and value) and, when the
-- server fetched it, the shop's logo with the stamp of the card.logo that brought it. owner_person_id null is the household's card; set, one
-- person's, filtered by scope like a personal list. Written by the fold from card.* events.
CREATE TABLE cards (
  id               TEXT PRIMARY KEY,
  household_id     TEXT NOT NULL REFERENCES households(id) ON DELETE CASCADE,
  name             TEXT NOT NULL,
  colour           TEXT NOT NULL DEFAULT '',
  owner_person_id  TEXT,
  format           TEXT NOT NULL,
  value            TEXT NOT NULL,
  domain           TEXT,
  logo_id          TEXT,
  logo_hlc         TEXT,
  updated_hlc      TEXT,
  archived_at      INTEGER
);
CREATE INDEX cards_household ON cards(household_id);

-- migrate:down
DROP TABLE cards;
