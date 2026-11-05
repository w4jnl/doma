package service

import (
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"errors"
	"fmt"
	"io/fs"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/w4jnl/doma/internal/db"
	"github.com/w4jnl/doma/internal/domain"
	"github.com/w4jnl/doma/internal/photo"
)

// Photos: the one kind of data outside SQLite. A photo.added event through
// sync makes the row; the JPEG follows by photo id, is decoded and
// re-encoded so nothing but pixels survives, and lands with a thumbnail
// under photos.dir/<household>/. The row's path is set once the file is
// there; until then, and after retention has taken an old photo's files,
// the photo is pending and its GET is a 404.

// LinkTTL is how long a signed photo link opens.
const LinkTTL = time.Hour

// StoredPhoto is what an upload answers with.
type StoredPhoto struct {
	ID     string `json:"id"`
	SpotID string `json:"spot_id"`
	Bytes  int64  `json:"bytes"`
	Width  int64  `json:"width"`
	Height int64  `json:"height"`
}

// MaxUploadBytes is the cap on one upload's body.
func (s *Service) MaxUploadBytes() int64 { return s.cfg.MaxUploadBytes }

func (s *Service) photoFile(rel string) string {
	return filepath.Join(s.cfg.PhotosDir, filepath.FromSlash(rel))
}

// StorePhoto keeps the JPEG for an accepted photo.added. Members only.
// Over quota is domain.ErrQuota, checked against the household's
// quota_photo_bytes before the picture is processed and again on what is
// kept; anything that does not decode as a JPEG is photo.ErrNotJPEG.
func (s *Service) StorePhoto(ctx context.Context, sc domain.Scope, photoID string, body []byte) (*StoredPhoto, error) {
	if err := requireMember(sc); err != nil {
		return nil, err
	}
	if s.cfg.PhotosDir == "" {
		return nil, errors.New("no photos directory")
	}
	if int64(len(body)) > s.cfg.MaxUploadBytes {
		return nil, fmt.Errorf("%w: a picture may be %d bytes at most", domain.ErrQuota, s.cfg.MaxUploadBytes)
	}
	var (
		row   db.Photo
		quota *int64
		used  int64
	)
	err := s.db.ReadTx(ctx, func(q *db.Queries) error {
		h, err := q.GetHousehold(ctx, sc.HouseholdID)
		if err != nil {
			return notFound(err)
		}
		quota = h.QuotaPhotoBytes
		if row, err = q.GetPhoto(ctx, db.GetPhotoParams{HouseholdID: sc.HouseholdID, ID: photoID}); err != nil {
			return notFound(err)
		}
		used, err = q.PhotoBytes(ctx, sc.HouseholdID)
		return err
	})
	if err != nil {
		return nil, err
	}
	if row.Path != nil {
		used -= row.Bytes
	}
	if quota != nil && used+int64(len(body)) > *quota {
		return nil, fmt.Errorf("%w: the household's photos would pass %d bytes", domain.ErrQuota, *quota)
	}
	res, err := photo.Process(strings.NewReader(string(body)))
	if err != nil {
		return nil, err
	}
	kept := int64(len(res.Full) + len(res.Thumb))
	if quota != nil && used+kept > *quota {
		return nil, fmt.Errorf("%w: the household's photos would pass %d bytes", domain.ErrQuota, *quota)
	}
	rel, relThumb := photoID+".jpg", photoID+".t.jpg"
	dir := filepath.Join(s.cfg.PhotosDir, sc.HouseholdID)
	if err := os.MkdirAll(dir, 0o750); err != nil {
		return nil, err
	}
	for name, data := range map[string][]byte{rel: res.Full, relThumb: res.Thumb} {
		if err := writeFile(filepath.Join(dir, name), data); err != nil {
			return nil, err
		}
	}
	stored := &StoredPhoto{ID: photoID, SpotID: row.SpotID, Bytes: kept, Width: int64(res.Width), Height: int64(res.Height)}
	path, thumb := sc.HouseholdID+"/"+rel, sc.HouseholdID+"/"+relThumb
	var pruned []string
	err = s.db.Tx(ctx, func(q *db.Queries) error {
		if err := q.SetPhotoFile(ctx, db.SetPhotoFileParams{Path: &path, ThumbPath: &thumb, Bytes: kept, Width: stored.Width, Height: stored.Height, HouseholdID: sc.HouseholdID, ID: photoID}); err != nil {
			return err
		}
		pruned, err = s.pruneSpot(ctx, q, sc.HouseholdID, row.SpotID)
		if err != nil {
			return err
		}
		used, err = q.PhotoBytes(ctx, sc.HouseholdID)
		return err
	})
	if err != nil {
		_ = os.Remove(filepath.Join(dir, rel))
		_ = os.Remove(filepath.Join(dir, relThumb))
		return nil, err
	}
	for _, p := range pruned {
		_ = os.Remove(s.photoFile(p))
	}
	s.setPhotoBytes(sc.HouseholdID, used)
	s.log.Info("photo stored", "household", sc.HouseholdID, "photo", photoID, "bytes", kept, "width", res.Width, "height", res.Height, "pruned", len(pruned)/2)
	return stored, nil
}

// pruneSpot clears the files of the spot's photos beyond photos_per_spot,
// newest first, and returns the relative paths to remove once the
// transaction holds.
func (s *Service) pruneSpot(ctx context.Context, q *db.Queries, householdID, spotID string) ([]string, error) {
	rows, err := q.ListSpotPhotos(ctx, db.ListSpotPhotosParams{HouseholdID: householdID, SpotID: spotID})
	if err != nil {
		return nil, err
	}
	var out []string
	kept := 0
	for _, r := range rows {
		if r.Path == nil {
			continue
		}
		if kept++; kept <= s.cfg.PhotosPerSpot {
			continue
		}
		out = append(out, *r.Path)
		if r.ThumbPath != nil {
			out = append(out, *r.ThumbPath)
		}
		if err := q.ClearPhotoFile(ctx, db.ClearPhotoFileParams{HouseholdID: householdID, ID: r.ID}); err != nil {
			return nil, err
		}
	}
	return out, nil
}

// OpenPhoto opens the file of a stored photo, or its thumbnail, for a
// member, inside the photo directory; a pending or pruned photo is not
// found. The caller closes it.
func (s *Service) OpenPhoto(ctx context.Context, sc domain.Scope, photoID string, thumb bool) (*os.File, error) {
	if err := requireMember(sc); err != nil {
		return nil, err
	}
	row, err := s.db.Read().GetPhoto(ctx, db.GetPhotoParams{HouseholdID: sc.HouseholdID, ID: photoID})
	if err != nil {
		return nil, notFound(err)
	}
	rel := row.Path
	if thumb {
		rel = row.ThumbPath
	}
	if rel == nil {
		return nil, domain.ErrNotFound
	}
	f, err := os.OpenInRoot(s.cfg.PhotosDir, filepath.FromSlash(*rel))
	if errors.Is(err, fs.ErrNotExist) {
		return nil, domain.ErrNotFound
	}
	return f, err
}

// PhotoBytes is what the household's photos take on disk.
func (s *Service) PhotoBytes(ctx context.Context, householdID string) (int64, error) {
	return s.db.Read().PhotoBytes(ctx, householdID)
}

func (s *Service) setPhotoBytes(householdID string, n int64) {
	if s.metrics != nil {
		s.metrics.PhotoBytes.WithLabelValues(householdID).Set(float64(n))
	}
}

// Signed links: a photo URL with exp and sig in the query opens for an
// hour without a device signature, for a page that shows the picture by
// URL. The key derives from the instance key; without one (tests) it is
// random per process.

// SignLink returns the absolute URL of path, signed until LinkTTL from now.
func (s *Service) SignLink(path string) string {
	exp := s.now().Add(LinkTTL).Unix()
	return s.cfg.BaseURL + path + "?exp=" + strconv.FormatInt(exp, 10) + "&sig=" + s.linkSig(path, exp)
}

// CheckLink reports whether q signs path and has not expired.
func (s *Service) CheckLink(path string, q url.Values) bool {
	exp, err := strconv.ParseInt(q.Get("exp"), 10, 64)
	if err != nil || exp < s.now().Unix() {
		return false
	}
	return subtle.ConstantTimeCompare([]byte(q.Get("sig")), []byte(s.linkSig(path, exp))) == 1
}

func (s *Service) linkSig(path string, exp int64) string {
	m := hmac.New(sha256.New, s.linkKey())
	_, _ = fmt.Fprintf(m, "%s\n%d", path, exp)
	return base64.RawURLEncoding.EncodeToString(m.Sum(nil))
}

func (s *Service) linkKey() []byte {
	s.linkMu.Lock()
	defer s.linkMu.Unlock()
	if s.linkKeyBytes == nil {
		if s.keyring != nil {
			s.linkKeyBytes = s.keyring.MAC("photo-link")
		} else {
			s.linkKeyBytes = make([]byte, 32)
			_, _ = rand.Read(s.linkKeyBytes)
		}
	}
	return s.linkKeyBytes
}

// reconcilePhotos recomputes the household's usage from disk, as the
// nightly job does: a row whose file is gone goes back to pending, a row's
// bytes follow the files, and a file no row names is removed.
func (s *Service) reconcilePhotos(ctx context.Context, householdID string) error {
	if s.cfg.PhotosDir == "" {
		return nil
	}
	rows, err := s.db.Read().ListStoredPhotos(ctx, householdID)
	if err != nil {
		return err
	}
	named := map[string]bool{}
	var used int64
	for _, r := range rows {
		full, errF := os.Stat(s.photoFile(*r.Path))
		var thumbSize int64
		if r.ThumbPath != nil {
			if st, err := os.Stat(s.photoFile(*r.ThumbPath)); err == nil {
				thumbSize = st.Size()
				named[*r.ThumbPath] = true
			}
		}
		if errF != nil {
			if err := s.db.Write().ClearPhotoFile(ctx, db.ClearPhotoFileParams{HouseholdID: householdID, ID: r.ID}); err != nil {
				return err
			}
			continue
		}
		named[*r.Path] = true
		size := full.Size() + thumbSize
		if size != r.Bytes {
			if err := s.db.Write().SetPhotoFile(ctx, db.SetPhotoFileParams{Path: r.Path, ThumbPath: r.ThumbPath, Bytes: size, Width: r.Width, Height: r.Height, HouseholdID: householdID, ID: r.ID}); err != nil {
				return err
			}
		}
		used += size
	}
	if root, err := os.OpenRoot(filepath.Join(s.cfg.PhotosDir, householdID)); err == nil {
		_ = fs.WalkDir(root.FS(), ".", func(p string, d fs.DirEntry, err error) error {
			if err != nil || d.IsDir() {
				return nil
			}
			if !named[householdID+"/"+p] {
				_ = root.Remove(p)
			}
			return nil
		})
		_ = root.Close()
	}
	s.setPhotoBytes(householdID, used)
	return nil
}

// removePhotoDir takes a deleted household's photos with it.
func (s *Service) removePhotoDir(householdID string) {
	if s.cfg.PhotosDir == "" || householdID == "" {
		return
	}
	_ = os.RemoveAll(filepath.Join(s.cfg.PhotosDir, householdID))
	if s.metrics != nil {
		s.metrics.PhotoBytes.DeleteLabelValues(householdID)
	}
}

// writeFile writes data next to its final name and renames it into place.
func writeFile(path string, data []byte) error {
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}
