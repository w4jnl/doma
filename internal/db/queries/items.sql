-- name: GetItem :one
SELECT * FROM items WHERE household_id = ? AND id = ?;

-- name: ListItems :many
SELECT * FROM items WHERE household_id = ? ORDER BY id;

-- name: UpsertItem :exec
INSERT INTO items (id, household_id, name, norm_name, category, last_used_at, use_count, archived_at, merged_into, created_hlc, updated_hlc)
VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
ON CONFLICT(id) DO UPDATE SET
  name = excluded.name, norm_name = excluded.norm_name, category = excluded.category,
  last_used_at = excluded.last_used_at, use_count = excluded.use_count, archived_at = excluded.archived_at,
  merged_into = excluded.merged_into, created_hlc = excluded.created_hlc, updated_hlc = excluded.updated_hlc;

-- name: RecountItemUsage :exec
UPDATE items SET
  use_count = (SELECT COUNT(*) FROM entries e WHERE e.household_id = items.household_id AND e.item_id = items.id),
  last_used_at = (SELECT MAX(CAST(substr(e.added_hlc, 1, 13) AS INTEGER)) FROM entries e WHERE e.household_id = items.household_id AND e.item_id = items.id)
WHERE items.household_id = ? AND items.id = ?;

-- name: DeleteAliases :exec
DELETE FROM item_aliases WHERE household_id = ?;

-- name: InsertAlias :exec
INSERT INTO item_aliases (item_id, household_id, norm_name) VALUES (?, ?, ?);

-- name: ListAliases :many
SELECT * FROM item_aliases WHERE household_id = ? ORDER BY norm_name;
