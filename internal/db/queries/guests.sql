-- name: GuestsForHousehold :many
SELECT m.person_id, m.household_id, m.home_id, m.list_id, m.expires_at, m.created_at,
       c.id AS credential_id, c.label, c.last_used_at, c.revoked_at
FROM memberships m
JOIN credentials c ON c.person_id = m.person_id AND c.kind = 'guest_link'
WHERE m.household_id = ? AND m.role = 'guest'
ORDER BY m.created_at;

-- name: ExpireGuest :execrows
UPDATE memberships SET expires_at = ? WHERE household_id = ? AND person_id = ? AND role = 'guest';

-- name: LastEventAt :one
SELECT CAST(COALESCE(MAX(received_at), 0) AS INTEGER) FROM events WHERE household_id = ?;

-- name: CountDevices :one
SELECT COUNT(*) FROM credentials c JOIN memberships m ON m.person_id = c.person_id
WHERE m.household_id = ? AND c.kind = 'device_key' AND c.revoked_at IS NULL;

-- name: SetAdminTOTP :exec
UPDATE admin SET totp_secret = ? WHERE id = 1;
