package domain

// SystemPerson is the person id on events the server appends itself: the
// default list and first home of a new household, a removed member, a
// revoked device.
const SystemPerson = "doma"

// Person is one human on this server, in any number of households.
type Person struct {
	ID          string
	DisplayName string
	CreatedAt   int64
	LastSeenAt  *int64
}

// Credential kinds.
const (
	KindDeviceKey = "device_key"
	KindPasskey   = "passkey"
	KindGuestLink = "guest_link"
)

// Credential is a device, a passkey or a guest link.
type Credential struct {
	ID         string
	PersonID   string
	Kind       string
	PublicKey  string
	Label      string
	Platform   string
	APNSToken  *string
	CreatedAt  int64
	LastUsedAt *int64
	RevokedAt  *int64
}

// Revoked reports whether the credential has been revoked.
func (c Credential) Revoked() bool { return c.RevokedAt != nil }

// Household is the tenant.
type Household struct {
	ID              string
	Slug            string
	Name            string
	Timezone        string
	QuotaDevices    *int64
	QuotaPhotoBytes *int64
	StalenessDays   *int64
	CreatedAt       int64
}

// Membership is a person's role in a household; guests carry a home and
// a list.
type Membership struct {
	PersonID    string
	HouseholdID string
	Role        Role
	HomeID      *string
	ListID      *string
	ExpiresAt   *int64
	CreatedAt   int64
}

// Member is a membership with the person's name, for the Family screen.
type Member struct {
	Membership
	DisplayName string
	LastSeenAt  *int64
}

// Invite is one use of the QR a family shows a new member.
type Invite struct {
	ID          string
	HouseholdID string
	Role        Role
	CreatedBy   *string
	ExpiresAt   int64
	UsedBy      *string
	UsedAt      *int64
	RevokedAt   *int64
	// ForPersonID makes it a device invite: accepting it adds a device to
	// that person instead of making a new one.
	ForPersonID *string
}

// IsDevice says whether accepting the invite adds a device to a person.
func (i Invite) IsDevice() bool { return i.ForPersonID != nil }
