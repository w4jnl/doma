CREATE TABLE "schema_migrations" (version varchar(128) primary key);
CREATE TABLE persons (
  id            TEXT PRIMARY KEY,
  display_name  TEXT NOT NULL,
  created_at    INTEGER NOT NULL,
  last_seen_at  INTEGER
);
CREATE TABLE credentials (
  id            TEXT PRIMARY KEY,
  person_id     TEXT NOT NULL REFERENCES persons(id) ON DELETE CASCADE,
  kind          TEXT NOT NULL CHECK (kind IN ('device_key', 'passkey', 'guest_link')),
  public_key    TEXT,
  hash          BLOB,
  label         TEXT NOT NULL DEFAULT '',
  platform      TEXT NOT NULL DEFAULT '',
  apns_token    TEXT,
  created_at    INTEGER NOT NULL,
  last_used_at  INTEGER,
  revoked_at    INTEGER
);
CREATE INDEX credentials_person ON credentials(person_id);
CREATE UNIQUE INDEX credentials_hash ON credentials(hash) WHERE hash IS NOT NULL;
CREATE TABLE households (
  id                 TEXT PRIMARY KEY,
  slug               TEXT NOT NULL UNIQUE,
  name               TEXT NOT NULL,
  timezone           TEXT NOT NULL,
  quota_devices      INTEGER,
  quota_photo_bytes  INTEGER,
  staleness_days     INTEGER,
  created_at         INTEGER NOT NULL
);
CREATE TABLE memberships (
  person_id     TEXT NOT NULL REFERENCES persons(id) ON DELETE CASCADE,
  household_id  TEXT NOT NULL REFERENCES households(id) ON DELETE CASCADE,
  role          TEXT NOT NULL CHECK (role IN ('owner', 'member', 'guest')),
  home_id       TEXT,
  list_id       TEXT,
  expires_at    INTEGER,
  created_at    INTEGER NOT NULL,
  PRIMARY KEY (person_id, household_id)
);
CREATE INDEX memberships_household ON memberships(household_id);
CREATE TABLE invites (
  id            TEXT PRIMARY KEY,
  household_id  TEXT NOT NULL REFERENCES households(id) ON DELETE CASCADE,
  role          TEXT NOT NULL CHECK (role IN ('owner', 'member')),
  token_hash    BLOB NOT NULL UNIQUE,
  created_by    TEXT,
  expires_at    INTEGER NOT NULL,
  used_by       TEXT,
  used_at       INTEGER,
  revoked_at    INTEGER
);
CREATE INDEX invites_household ON invites(household_id);
CREATE TABLE admin (
  id             INTEGER PRIMARY KEY CHECK (id = 1),
  login          TEXT NOT NULL,
  password_hash  TEXT NOT NULL,
  totp_secret    BLOB,
  created_at     INTEGER NOT NULL
);
CREATE TABLE events (
  household_id   TEXT NOT NULL REFERENCES households(id) ON DELETE CASCADE,
  seq            INTEGER NOT NULL,
  id             TEXT NOT NULL UNIQUE,
  person_id      TEXT NOT NULL,
  credential_id  TEXT NOT NULL,
  hlc            TEXT NOT NULL,
  kind           TEXT NOT NULL,
  payload        TEXT NOT NULL,
  received_at    INTEGER NOT NULL,
  PRIMARY KEY (household_id, seq)
);
CREATE INDEX events_entry_key ON events(household_id, json_extract(payload, '$.list_id'), json_extract(payload, '$.item_id'));
CREATE TABLE snapshots (
  household_id  TEXT NOT NULL REFERENCES households(id) ON DELETE CASCADE,
  seq           INTEGER NOT NULL,
  blob_path     TEXT NOT NULL,
  created_at    INTEGER NOT NULL,
  PRIMARY KEY (household_id, seq)
);
CREATE TABLE homes (
  id            TEXT PRIMARY KEY,
  household_id  TEXT NOT NULL REFERENCES households(id) ON DELETE CASCADE,
  name          TEXT NOT NULL,
  sort          INTEGER NOT NULL DEFAULT 0,
  archived_at   INTEGER,
  updated_hlc   TEXT
);
CREATE INDEX homes_household ON homes(household_id);
CREATE TABLE spots (
  id            TEXT PRIMARY KEY,
  household_id  TEXT NOT NULL REFERENCES households(id) ON DELETE CASCADE,
  home_id       TEXT NOT NULL,
  name          TEXT NOT NULL,
  sort          INTEGER NOT NULL DEFAULT 0,
  archived_at   INTEGER,
  updated_hlc   TEXT
);
CREATE INDEX spots_home ON spots(household_id, home_id);
CREATE TABLE items (
  id            TEXT PRIMARY KEY,
  household_id  TEXT NOT NULL REFERENCES households(id) ON DELETE CASCADE,
  name          TEXT NOT NULL,
  norm_name     TEXT,
  category      TEXT,
  last_used_at  INTEGER,
  use_count     INTEGER NOT NULL DEFAULT 0,
  archived_at   INTEGER,
  merged_into   TEXT,
  created_hlc   TEXT NOT NULL,
  updated_hlc   TEXT NOT NULL
);
CREATE UNIQUE INDEX items_norm ON items(household_id, norm_name) WHERE norm_name IS NOT NULL;
CREATE INDEX items_household ON items(household_id);
CREATE TABLE item_aliases (
  item_id       TEXT NOT NULL REFERENCES items(id) ON DELETE CASCADE,
  household_id  TEXT NOT NULL REFERENCES households(id) ON DELETE CASCADE,
  norm_name     TEXT NOT NULL,
  PRIMARY KEY (household_id, norm_name)
);
CREATE TABLE lists (
  id               TEXT PRIMARY KEY,
  household_id     TEXT NOT NULL REFERENCES households(id) ON DELETE CASCADE,
  name             TEXT NOT NULL,
  colour           TEXT NOT NULL DEFAULT '',
  owner_person_id  TEXT,
  sort             INTEGER NOT NULL DEFAULT 0,
  is_default       INTEGER NOT NULL DEFAULT 0,
  archived_at      INTEGER,
  updated_hlc      TEXT
);
CREATE INDEX lists_household ON lists(household_id);
CREATE TABLE entries (
  id            TEXT PRIMARY KEY,
  household_id  TEXT NOT NULL REFERENCES households(id) ON DELETE CASCADE,
  list_id       TEXT NOT NULL,
  item_id       TEXT NOT NULL,
  note          TEXT NOT NULL DEFAULT '',
  qty           REAL,
  unit          TEXT,
  for_home_id   TEXT,
  sort          REAL NOT NULL DEFAULT 0,
  added_hlc     TEXT NOT NULL,
  added_by      TEXT NOT NULL,
  checked_hlc   TEXT,
  checked_by    TEXT,
  cleared_hlc   TEXT
);
CREATE INDEX entries_key ON entries(household_id, list_id, item_id);
CREATE INDEX entries_item ON entries(household_id, item_id);
CREATE TABLE flags (
  household_id  TEXT NOT NULL REFERENCES households(id) ON DELETE CASCADE,
  home_id       TEXT NOT NULL,
  item_id       TEXT NOT NULL,
  state         TEXT NOT NULL CHECK (state IN ('have', 'low', 'out')),
  set_hlc       TEXT NOT NULL,
  set_by        TEXT NOT NULL,
  note          TEXT NOT NULL DEFAULT '',
  PRIMARY KEY (home_id, item_id)
);
CREATE INDEX flags_household ON flags(household_id, home_id);
CREATE TABLE staples (
  household_id  TEXT NOT NULL REFERENCES households(id) ON DELETE CASCADE,
  home_id       TEXT NOT NULL,
  item_id       TEXT NOT NULL,
  sort          INTEGER NOT NULL DEFAULT 0,
  added_hlc     TEXT,
  removed_hlc   TEXT,
  PRIMARY KEY (home_id, item_id)
);
CREATE INDEX staples_household ON staples(household_id, home_id);
CREATE TABLE photos (
  id            TEXT PRIMARY KEY,
  household_id  TEXT NOT NULL REFERENCES households(id) ON DELETE CASCADE,
  spot_id       TEXT NOT NULL,
  taken_hlc     TEXT NOT NULL,
  taken_by      TEXT NOT NULL,
  path          TEXT,
  thumb_path    TEXT,
  bytes         INTEGER NOT NULL DEFAULT 0,
  width         INTEGER NOT NULL DEFAULT 0,
  height        INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX photos_spot ON photos(household_id, spot_id);
CREATE TABLE trips (
  id            TEXT PRIMARY KEY,
  household_id  TEXT NOT NULL REFERENCES households(id) ON DELETE CASCADE,
  from_home_id  TEXT NOT NULL,
  to_home_id    TEXT NOT NULL,
  date          INTEGER NOT NULL,
  created_by    TEXT NOT NULL,
  arrived_at    INTEGER NOT NULL
);
CREATE INDEX trips_household ON trips(household_id);
CREATE TABLE push_log (
  household_id   TEXT NOT NULL REFERENCES households(id) ON DELETE CASCADE,
  credential_id  TEXT NOT NULL,
  sent_at        INTEGER NOT NULL,
  seq            INTEGER NOT NULL,
  PRIMARY KEY (household_id, credential_id)
);
-- Dbmate schema migrations
INSERT INTO "schema_migrations" (version) VALUES
  ('20261101000000');
