-- name: InsertSnapshot :exec
INSERT INTO snapshots (household_id, seq, blob_path, created_at) VALUES (?, ?, ?, ?);

-- name: NewestSnapshot :one
SELECT * FROM snapshots WHERE household_id = ? ORDER BY seq DESC LIMIT 1;

-- name: ListSnapshots :many
SELECT * FROM snapshots WHERE household_id = ? ORDER BY seq DESC;

-- name: DeleteSnapshot :exec
DELETE FROM snapshots WHERE household_id = ? AND seq = ?;

-- name: GetSnapshot :one
SELECT * FROM snapshots WHERE household_id = ? AND seq = ?;

-- name: DeleteEventsBefore :execrows
-- Retention: events at or below the newest snapshot that were received
-- before the cutoff.
DELETE FROM events WHERE household_id = ? AND seq <= ? AND received_at < ?;

-- name: LastSeq :one
SELECT CAST(COALESCE(MAX(seq), 0) AS INTEGER) FROM events WHERE household_id = ?;

-- name: CountEvents :one
SELECT COUNT(*) FROM events WHERE household_id = ?;

-- name: AllEvents :many
SELECT * FROM events WHERE household_id = ? ORDER BY seq;

-- name: CountHouseholds :one
-- tenancy: root -- the instance gauge
SELECT COUNT(*) FROM households;
