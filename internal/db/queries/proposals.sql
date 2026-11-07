-- name: ListProposals :many
SELECT * FROM proposals WHERE household_id = ? ORDER BY id;

-- name: DeleteProposalsForKey :exec
DELETE FROM proposals
WHERE household_id = @household_id AND home_id = @home_id
  AND item_id IN (SELECT value FROM json_each(CAST(@item_ids AS TEXT)));

-- name: DeleteProposalsForItems :exec
DELETE FROM proposals
WHERE household_id = @household_id
  AND item_id IN (SELECT value FROM json_each(CAST(@item_ids AS TEXT)));

-- name: InsertProposal :exec
INSERT INTO proposals (id, household_id, home_id, item_id, state, photo_id, proposed_hlc, closed_hlc)
VALUES (?, ?, ?, ?, ?, ?, ?, ?)
ON CONFLICT(id) DO UPDATE SET
  home_id = excluded.home_id, item_id = excluded.item_id, state = excluded.state, photo_id = excluded.photo_id,
  proposed_hlc = excluded.proposed_hlc, closed_hlc = excluded.closed_hlc;
