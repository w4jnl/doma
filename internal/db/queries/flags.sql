-- name: GetFlag :one
SELECT * FROM flags WHERE household_id = ? AND home_id = ? AND item_id = ?;

-- name: ListFlags :many
SELECT * FROM flags WHERE household_id = ? ORDER BY home_id, item_id;

-- name: UpsertFlag :exec
INSERT INTO flags (household_id, home_id, item_id, state, set_hlc, set_by, note)
VALUES (?, ?, ?, ?, ?, ?, ?)
ON CONFLICT(home_id, item_id) DO UPDATE SET
  state = excluded.state, set_hlc = excluded.set_hlc, set_by = excluded.set_by, note = excluded.note;

-- name: DeleteFlag :exec
DELETE FROM flags WHERE household_id = ? AND home_id = ? AND item_id = ?;

-- name: DeleteFlagsForItems :exec
DELETE FROM flags
WHERE household_id = @household_id
  AND item_id IN (SELECT value FROM json_each(CAST(@item_ids AS TEXT)));

-- name: GetStaple :one
SELECT * FROM staples WHERE household_id = ? AND home_id = ? AND item_id = ?;

-- name: ListStaples :many
SELECT * FROM staples WHERE household_id = ? ORDER BY home_id, item_id;

-- name: UpsertStaple :exec
INSERT INTO staples (household_id, home_id, item_id, sort, added_hlc, removed_hlc)
VALUES (?, ?, ?, ?, ?, ?)
ON CONFLICT(home_id, item_id) DO UPDATE SET
  sort = excluded.sort, added_hlc = excluded.added_hlc, removed_hlc = excluded.removed_hlc;

-- name: DeleteStaplesForItems :exec
DELETE FROM staples
WHERE household_id = @household_id
  AND item_id IN (SELECT value FROM json_each(CAST(@item_ids AS TEXT)));
