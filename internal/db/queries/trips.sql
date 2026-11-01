-- name: InsertTrip :exec
INSERT INTO trips (id, household_id, from_home_id, to_home_id, date, created_by, arrived_at)
VALUES (?, ?, ?, ?, ?, ?, ?)
ON CONFLICT(id) DO NOTHING;

-- name: ListTrips :many
SELECT * FROM trips WHERE household_id = ? ORDER BY id;
