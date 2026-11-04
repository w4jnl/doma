-- name: InsertCredential :exec
INSERT INTO credentials (id, person_id, kind, public_key, hash, label, platform, created_at)
VALUES (?, ?, ?, ?, ?, ?, ?, ?);

-- name: GetCredential :one
SELECT * FROM credentials WHERE id = ?;

-- name: GetCredentialByPublicKey :one
SELECT * FROM credentials WHERE public_key = ? AND revoked_at IS NULL LIMIT 1;

-- name: GetCredentialByHash :one
SELECT * FROM credentials WHERE hash = ? LIMIT 1;

-- name: CredentialsForPerson :many
SELECT * FROM credentials WHERE person_id = ? ORDER BY created_at;

-- name: CredentialsForHousehold :many
SELECT c.* FROM credentials c
JOIN memberships m ON m.person_id = c.person_id
WHERE m.household_id = ? AND c.kind = 'device_key'
ORDER BY c.created_at;

-- name: RevokeCredential :execrows
UPDATE credentials SET revoked_at = ? WHERE id = ? AND revoked_at IS NULL;

-- name: SetAPNSToken :exec
UPDATE credentials SET apns_token = ?, apns_sandbox = ? WHERE id = ?;

-- name: TouchCredential :exec
UPDATE credentials SET last_used_at = ? WHERE id = ?;

-- name: SetNotifyPrefs :exec
UPDATE credentials SET muted_lists = ?, notify_clears = ? WHERE id = ?;
