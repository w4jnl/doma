-- name: InsertInvite :exec
INSERT INTO invites (id, household_id, role, token_hash, created_by, expires_at, for_person_id)
VALUES (?, ?, ?, ?, ?, ?, ?);

-- name: GetInviteByHash :one
-- tenancy: root -- the token is the only thing an invite link carries
SELECT * FROM invites WHERE token_hash = ?;

-- name: InvitesForHousehold :many
-- the household's pending invites; a device invite is its person's and is not among them
SELECT * FROM invites
WHERE household_id = ? AND used_at IS NULL AND revoked_at IS NULL AND expires_at > ? AND for_person_id IS NULL
ORDER BY expires_at;

-- name: UseInvite :execrows
UPDATE invites SET used_by = ?, used_at = ?
WHERE household_id = ? AND id = ? AND used_at IS NULL AND revoked_at IS NULL;

-- name: RevokeInvite :execrows
UPDATE invites SET revoked_at = ?
WHERE household_id = ? AND id = ? AND used_at IS NULL AND revoked_at IS NULL;
