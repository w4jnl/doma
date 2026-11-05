-- name: InsertPhoto :exec
INSERT INTO photos (id, household_id, spot_id, taken_hlc, taken_by, bytes, width, height)
VALUES (?, ?, ?, ?, ?, ?, ?, ?)
ON CONFLICT(id) DO NOTHING;

-- name: ListPhotos :many
SELECT * FROM photos WHERE household_id = ? ORDER BY id;

-- name: GetPhoto :one
SELECT * FROM photos WHERE household_id = ? AND id = ?;

-- name: SetPhotoFile :exec
UPDATE photos SET path = ?, thumb_path = ?, bytes = ?, width = ?, height = ?
WHERE household_id = ? AND id = ?;

-- name: ClearPhotoFile :exec
UPDATE photos SET path = NULL, thumb_path = NULL, bytes = 0
WHERE household_id = ? AND id = ?;

-- name: PhotoBytes :one
SELECT CAST(COALESCE(SUM(bytes), 0) AS INTEGER) FROM photos WHERE household_id = ? AND path IS NOT NULL;

-- name: ListSpotPhotos :many
SELECT * FROM photos WHERE household_id = ? AND spot_id = ? ORDER BY taken_hlc DESC, id DESC;

-- name: ListStoredPhotos :many
SELECT * FROM photos WHERE household_id = ? AND path IS NOT NULL ORDER BY id;
