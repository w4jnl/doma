-- name: InsertPerson :exec
INSERT INTO persons (id, display_name, created_at) VALUES (?, ?, ?);

-- name: GetPerson :one
SELECT * FROM persons WHERE id = ?;

-- name: TouchPerson :exec
UPDATE persons SET last_seen_at = ? WHERE id = ?;

-- name: UpdatePersonName :exec
UPDATE persons SET display_name = ? WHERE id = ?;
