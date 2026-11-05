package service

import (
	"archive/zip"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"time"

	"github.com/w4jnl/doma/internal/auth"
	"github.com/w4jnl/doma/internal/db"
	"github.com/w4jnl/doma/internal/domain"
	"github.com/w4jnl/doma/internal/secrets"
)

// SetKeyring gives the service the instance key, for the TOTP secret.
func (s *Service) SetKeyring(k *secrets.Keyring) { s.keyring = k }

// HouseholdOverview is one row of the admin's households page: counts and
// metadata, never content.
type HouseholdOverview struct {
	domain.Household
	Members     int
	Devices     int
	PhotoBytes  int64
	LastEventAt int64
}

// PhotoSize is PhotoBytes for a page: "none", "340 kB", "12.5 MB".
func (o HouseholdOverview) PhotoSize() string {
	switch {
	case o.PhotoBytes == 0:
		return "no photos"
	case o.PhotoBytes < 1<<20:
		return fmt.Sprintf("%d kB of photos", o.PhotoBytes>>10)
	default:
		return fmt.Sprintf("%.1f MB of photos", float64(o.PhotoBytes)/(1<<20))
	}
}

// Overview lists every household with its counts.
func (s *Service) Overview(ctx context.Context) ([]HouseholdOverview, error) {
	hs, err := s.Households(ctx)
	if err != nil {
		return nil, err
	}
	q := s.db.Read()
	out := make([]HouseholdOverview, 0, len(hs))
	for _, h := range hs {
		o := HouseholdOverview{Household: h}
		n, _ := q.CountMembers(ctx, h.ID)
		o.Members = int(n)
		d, _ := q.CountDevices(ctx, h.ID)
		o.Devices = int(d)
		o.LastEventAt, _ = q.LastEventAt(ctx, h.ID)
		o.PhotoBytes, _ = q.PhotoBytes(ctx, h.ID)
		out = append(out, o)
	}
	return out, nil
}

// DeviceInfo is a device row on the household page.
type DeviceInfo struct {
	domain.Credential
	PersonName string
}

// HouseholdDetail is the admin's household page.
type HouseholdDetail struct {
	HouseholdOverview
	MembersList   []domain.Member
	DevicesList   []DeviceInfo
	Invites       []domain.Invite
	GuestLinks    []GuestLink
	Homes         []NamedID
	Lists         []NamedID
	SnapshotAt    int64
	StalenessDays int
}

// NamedID is an id with its name, for pickers.
type NamedID struct{ ID, Name string }

// HouseholdDetail loads everything the admin's household page shows.
func (s *Service) HouseholdDetail(ctx context.Context, id string) (*HouseholdDetail, error) {
	h, err := s.HouseholdByID(ctx, id)
	if err != nil {
		return nil, err
	}
	q := s.db.Read()
	d := &HouseholdDetail{HouseholdOverview: HouseholdOverview{Household: *h}, StalenessDays: s.StalenessDays(h)}
	admin := domain.Scope{HouseholdID: id, Role: domain.RoleOwner}
	if d.MembersList, err = s.Members(ctx, admin); err != nil {
		return nil, err
	}
	d.Members = len(d.MembersList)
	names := map[string]string{}
	for _, m := range d.MembersList {
		names[m.PersonID] = m.DisplayName
	}
	creds, err := q.CredentialsForHousehold(ctx, id)
	if err != nil {
		return nil, err
	}
	for _, c := range creds {
		if c.RevokedAt == nil {
			d.DevicesList = append(d.DevicesList, DeviceInfo{Credential: credential(c), PersonName: names[c.PersonID]})
		}
	}
	d.Devices = len(d.DevicesList)
	d.PhotoBytes, _ = q.PhotoBytes(ctx, id)
	if d.Invites, err = s.Invites(ctx, admin); err != nil {
		return nil, err
	}
	if d.GuestLinks, err = s.Guests(ctx, admin); err != nil {
		return nil, err
	}
	homes, err := q.ListHomes(ctx, id)
	if err != nil {
		return nil, err
	}
	for _, hm := range homes {
		if hm.ArchivedAt == nil {
			d.Homes = append(d.Homes, NamedID{ID: hm.ID, Name: hm.Name})
		}
	}
	lists, err := q.ListLists(ctx, id)
	if err != nil {
		return nil, err
	}
	for _, l := range lists {
		if l.ArchivedAt == nil && l.OwnerPersonID == nil {
			d.Lists = append(d.Lists, NamedID{ID: l.ID, Name: l.Name})
		}
	}
	d.LastEventAt, _ = q.LastEventAt(ctx, id)
	if snap, err := q.NewestSnapshot(ctx, id); err == nil {
		d.SnapshotAt = snap.CreatedAt
	}
	return d, nil
}

// SetQuotas sets a household's device and photo quotas; nil is unlimited.
func (s *Service) SetQuotas(ctx context.Context, id string, devices, photoBytes *int64) error {
	if (devices != nil && *devices < 0) || (photoBytes != nil && *photoBytes < 0) {
		return domain.Invalid("quota", "quotas are zero or more")
	}
	return s.db.Tx(ctx, func(q *db.Queries) error {
		if _, err := q.GetHousehold(ctx, id); err != nil {
			return notFound(err)
		}
		return q.UpdateHouseholdQuotas(ctx, db.UpdateHouseholdQuotasParams{QuotaDevices: devices, QuotaPhotoBytes: photoBytes, ID: id})
	})
}

// TOTP: the admin's optional second factor, the secret sealed at rest.

// TOTPEnabled reports whether the admin has a second factor.
func (s *Service) TOTPEnabled(ctx context.Context) (bool, error) {
	a, err := s.db.Read().GetAdmin(ctx)
	if err != nil {
		return false, notFound(err)
	}
	return len(a.TotpSecret) > 0, nil
}

// SetTOTP stores the secret after the admin typed one good code; an empty
// secret turns the second factor off.
func (s *Service) SetTOTP(ctx context.Context, secret string) error {
	if s.keyring == nil {
		return errors.New("no keyring")
	}
	var sealed []byte
	if secret != "" {
		v, err := s.keyring.Seal([]byte(secret))
		if err != nil {
			return err
		}
		sealed = []byte(v)
	}
	return s.db.Write().SetAdminTOTP(ctx, sealed)
}

// VerifyTOTP checks a code against the stored secret.
func (s *Service) VerifyTOTP(ctx context.Context, code string) error {
	a, err := s.db.Read().GetAdmin(ctx)
	if err != nil {
		return notFound(err)
	}
	if len(a.TotpSecret) == 0 || s.keyring == nil {
		return domain.ErrUnauthorized
	}
	secret, err := s.keyring.Open(string(a.TotpSecret))
	if err != nil {
		return err
	}
	if !auth.VerifyTOTP(string(secret), code, s.now()) {
		return domain.ErrUnauthorized
	}
	return nil
}

// Backup writes a dated zip next to the database with a consistent copy of
// the database (VACUUM INTO), the key file and the photos, and returns its
// path.
func (s *Service) Backup(ctx context.Context, keyFile, photosDir string) (string, error) {
	dir := filepath.Dir(s.db.Path)
	stamp := s.now().Format("20060102-150405")
	tmpDB := filepath.Join(dir, "doma-backup-"+stamp+".db")
	if _, err := s.db.Writer.ExecContext(ctx, "VACUUM INTO ?", tmpDB); err != nil {
		return "", fmt.Errorf("vacuum into: %w", err)
	}
	defer func() { _ = os.Remove(tmpDB) }()
	path := filepath.Join(dir, "doma-backup-"+stamp+".zip")
	f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o600)
	if err != nil {
		return "", err
	}
	z := zip.NewWriter(f)
	add := func(name, src string) error {
		in, err := os.Open(src)
		if err != nil {
			return err
		}
		defer func() { _ = in.Close() }()
		w, err := z.CreateHeader(&zip.FileHeader{Name: name, Method: zip.Deflate, Modified: s.now()})
		if err != nil {
			return err
		}
		_, err = io.Copy(w, in)
		return err
	}
	if err := add("doma.db", tmpDB); err != nil {
		_ = f.Close()
		return "", err
	}
	if _, err := os.Stat(keyFile); err == nil {
		if err := add("secret.key", keyFile); err != nil {
			_ = f.Close()
			return "", err
		}
	}
	_ = filepath.WalkDir(photosDir, func(p string, d os.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return nil
		}
		rel, _ := filepath.Rel(photosDir, p)
		return add(filepath.ToSlash(filepath.Join("photos", rel)), p)
	})
	if err := z.Close(); err != nil {
		_ = f.Close()
		return "", err
	}
	if err := f.Close(); err != nil {
		return "", err
	}
	s.log.Info("backup written", "path", path)
	return path, nil
}

var _ = time.Now
