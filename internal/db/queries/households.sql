-- name: InsertHousehold :exec
INSERT INTO households (id, slug, name, timezone, created_at) VALUES (?, ?, ?, ?, ?);

-- name: GetHousehold :one
SELECT * FROM households WHERE id = ?;

-- name: ListHouseholds :many
SELECT * FROM households ORDER BY name, id;

-- name: UpdateHousehold :exec
UPDATE households SET name = ?, timezone = ?, staleness_days = ? WHERE id = ?;

-- name: UpdateHouseholdQuotas :exec
UPDATE households SET quota_devices = ?, quota_photo_bytes = ? WHERE id = ?;

-- name: DeleteHousehold :exec
DELETE FROM households WHERE id = ?;
