-- name: InsertPerson :exec
INSERT INTO persons (id, display_name, created_at) VALUES (?, ?, ?);

-- name: GetPerson :one
SELECT * FROM persons WHERE id = ?;

-- name: TouchPerson :exec
UPDATE persons SET last_seen_at = ? WHERE id = ?;

-- name: UpdatePersonName :exec
UPDATE persons SET display_name = ? WHERE id = ?;

-- name: DeleteOrphanPersons :exec
-- A person with no household left goes, and their devices and device invites with them.
DELETE FROM persons WHERE id NOT IN (SELECT person_id FROM memberships);
