-- name: ListEntries :many
SELECT * FROM entries WHERE household_id = ? ORDER BY id;

-- name: EntriesForKey :many
SELECT * FROM entries
WHERE household_id = @household_id AND list_id = @list_id
  AND item_id IN (SELECT value FROM json_each(CAST(@item_ids AS TEXT)))
ORDER BY id;

-- name: DeleteEntriesForKey :exec
DELETE FROM entries
WHERE household_id = @household_id AND list_id = @list_id
  AND item_id IN (SELECT value FROM json_each(CAST(@item_ids AS TEXT)));

-- name: InsertEntry :exec
INSERT INTO entries (id, household_id, list_id, item_id, note, qty, unit, for_home_id, sort, added_hlc, added_by, checked_hlc, checked_by, cleared_hlc)
VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);

-- name: ClearedEntriesForHome :many
SELECT * FROM entries
WHERE household_id = @household_id AND for_home_id = @home_id AND cleared_hlc IS NOT NULL
  AND item_id IN (SELECT value FROM json_each(CAST(@item_ids AS TEXT)))
ORDER BY id;
