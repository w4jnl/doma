-- name: GetAdmin :one
SELECT * FROM admin WHERE id = 1;

-- name: InsertAdmin :exec
INSERT INTO admin (id, login, password_hash, created_at) VALUES (1, ?, ?, ?);
