-- migrate:up
-- A trip is planned before it is walked: from, to, a date and the list it shops on, shared
-- through trip.planned and last-writer-wins on updated_hlc; arrived_at comes with
-- trip.arrived, cancelled_at with trip.cancelled. A trip that was only ever arrived keeps the
-- arrival's wall as its date, as before. SQLite cannot loosen a NOT NULL, so the table is
-- rebuilt.
CREATE TABLE trips_new (
  id            TEXT PRIMARY KEY,
  household_id  TEXT NOT NULL REFERENCES households(id) ON DELETE CASCADE,
  from_home_id  TEXT NOT NULL DEFAULT '',
  to_home_id    TEXT NOT NULL DEFAULT '',
  date          INTEGER NOT NULL DEFAULT 0,
  created_by    TEXT NOT NULL DEFAULT '',
  list_id       TEXT,
  updated_hlc   TEXT,
  arrived_at    INTEGER,
  cancelled_at  INTEGER
);
INSERT INTO trips_new (id, household_id, from_home_id, to_home_id, date, created_by, arrived_at)
  SELECT id, household_id, from_home_id, to_home_id, date, created_by, arrived_at FROM trips;
DROP TABLE trips;
ALTER TABLE trips_new RENAME TO trips;
CREATE INDEX trips_household ON trips(household_id);

-- migrate:down
CREATE TABLE trips_old (
  id            TEXT PRIMARY KEY,
  household_id  TEXT NOT NULL REFERENCES households(id) ON DELETE CASCADE,
  from_home_id  TEXT NOT NULL,
  to_home_id    TEXT NOT NULL,
  date          INTEGER NOT NULL,
  created_by    TEXT NOT NULL,
  arrived_at    INTEGER NOT NULL
);
INSERT INTO trips_old (id, household_id, from_home_id, to_home_id, date, created_by, arrived_at)
  SELECT id, household_id, from_home_id, to_home_id, date, created_by, COALESCE(arrived_at, date) FROM trips WHERE arrived_at IS NOT NULL;
DROP TABLE trips;
ALTER TABLE trips_old RENAME TO trips;
CREATE INDEX trips_household ON trips(household_id);
