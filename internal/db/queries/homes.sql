-- name: GetHome :one
SELECT * FROM homes WHERE household_id = ? AND id = ?;

-- name: ListHomes :many
SELECT * FROM homes WHERE household_id = ? ORDER BY id;

-- name: UpsertHome :exec
INSERT INTO homes (id, household_id, name, sort, archived_at, updated_hlc)
VALUES (?, ?, ?, ?, ?, ?)
ON CONFLICT(id) DO UPDATE SET
  name = excluded.name, sort = excluded.sort, archived_at = excluded.archived_at, updated_hlc = excluded.updated_hlc;

-- name: GetSpot :one
SELECT * FROM spots WHERE household_id = ? AND id = ?;

-- name: ListSpots :many
SELECT * FROM spots WHERE household_id = ? ORDER BY id;

-- name: UpsertSpot :exec
INSERT INTO spots (id, household_id, home_id, name, sort, archived_at, updated_hlc)
VALUES (?, ?, ?, ?, ?, ?, ?)
ON CONFLICT(id) DO UPDATE SET
  home_id = excluded.home_id, name = excluded.name, sort = excluded.sort, archived_at = excluded.archived_at, updated_hlc = excluded.updated_hlc;
