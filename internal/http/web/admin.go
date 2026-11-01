package web

import (
	"errors"
	"fmt"
	"html/template"
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/w4jnl/doma/internal/auth"
	"github.com/w4jnl/doma/internal/domain"
	"github.com/w4jnl/doma/internal/logging"
	"github.com/w4jnl/doma/internal/service"
)

// ServerFacts is what the Server page shows and does, wired from main.
type ServerFacts struct {
	BaseURL     string
	Version     string
	PushEnabled bool
	PushKeyFile string
	PhotosDir   string
	// ConfigTOML is the effective configuration, redacted.
	ConfigTOML string
	// LastPushError is the pusher's last failure, "" when none.
	LastPushError func() string
	// SealKey stores an uploaded APNs key encrypted at PushKeyFile.
	SealKey func(pem []byte) error
	// SecretKeyFile goes into the backup zip.
	SecretKeyFile string
}

// SetServerFacts wires the Server page.
func (h *Web) SetServerFacts(f ServerFacts) { h.facts = &f }

// households

type householdRow struct {
	ID, Name, Timezone string
	Members, Devices   int
	LastEvent          string
}

type householdsData struct {
	Households []householdRow
	Timezone   string
	Notice     string
}

func (h *Web) households(w http.ResponseWriter, r *http.Request, sess *auth.Session) {
	h.renderHouseholds(w, r, sess, http.StatusOK, "", r.URL.Query().Get("created"))
}

func (h *Web) renderHouseholds(w http.ResponseWriter, r *http.Request, sess *auth.Session, status int, errMsg, created string) {
	hs, err := h.svc.Overview(r.Context())
	if err != nil {
		h.fail(w, r, err)
		return
	}
	data := householdsData{Timezone: "Europe/Amsterdam"}
	for _, hh := range hs {
		row := householdRow{ID: hh.ID, Name: hh.Name, Timezone: hh.Timezone, Members: hh.Members, Devices: hh.Devices}
		if hh.LastEventAt > 0 {
			row.LastEvent = ago(hh.LastEventAt, h.now())
		}
		data.Households = append(data.Households, row)
		if hh.ID == created {
			data.Notice = hh.Name + " is created. Open it and make the first owner invite."
		}
	}
	h.render(w, status, "households", page{Title: "Households", Nav: "households", CSRF: sess.CSRF, Error: errMsg, Data: data})
}

func (h *Web) createHousehold(w http.ResponseWriter, r *http.Request, sess *auth.Session) {
	hh, err := h.svc.CreateHousehold(r.Context(), r.PostFormValue("name"), r.PostFormValue("timezone"), r.PostFormValue("home"))
	if err != nil {
		var ve domain.ErrValidation
		if errors.As(err, &ve) {
			h.renderHouseholds(w, r, sess, http.StatusUnprocessableEntity, ve.Msg, "")
			return
		}
		h.fail(w, r, err)
		return
	}
	http.Redirect(w, r, "/admin/h/"+hh.ID, http.StatusSeeOther) //nolint:gosec // G710: the id is a ULID we just made
}

// one household

type inviteView struct {
	URL string
	QR  template.HTML
}

type detailView struct {
	*service.HouseholdDetail
	InviteDays int
}

type householdData struct {
	Detail        detailView
	Invite        *inviteView
	QuotaDevices  string
	QuotaPhotoMB  string
	Notice        string
	ConfirmDelete bool
}

func (h *Web) household(w http.ResponseWriter, r *http.Request, sess *auth.Session) {
	h.renderHousehold(w, r, sess, r.PathValue("id"), householdData{Notice: r.URL.Query().Get("notice")}, http.StatusOK, "")
}

func (h *Web) renderHousehold(w http.ResponseWriter, r *http.Request, sess *auth.Session, id string, data householdData, status int, errMsg string) {
	d, err := h.svc.HouseholdDetail(r.Context(), id)
	if err != nil {
		if errors.Is(err, domain.ErrNotFound) {
			http.NotFound(w, r)
			return
		}
		h.fail(w, r, err)
		return
	}
	data.Detail = detailView{HouseholdDetail: d, InviteDays: h.InviteDays}
	if d.QuotaDevices != nil {
		data.QuotaDevices = strconv.FormatInt(*d.QuotaDevices, 10)
	}
	if d.QuotaPhotoBytes != nil {
		data.QuotaPhotoMB = strconv.FormatInt(*d.QuotaPhotoBytes>>20, 10)
	}
	h.render(w, status, "household", page{Title: d.Name, Nav: "households", CSRF: sess.CSRF, Error: errMsg, Data: data})
}

func (h *Web) ownerInvite(w http.ResponseWriter, r *http.Request, sess *auth.Session) {
	id := r.PathValue("id")
	inv, err := h.svc.CreateInvite(r.Context(), domain.Scope{HouseholdID: id, Role: domain.RoleOwner}, domain.RoleOwner)
	if err != nil {
		if errors.Is(err, domain.ErrNotFound) {
			http.NotFound(w, r)
			return
		}
		h.fail(w, r, err)
		return
	}
	svg, err := qrSVG(inv.URL)
	if err != nil {
		h.fail(w, r, err)
		return
	}
	h.renderHousehold(w, r, sess, id, householdData{Invite: &inviteView{URL: inv.URL, QR: template.HTML(svg)}}, http.StatusOK, "") //nolint:gosec // G203: the SVG is built from a URL we made
}

func (h *Web) setQuotas(w http.ResponseWriter, r *http.Request, sess *auth.Session) {
	id := r.PathValue("id")
	parse := func(field string, scale int64) (*int64, error) {
		v := strings.TrimSpace(r.PostFormValue(field))
		if v == "" {
			return nil, nil
		}
		n, err := strconv.ParseInt(v, 10, 64)
		if err != nil || n < 0 {
			return nil, fmt.Errorf("%s must be a whole number", field)
		}
		n *= scale
		return &n, nil
	}
	devices, err := parse("devices", 1)
	if err != nil {
		h.renderHousehold(w, r, sess, id, householdData{}, http.StatusUnprocessableEntity, err.Error())
		return
	}
	photo, err := parse("photo_mb", 1<<20)
	if err != nil {
		h.renderHousehold(w, r, sess, id, householdData{}, http.StatusUnprocessableEntity, err.Error())
		return
	}
	if err := h.svc.SetQuotas(r.Context(), id, devices, photo); err != nil {
		if errors.Is(err, domain.ErrNotFound) {
			http.NotFound(w, r)
			return
		}
		h.fail(w, r, err)
		return
	}
	http.Redirect(w, r, "/admin/h/"+id+"?notice=Quotas+saved", http.StatusSeeOther) //nolint:gosec // G710: our own page, id from our own route
}

func (h *Web) deleteHousehold(w http.ResponseWriter, r *http.Request, sess *auth.Session) {
	id := r.PathValue("id")
	if r.PostFormValue("confirm") != "1" {
		h.renderHousehold(w, r, sess, id, householdData{ConfirmDelete: true}, http.StatusOK, "")
		return
	}
	if err := h.svc.DeleteHousehold(r.Context(), id); err != nil {
		if errors.Is(err, domain.ErrConflict) {
			h.renderHousehold(w, r, sess, id, householdData{}, http.StatusConflict, "The household still has members.")
			return
		}
		if errors.Is(err, domain.ErrNotFound) {
			http.NotFound(w, r)
			return
		}
		h.fail(w, r, err)
		return
	}
	http.Redirect(w, r, "/admin", http.StatusSeeOther)
}

// exportHousehold streams the zip for the admin, personal lists included:
// it is a backup, not a view.
func (h *Web) exportHousehold(w http.ResponseWriter, r *http.Request, _ *auth.Session) {
	id := r.PathValue("id")
	w.Header().Set("Content-Type", "application/zip")
	w.Header().Set("Content-Disposition", `attachment; filename="doma-export.zip"`)
	w.Header().Set("Cache-Control", "no-store")
	if err := h.svc.Export(r.Context(), domain.Scope{HouseholdID: id, PersonID: domain.SystemPerson, Role: domain.RoleOwner}, w); err != nil {
		if errors.Is(err, domain.ErrNotFound) {
			http.NotFound(w, r)
			return
		}
		h.log.Error("export", "err", err)
	}
}

// server page

type totpSetup struct {
	Secret string
	QR     template.HTML
}

type serverData struct {
	BaseURL, Version, PushStatus, PushError string
	TLS                                     bool
	SnapshotRun                             int64
	LastBackup                              string
	Levels                                  []string
	LogLevel                                string
	TOTPOn                                  bool
	TOTPSetup                               *totpSetup
	Config                                  string
	Notice                                  string
}

func (h *Web) serverPage(w http.ResponseWriter, r *http.Request, sess *auth.Session) {
	h.renderServer(w, r, sess, serverData{Notice: r.URL.Query().Get("notice")}, http.StatusOK, "")
}

func (h *Web) renderServer(w http.ResponseWriter, r *http.Request, sess *auth.Session, data serverData, status int, errMsg string) {
	f := h.facts
	if f == nil {
		f = &ServerFacts{}
	}
	data.BaseURL, data.Version, data.TLS = f.BaseURL, f.Version, strings.HasPrefix(f.BaseURL, "https://")
	data.Levels = []string{"debug", "info", "warn", "error"}
	data.LogLevel = logging.LevelName()
	data.Config = f.ConfigTOML
	switch {
	case f.PushEnabled:
		data.PushStatus = "on"
	case f.PushKeyFile != "":
		if fileExists(f.PushKeyFile) {
			data.PushStatus = "off; the APNs key is uploaded, set push.enabled = true and restart"
		} else {
			data.PushStatus = "off; no APNs key yet"
		}
	default:
		data.PushStatus = "off"
	}
	if f.LastPushError != nil {
		data.PushError = f.LastPushError()
	}
	if last := h.svc.LastSnapshotRun(); !last.IsZero() {
		data.SnapshotRun = last.UnixMilli()
	}
	on, err := h.svc.TOTPEnabled(r.Context())
	if err != nil {
		h.fail(w, r, err)
		return
	}
	data.TOTPOn = on
	h.render(w, status, "server", page{Title: "Server", Nav: "server", CSRF: sess.CSRF, Error: errMsg, Data: data})
}

func (h *Web) uploadAPNSKey(w http.ResponseWriter, r *http.Request, sess *auth.Session) {
	if h.facts == nil || h.facts.SealKey == nil {
		http.NotFound(w, r)
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, 64<<10)
	if err := r.ParseMultipartForm(64 << 10); err != nil { //nolint:gosec // G120: the body is capped at 64 KB by MaxBytesReader above
		h.renderServer(w, r, sess, serverData{}, http.StatusUnprocessableEntity, "Choose the .p8 file Apple gave you.")
		return
	}
	file, _, err := r.FormFile("key")
	if err != nil {
		h.renderServer(w, r, sess, serverData{}, http.StatusUnprocessableEntity, "Choose the .p8 file Apple gave you.")
		return
	}
	defer func() { _ = file.Close() }()
	raw, err := io.ReadAll(io.LimitReader(file, 16<<10))
	if err != nil || !strings.Contains(string(raw), "PRIVATE KEY") {
		h.renderServer(w, r, sess, serverData{}, http.StatusUnprocessableEntity, "That is not an APNs key file.")
		return
	}
	if err := h.facts.SealKey(raw); err != nil {
		h.fail(w, r, err)
		return
	}
	http.Redirect(w, r, "/admin/server?notice=APNs+key+stored", http.StatusSeeOther)
}

func (h *Web) backupNow(w http.ResponseWriter, r *http.Request, sess *auth.Session) {
	keyFile, photos := "", ""
	if h.facts != nil {
		keyFile, photos = h.facts.SecretKeyFile, h.facts.PhotosDir
	}
	path, err := h.svc.Backup(r.Context(), keyFile, photos)
	if err != nil {
		h.fail(w, r, err)
		return
	}
	h.renderServer(w, r, sess, serverData{LastBackup: path, Notice: "Backup written."}, http.StatusOK, "")
}

func (h *Web) runSnapshots(w http.ResponseWriter, r *http.Request, _ *auth.Session) {
	if err := h.svc.RunSnapshots(r.Context()); err != nil {
		h.log.Error("snapshots from the server page", "err", err)
	}
	http.Redirect(w, r, "/admin/server?notice=Snapshots+written", http.StatusSeeOther)
}

func (h *Web) setLogLevel(w http.ResponseWriter, r *http.Request, _ *auth.Session) {
	level := r.PostFormValue("level")
	switch level {
	case "debug", "info", "warn", "error":
		logging.SetLevel(level)
		h.log.Info("log level set", "level", level)
	}
	http.Redirect(w, r, "/admin/server", http.StatusSeeOther)
}

func (h *Web) totpSetupPage(w http.ResponseWriter, r *http.Request, sess *auth.Session) {
	secret, err := auth.NewTOTPSecret()
	if err != nil {
		h.fail(w, r, err)
		return
	}
	svg, err := qrSVG(auth.TOTPURL(secret, "admin"))
	if err != nil {
		h.fail(w, r, err)
		return
	}
	h.renderServer(w, r, sess, serverData{TOTPSetup: &totpSetup{Secret: secret, QR: template.HTML(svg)}}, http.StatusOK, "") //nolint:gosec // G203: our own SVG
}

func (h *Web) totpConfirm(w http.ResponseWriter, r *http.Request, sess *auth.Session) {
	secret, code := r.PostFormValue("secret"), r.PostFormValue("code")
	if !auth.VerifyTOTP(secret, code, h.now()) {
		svg, _ := qrSVG(auth.TOTPURL(secret, "admin"))
		h.renderServer(w, r, sess, serverData{TOTPSetup: &totpSetup{Secret: secret, QR: template.HTML(svg)}}, http.StatusUnprocessableEntity, "That code does not match. Try the next one.") //nolint:gosec // G203: our own SVG
		return
	}
	if err := h.svc.SetTOTP(r.Context(), secret); err != nil {
		h.fail(w, r, err)
		return
	}
	http.Redirect(w, r, "/admin/server?notice=Second+step+is+on", http.StatusSeeOther)
}

func (h *Web) totpOff(w http.ResponseWriter, r *http.Request, _ *auth.Session) {
	if err := h.svc.SetTOTP(r.Context(), ""); err != nil {
		h.fail(w, r, err)
		return
	}
	http.Redirect(w, r, "/admin/server?notice=Second+step+is+off", http.StatusSeeOther)
}

// ago renders a time as the design system wants it: relative first.
func ago(ms int64, now time.Time) string {
	d := now.Sub(domain.FromMillis(ms))
	switch {
	case d < time.Minute:
		return "just now"
	case d < time.Hour:
		return fmt.Sprintf("%d min ago", int(d.Minutes()))
	case d < 24*time.Hour:
		return fmt.Sprintf("%d h ago", int(d.Hours()))
	case d < 48*time.Hour:
		return "yesterday"
	case d < 14*24*time.Hour:
		return fmt.Sprintf("%d days ago", int(d.Hours()/24))
	case d < 60*24*time.Hour:
		return fmt.Sprintf("%d wk ago", int(d.Hours()/24/7))
	default:
		return domain.FromMillis(ms).Format("2 Jan 2006")
	}
}
