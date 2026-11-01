-- name: GetList :one
SELECT * FROM lists WHERE household_id = ? AND id = ?;

-- name: ListLists :many
SELECT * FROM lists WHERE household_id = ? ORDER BY id;

-- name: UpsertList :exec
INSERT INTO lists (id, household_id, name, colour, owner_person_id, sort, is_default, archived_at, updated_hlc)
VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
ON CONFLICT(id) DO UPDATE SET
  name = excluded.name, colour = excluded.colour, owner_person_id = excluded.owner_person_id, sort = excluded.sort,
  is_default = excluded.is_default, archived_at = excluded.archived_at, updated_hlc = excluded.updated_hlc;

-- name: DefaultListID :one
SELECT id FROM lists WHERE household_id = ? AND is_default = 1 ORDER BY id LIMIT 1;
