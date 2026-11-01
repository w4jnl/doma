-- name: InsertPhoto :exec
INSERT INTO photos (id, household_id, spot_id, taken_hlc, taken_by, bytes, width, height)
VALUES (?, ?, ?, ?, ?, ?, ?, ?)
ON CONFLICT(id) DO NOTHING;

-- name: ListPhotos :many
SELECT * FROM photos WHERE household_id = ? ORDER BY id;
