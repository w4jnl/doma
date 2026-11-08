-- name: GetCard :one
SELECT * FROM cards WHERE household_id = ? AND id = ?;

-- name: ListCards :many
SELECT * FROM cards WHERE household_id = ? ORDER BY id;

-- name: UpsertCard :exec
INSERT INTO cards (id, household_id, name, colour, owner_person_id, format, value, domain, logo_id, logo_hlc, updated_hlc, archived_at)
VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
ON CONFLICT(id) DO UPDATE SET
  name = excluded.name, colour = excluded.colour, owner_person_id = excluded.owner_person_id, format = excluded.format,
  value = excluded.value, domain = excluded.domain, logo_id = excluded.logo_id, logo_hlc = excluded.logo_hlc, updated_hlc = excluded.updated_hlc,
  archived_at = excluded.archived_at;
