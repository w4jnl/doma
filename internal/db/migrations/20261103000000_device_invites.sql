-- migrate:up
-- A device invite is an invite bound to a person: accepting it adds a device to that person
-- instead of making a new one. The membership is the person's already, so the invite's role
-- is only what the page shows.
ALTER TABLE invites ADD COLUMN for_person_id TEXT REFERENCES persons(id) ON DELETE CASCADE;

-- migrate:down
ALTER TABLE invites DROP COLUMN for_person_id;
