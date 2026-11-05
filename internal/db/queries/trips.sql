-- name: GetTrip :one
SELECT * FROM trips WHERE household_id = ? AND id = ?;

-- name: UpsertTrip :exec
INSERT INTO trips (id, household_id, from_home_id, to_home_id, date, created_by, list_id, updated_hlc, arrived_at, cancelled_at)
VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
ON CONFLICT(id) DO UPDATE SET
  from_home_id = excluded.from_home_id, to_home_id = excluded.to_home_id, date = excluded.date, created_by = excluded.created_by,
  list_id = excluded.list_id, updated_hlc = excluded.updated_hlc, arrived_at = excluded.arrived_at, cancelled_at = excluded.cancelled_at;

-- name: ListTrips :many
SELECT * FROM trips WHERE household_id = ? ORDER BY id;
