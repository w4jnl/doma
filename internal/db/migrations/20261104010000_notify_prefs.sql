-- migrate:up
-- What a device wants to hear: the lists it muted (a JSON array of list ids) and whether a
-- cleared list is worth a word; and when it was last spoken to, so spoken pushes come at most
-- every two minutes and say everything since the last spoken one.
ALTER TABLE credentials ADD COLUMN muted_lists TEXT NOT NULL DEFAULT '[]';
ALTER TABLE credentials ADD COLUMN notify_clears INTEGER NOT NULL DEFAULT 1;
ALTER TABLE push_log ADD COLUMN spoken_at INTEGER;
ALTER TABLE push_log ADD COLUMN spoken_seq INTEGER;

-- migrate:down
ALTER TABLE push_log DROP COLUMN spoken_seq;
ALTER TABLE push_log DROP COLUMN spoken_at;
ALTER TABLE credentials DROP COLUMN notify_clears;
ALTER TABLE credentials DROP COLUMN muted_lists;
