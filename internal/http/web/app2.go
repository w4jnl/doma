package web

import (
	"errors"
	"html/template"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/w4jnl/doma/internal/auth"
	"github.com/w4jnl/doma/internal/domain"
	"github.com/w4jnl/doma/internal/service"
)

// The web client's homes, trips and Family pages. Plain forms that post and
// come back to the page; nothing here polls.

func (h *Web) mountApp2(mux *http.ServeMux) {
	mux.HandleFunc("GET /app/h/{household}/homes", h.inHousehold(h.appHomes))
	mux.HandleFunc("POST /app/h/{household}/homes", h.inHousehold(h.appCreateHome))
	mux.HandleFunc("GET /app/h/{household}/home/{home}", h.inHousehold(h.appHome))
	mux.HandleFunc("POST /app/h/{household}/home/{home}/flag/{item}", h.inHousehold(h.appFlag))
	mux.HandleFunc("POST /app/h/{household}/home/{home}/staples", h.inHousehold(h.appAddStaple))
	mux.HandleFunc("POST /app/h/{household}/home/{home}/staples/{item}/remove", h.inHousehold(h.appRemoveStaple))
	mux.HandleFunc("GET /app/h/{household}/trips", h.inHousehold(h.appTrips))
	mux.HandleFunc("POST /app/h/{household}/trips", h.inHousehold(h.appPlanTrip))
	mux.HandleFunc("GET /app/h/{household}/trip/{trip}", h.inHousehold(h.appTrip))
	mux.HandleFunc("POST /app/h/{household}/trip/{trip}/arrived", h.inHousehold(h.appArrive))
	mux.HandleFunc("POST /app/h/{household}/trip/{trip}/cancel", h.inHousehold(h.appCancelTrip))
	mux.HandleFunc("POST /app/h/{household}/trip/{trip}/add/{item}", h.inHousehold(h.appTripAdd))
	mux.HandleFunc("GET /app/h/{household}/family", h.inHousehold(h.appFamily))
	mux.HandleFunc("POST /app/h/{household}/family/invite", h.inHousehold(h.appInvite))
	mux.HandleFunc("POST /app/h/{household}/family/invites/{id}/revoke", h.inHousehold(h.appRevokeInvite))
	mux.HandleFunc("POST /app/h/{household}/family/guests", h.inHousehold(h.appGuestLink))
	mux.HandleFunc("POST /app/h/{household}/family/guests/{id}/revoke", h.inHousehold(h.appRevokeGuest))
	mux.HandleFunc("POST /app/h/{household}/family/members/{person}/remove", h.inHousehold(h.appRemoveMember))
	mux.HandleFunc("POST /app/h/{household}/family/devices/{id}/revoke", h.inHousehold(h.appRevokeDevice))
}

// back sends a plain form back to where it came from in the household, or
// to the page given.
func (h *Web) back(w http.ResponseWriter, r *http.Request, sc domain.Scope, fallback string) {
	to := "/app/h/" + sc.HouseholdID + "/" + fallback
	if ref := r.Referer(); strings.Contains(ref, "/app/h/"+sc.HouseholdID+"/") {
		if i := strings.Index(ref, "/app/"); i >= 0 {
			to = ref[i:]
		}
	}
	http.Redirect(w, r, to, http.StatusSeeOther) //nolint:gosec // G710: a path under this household's pages
}

// problem answers a write that the service refused: a 404 for what is not
// the person's, a 403 for a role, the page again with the message otherwise.
func (h *Web) problem(w http.ResponseWriter, r *http.Request, err error, again func(string)) bool {
	switch {
	case err == nil:
		return false
	case errors.Is(err, domain.ErrNotFound):
		http.NotFound(w, r)
	case errors.Is(err, domain.ErrForbidden):
		http.Error(w, "owners only", http.StatusForbidden)
	case errors.Is(err, domain.ErrConflict):
		http.Error(w, "that already happened", http.StatusConflict)
	default:
		var ve domain.ErrValidation
		if errors.As(err, &ve) && again != nil {
			again(ve.Msg)
			return true
		}
		h.fail(w, r, err)
	}
	return true
}

// homes

type homesData struct {
	Base  string
	Homes []service.WebHome
	Error string
}

func (h *Web) appHomes(w http.ResponseWriter, r *http.Request, sess *auth.Session, sc domain.Scope) {
	h.renderHomes(w, r, sess, sc, http.StatusOK, "")
}

func (h *Web) renderHomes(w http.ResponseWriter, r *http.Request, sess *auth.Session, sc domain.Scope, status int, problem string) {
	homes, err := h.svc.WebHomes(r.Context(), sc)
	if err != nil {
		h.fail(w, r, err)
		return
	}
	p, err := h.memberPage(r, sess, sc, "Homes", "homes")
	if err != nil {
		h.fail(w, r, err)
		return
	}
	p.Live = false
	p.Data = homesData{Base: "/app/h/" + sc.HouseholdID, Homes: homes, Error: problem}
	h.render(w, status, "app_homes", p)
}

func (h *Web) appCreateHome(w http.ResponseWriter, r *http.Request, sess *auth.Session, sc domain.Scope) {
	id, err := h.svc.WebCreateHome(r.Context(), sc, sess.Credential, r.PostFormValue("name"))
	if h.problem(w, r, err, func(msg string) { h.renderHomes(w, r, sess, sc, http.StatusUnprocessableEntity, msg) }) {
		return
	}
	http.Redirect(w, r, "/app/h/"+sc.HouseholdID+"/home/"+id, http.StatusSeeOther) //nolint:gosec // G710: the home just made
}

type homeData struct {
	Base string
	// Page is the home's own path.
	Page  string
	View  *service.WebHomeView
	Error string
}

func (h *Web) appHome(w http.ResponseWriter, r *http.Request, sess *auth.Session, sc domain.Scope) {
	h.renderHome(w, r, sess, sc, http.StatusOK, "")
}

func (h *Web) renderHome(w http.ResponseWriter, r *http.Request, sess *auth.Session, sc domain.Scope, status int, problem string) {
	view, err := h.svc.WebHome(r.Context(), sc, r.PathValue("home"))
	if err != nil {
		h.problem(w, r, err, nil)
		return
	}
	p, err := h.memberPage(r, sess, sc, view.Home.Name, "homes")
	if err != nil {
		h.fail(w, r, err)
		return
	}
	p.Live = false
	p.Data = homeData{Base: "/app/h/" + sc.HouseholdID, Page: "/app/h/" + sc.HouseholdID + "/home/" + view.Home.ID, View: view, Error: problem}
	h.render(w, status, "app_home", p)
}

func (h *Web) appFlag(w http.ResponseWriter, r *http.Request, sess *auth.Session, sc domain.Scope) {
	err := h.svc.WebSetFlag(r.Context(), sc, sess.Credential, r.PathValue("home"), r.PathValue("item"), r.PostFormValue("state"))
	if h.problem(w, r, err, func(msg string) { h.renderHome(w, r, sess, sc, http.StatusUnprocessableEntity, msg) }) {
		return
	}
	h.back(w, r, sc, "home/"+r.PathValue("home"))
}

func (h *Web) appAddStaple(w http.ResponseWriter, r *http.Request, sess *auth.Session, sc domain.Scope) {
	err := h.svc.WebAddStaple(r.Context(), sc, sess.Credential, r.PathValue("home"), strings.TrimSpace(r.PostFormValue("text")))
	if h.problem(w, r, err, func(msg string) { h.renderHome(w, r, sess, sc, http.StatusUnprocessableEntity, msg) }) {
		return
	}
	h.back(w, r, sc, "home/"+r.PathValue("home"))
}

func (h *Web) appRemoveStaple(w http.ResponseWriter, r *http.Request, sess *auth.Session, sc domain.Scope) {
	if h.problem(w, r, h.svc.WebRemoveStaple(r.Context(), sc, sess.Credential, r.PathValue("home"), r.PathValue("item")), nil) {
		return
	}
	h.back(w, r, sc, "home/"+r.PathValue("home"))
}

// trips

type tripsData struct {
	Base     string
	Trips    []service.WebTrip
	Homes    []service.WebHome
	Lists    []service.WebList
	Today    string
	Error    string
	Upcoming []service.WebTrip
	Past     []service.WebTrip
}

func (h *Web) appTrips(w http.ResponseWriter, r *http.Request, sess *auth.Session, sc domain.Scope) {
	h.renderTrips(w, r, sess, sc, http.StatusOK, "")
}

func (h *Web) renderTrips(w http.ResponseWriter, r *http.Request, sess *auth.Session, sc domain.Scope, status int, problem string) {
	trips, err := h.svc.WebTrips(r.Context(), sc)
	if err != nil {
		h.fail(w, r, err)
		return
	}
	homes, err := h.svc.WebHomes(r.Context(), sc)
	if err != nil {
		h.fail(w, r, err)
		return
	}
	lists, err := h.svc.WebLists(r.Context(), sc)
	if err != nil {
		h.fail(w, r, err)
		return
	}
	var shopping []service.WebList
	for _, l := range lists {
		if !l.Personal && !l.IsTasks() {
			shopping = append(shopping, l)
		}
	}
	d := tripsData{Base: "/app/h/" + sc.HouseholdID, Trips: trips, Homes: homes, Lists: shopping, Today: h.now().Format("2006-01-02"), Error: problem}
	for _, t := range trips {
		if t.Open() {
			d.Upcoming = append(d.Upcoming, t)
		} else {
			d.Past = append(d.Past, t)
		}
	}
	p, err := h.memberPage(r, sess, sc, "Trip", "trips")
	if err != nil {
		h.fail(w, r, err)
		return
	}
	p.Live = false
	p.Data = d
	h.render(w, status, "app_trips", p)
}

func (h *Web) appPlanTrip(w http.ResponseWriter, r *http.Request, sess *auth.Session, sc domain.Scope) {
	day, err := time.Parse("2006-01-02", r.PostFormValue("date"))
	if err != nil {
		h.renderTrips(w, r, sess, sc, http.StatusUnprocessableEntity, "Give the day of the trip.")
		return
	}
	id, err := h.svc.WebPlanTrip(r.Context(), sc, sess.Credential, r.PostFormValue("from"), r.PostFormValue("to"), domain.Millis(day), r.PostFormValue("list"))
	if h.problem(w, r, err, func(msg string) { h.renderTrips(w, r, sess, sc, http.StatusUnprocessableEntity, msg) }) {
		return
	}
	http.Redirect(w, r, "/app/h/"+sc.HouseholdID+"/trip/"+id, http.StatusSeeOther) //nolint:gosec // G710: the trip just planned
}

type tripData struct {
	Base string
	Page string
	View *service.WebTripView
}

func (h *Web) appTrip(w http.ResponseWriter, r *http.Request, sess *auth.Session, sc domain.Scope) {
	view, err := h.svc.WebTrip(r.Context(), sc, r.PathValue("trip"))
	if err != nil {
		h.problem(w, r, err, nil)
		return
	}
	p, err := h.memberPage(r, sess, sc, view.Trip.FromName+" to "+view.Trip.ToName, "trips")
	if err != nil {
		h.fail(w, r, err)
		return
	}
	p.Live = false
	p.Data = tripData{Base: "/app/h/" + sc.HouseholdID, Page: "/app/h/" + sc.HouseholdID + "/trip/" + view.Trip.ID, View: view}
	h.render(w, http.StatusOK, "app_trip", p)
}

func (h *Web) appArrive(w http.ResponseWriter, r *http.Request, sess *auth.Session, sc domain.Scope) {
	if h.problem(w, r, h.svc.WebArrive(r.Context(), sc, sess.Credential, r.PathValue("trip")), nil) {
		return
	}
	http.Redirect(w, r, "/app/h/"+sc.HouseholdID+"/trips", http.StatusSeeOther)
}

func (h *Web) appCancelTrip(w http.ResponseWriter, r *http.Request, sess *auth.Session, sc domain.Scope) {
	if h.problem(w, r, h.svc.WebCancelTrip(r.Context(), sc, sess.Credential, r.PathValue("trip")), nil) {
		return
	}
	http.Redirect(w, r, "/app/h/"+sc.HouseholdID+"/trips", http.StatusSeeOther)
}

func (h *Web) appTripAdd(w http.ResponseWriter, r *http.Request, sess *auth.Session, sc domain.Scope) {
	if h.problem(w, r, h.svc.WebAddToList(r.Context(), sc, sess.Credential, r.PathValue("trip"), r.PathValue("item")), nil) {
		return
	}
	h.back(w, r, sc, "trip/"+r.PathValue("trip"))
}

// family

type familyData struct {
	Base      string
	Household *domain.Household
	Members   []domain.Member
	Invites   []domain.Invite
	Guests    []service.GuestLink
	Devices   []domain.Credential
	Homes     []service.WebHome
	Lists     []service.WebList
	Owner     bool
	Me        string
	// Credential is the one this browser is signed in with.
	Credential string
	Error      string
}

func (h *Web) appFamily(w http.ResponseWriter, r *http.Request, sess *auth.Session, sc domain.Scope) {
	h.renderFamily(w, r, sess, sc, http.StatusOK, "")
}

func (h *Web) renderFamily(w http.ResponseWriter, r *http.Request, sess *auth.Session, sc domain.Scope, status int, problem string) {
	ctx := r.Context()
	hh, err := h.svc.Household(ctx, sc)
	if err != nil {
		h.fail(w, r, err)
		return
	}
	members, err := h.svc.Members(ctx, sc)
	if err != nil {
		h.fail(w, r, err)
		return
	}
	me, err := h.svc.Me(ctx, sess.User)
	if err != nil {
		h.fail(w, r, err)
		return
	}
	d := familyData{Base: "/app/h/" + sc.HouseholdID, Household: hh, Members: members, Devices: me.Credentials, Owner: sc.Role == domain.RoleOwner, Me: sess.User, Credential: sess.Credential, Error: problem}
	if d.Owner {
		if d.Invites, err = h.svc.Invites(ctx, sc); err != nil {
			h.fail(w, r, err)
			return
		}
		if d.Guests, err = h.svc.Guests(ctx, sc); err != nil {
			h.fail(w, r, err)
			return
		}
		if d.Homes, err = h.svc.WebHomes(ctx, sc); err != nil {
			h.fail(w, r, err)
			return
		}
		lists, err := h.svc.WebLists(ctx, sc)
		if err != nil {
			h.fail(w, r, err)
			return
		}
		for _, l := range lists {
			if !l.Personal {
				d.Lists = append(d.Lists, l)
			}
		}
	}
	p, err := h.memberPage(r, sess, sc, "Family", "family")
	if err != nil {
		h.fail(w, r, err)
		return
	}
	p.Live = false
	p.Data = d
	h.render(w, status, "app_family", p)
}

type linkData struct {
	Title string
	What  string
	URL   string
	QR    template.HTML
	Back  string
}

// showLink is the page after an invite or a guest link was made: the QR and
// the link, shown once.
func (h *Web) showLink(w http.ResponseWriter, r *http.Request, sc domain.Scope, title, what, link string) {
	svg, err := qrSVG(link)
	if err != nil {
		h.fail(w, r, err)
		return
	}
	h.render(w, http.StatusOK, "app_link", page{Title: title, Member: true, Nav: "family", CSRF: h.members.From(r).CSRF, Household: sc.HouseholdID, Data: linkData{Title: title, What: what, URL: link, QR: template.HTML(svg), Back: "/app/h/" + sc.HouseholdID + "/family"}}) //nolint:gosec // G203: our own QR
}

func (h *Web) appInvite(w http.ResponseWriter, r *http.Request, sess *auth.Session, sc domain.Scope) {
	role := domain.RoleMember
	if r.PostFormValue("role") == "owner" {
		role = domain.RoleOwner
	}
	inv, err := h.svc.CreateInvite(r.Context(), sc, role)
	if h.problem(w, r, err, func(msg string) { h.renderFamily(w, r, sess, sc, http.StatusUnprocessableEntity, msg) }) {
		return
	}
	h.showLink(w, r, sc, "Invite", "Show this to the new member, or send them the link. It works once, as "+string(role)+", for "+strconv.Itoa(h.InviteDays)+" days.", inv.URL)
}

func (h *Web) appRevokeInvite(w http.ResponseWriter, r *http.Request, sess *auth.Session, sc domain.Scope) {
	if h.problem(w, r, h.svc.RevokeInvite(r.Context(), sc, r.PathValue("id")), nil) {
		return
	}
	h.back(w, r, sc, "family")
}

func (h *Web) appGuestLink(w http.ResponseWriter, r *http.Request, sess *auth.Session, sc domain.Scope) {
	days, _ := strconv.Atoi(r.PostFormValue("days"))
	g, err := h.svc.CreateGuestLink(r.Context(), sc, r.PostFormValue("home"), r.PostFormValue("list"), strings.TrimSpace(r.PostFormValue("label")), days)
	if h.problem(w, r, err, func(msg string) { h.renderFamily(w, r, sess, sc, http.StatusUnprocessableEntity, msg) }) {
		return
	}
	h.showLink(w, r, sc, "Guest link", "Send this to "+g.Link.Label+". It opens one home and one list until "+domain.FromMillis(g.Link.ExpiresAt).Format("2 Jan 2006")+".", g.URL)
}

func (h *Web) appRevokeGuest(w http.ResponseWriter, r *http.Request, sess *auth.Session, sc domain.Scope) {
	if h.problem(w, r, h.svc.RevokeGuest(r.Context(), sc, r.PathValue("id")), nil) {
		return
	}
	h.back(w, r, sc, "family")
}

func (h *Web) appRemoveMember(w http.ResponseWriter, r *http.Request, sess *auth.Session, sc domain.Scope) {
	err := h.svc.RemoveMember(r.Context(), sc, r.PathValue("person"))
	if h.problem(w, r, err, func(msg string) { h.renderFamily(w, r, sess, sc, http.StatusUnprocessableEntity, msg) }) {
		return
	}
	h.back(w, r, sc, "family")
}

func (h *Web) appRevokeDevice(w http.ResponseWriter, r *http.Request, sess *auth.Session, sc domain.Scope) {
	id := r.PathValue("id")
	if h.problem(w, r, h.svc.RevokeCredential(r.Context(), sess.User, id), nil) {
		return
	}
	if id == sess.Credential {
		// the browser revoked what signed it in
		h.members.End(w, r)
		http.Redirect(w, r, "/app", http.StatusSeeOther)
		return
	}
	h.back(w, r, sc, "family")
}
