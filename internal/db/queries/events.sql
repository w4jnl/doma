-- name: NextSeq :one
SELECT COALESCE(MAX(seq), 0) + 1 FROM events WHERE household_id = ?;

-- name: InsertEvent :exec
INSERT INTO events (household_id, seq, id, person_id, credential_id, hlc, kind, payload, received_at)
VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);

-- name: EventsSince :many
SELECT * FROM events WHERE household_id = ? AND seq > ? ORDER BY seq LIMIT ?;

-- name: ItemEvents :many
SELECT * FROM events
WHERE household_id = ? AND kind IN ('item.named', 'item.renamed', 'item.merged')
ORDER BY hlc;

-- name: ItemEventsFor :many
-- The flag, staple and trip events that name one of the item ids, given as
-- a JSON array.
SELECT * FROM events
WHERE household_id = @household_id
  AND (
    (kind IN ('flag.set', 'staple.added', 'staple.removed')
      AND json_extract(payload, '$.item_id') IN (SELECT value FROM json_each(CAST(@item_ids AS TEXT))))
    OR (kind = 'trip.arrived'
      AND EXISTS (SELECT 1 FROM json_each(payload, '$.moved') AS m
                  WHERE m.value IN (SELECT value FROM json_each(CAST(@item_ids AS TEXT)))))
  )
ORDER BY hlc;

-- name: EntryEventsForKey :many
-- Every event the fold replays for one (list, item) key, in hlc order: the
-- entry events of the item and its merged ids (any item when any_item is
-- set), the clears of the list, and, when the list is the default list,
-- the out flags and trips that name the item.
SELECT * FROM events
WHERE household_id = @household_id
  AND (
    (kind IN ('entry.added', 'entry.edited', 'entry.checked', 'entry.unchecked', 'entry.moved')
      AND json_extract(payload, '$.list_id') = @list_id
      AND (CAST(@any_item AS INTEGER) = 1
           OR json_extract(payload, '$.item_id') IN (SELECT value FROM json_each(CAST(@item_ids AS TEXT)))))
    OR (kind = 'entry.cleared' AND json_extract(payload, '$.list_id') = @list_id)
    OR (kind = 'flag.set' AND CAST(@is_default AS INTEGER) = 1
      AND json_extract(payload, '$.state') = 'out'
      AND (CAST(@any_item AS INTEGER) = 1
           OR json_extract(payload, '$.item_id') IN (SELECT value FROM json_each(CAST(@item_ids AS TEXT)))))
    OR (kind = 'trip.arrived' AND CAST(@is_default AS INTEGER) = 1
      AND (CAST(@any_item AS INTEGER) = 1
           OR EXISTS (SELECT 1 FROM json_each(payload, '$.moved') AS m
                      WHERE m.value IN (SELECT value FROM json_each(CAST(@item_ids AS TEXT))))))
  )
ORDER BY hlc;

-- name: EntryListIDs :many
-- The lists with entry events naming one of the item ids.
SELECT DISTINCT CAST(json_extract(payload, '$.list_id') AS TEXT) AS list_id FROM events
WHERE household_id = @household_id
  AND kind IN ('entry.added', 'entry.edited', 'entry.checked', 'entry.unchecked', 'entry.moved')
  AND json_extract(payload, '$.item_id') IN (SELECT value FROM json_each(CAST(@item_ids AS TEXT)))
ORDER BY 1;
