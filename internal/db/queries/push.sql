-- name: PushTargets :many
-- The household's devices with a push token that were not pushed since the
-- cutoff: one push per device per 30 s.
SELECT c.id AS credential_id, c.apns_token, c.apns_sandbox, c.person_id, c.last_used_at, c.muted_lists, c.notify_clears, p.seq AS last_seq, p.spoken_at, p.spoken_seq FROM credentials c
JOIN memberships m ON m.person_id = c.person_id
LEFT JOIN push_log p ON p.household_id = m.household_id AND p.credential_id = c.id
WHERE m.household_id = ? AND c.apns_token IS NOT NULL AND c.revoked_at IS NULL
  AND (p.sent_at IS NULL OR p.sent_at < ?)
ORDER BY c.id;

-- name: RecordPush :exec
INSERT INTO push_log (household_id, credential_id, sent_at, seq) VALUES (?, ?, ?, ?)
ON CONFLICT(household_id, credential_id) DO UPDATE SET sent_at = excluded.sent_at, seq = excluded.seq;

-- name: ClearAPNSToken :exec
UPDATE credentials SET apns_token = NULL WHERE id = ?;

-- name: RecordSpoken :exec
-- the device heard words up to seq: the next spoken push waits two minutes and starts here
UPDATE push_log SET spoken_at = ?, spoken_seq = ? WHERE household_id = ? AND credential_id = ?;
