-- name: InsertMembership :exec
INSERT INTO memberships (person_id, household_id, role, home_id, list_id, expires_at, created_at)
VALUES (?, ?, ?, ?, ?, ?, ?);

-- name: GetMembership :one
SELECT * FROM memberships WHERE household_id = ? AND person_id = ?;

-- name: MembershipsForPerson :many
-- tenancy: root -- a person's memberships across households, to build their scopes
SELECT * FROM memberships WHERE person_id = ? ORDER BY created_at;

-- name: MembersOfHousehold :many
SELECT m.*, p.display_name, p.last_seen_at FROM memberships m
JOIN persons p ON p.id = m.person_id
WHERE m.household_id = ? AND m.role != 'guest'
ORDER BY m.created_at;

-- name: CountOwners :one
SELECT COUNT(*) FROM memberships WHERE household_id = ? AND role = 'owner';

-- name: CountMembers :one
SELECT COUNT(*) FROM memberships WHERE household_id = ? AND role != 'guest';

-- name: UpdateMembershipRole :execrows
UPDATE memberships SET role = ? WHERE household_id = ? AND person_id = ?;

-- name: DeleteMembership :execrows
DELETE FROM memberships WHERE household_id = ? AND person_id = ?;
