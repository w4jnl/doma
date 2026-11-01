package domain

// Role is a person's role in one household.
type Role string

const (
	RoleOwner  Role = "owner"
	RoleMember Role = "member"
	RoleGuest  Role = "guest"
)

// Valid reports whether r is one of the three roles.
func (r Role) Valid() bool { return r == RoleOwner || r == RoleMember || r == RoleGuest }

// AtLeast reports whether r has at least the rights of o: owner > member > guest.
func (r Role) AtLeast(o Role) bool { return rank(r) >= rank(o) }

func rank(r Role) int {
	switch r {
	case RoleOwner:
		return 3
	case RoleMember:
		return 2
	case RoleGuest:
		return 1
	}
	return 0
}

// Scope is who is acting on which household, set once by the auth
// middleware and passed first to every service method. A guest scope
// carries HomeID and ListID and nothing else.
type Scope struct {
	HouseholdID string
	PersonID    string
	Role        Role
	// HomeID and ListID are set for guests only.
	HomeID string
	ListID string
}

// IsGuest reports whether the scope is a guest link's.
func (s Scope) IsGuest() bool { return s.Role == RoleGuest }
