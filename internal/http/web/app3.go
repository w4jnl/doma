package web

import (
	"net/http"
	"net/url"

	"github.com/w4jnl/doma/internal/auth"
	"github.com/w4jnl/doma/internal/domain"
	"github.com/w4jnl/doma/internal/service"
)

// History and All items: what the family bought, a month at a time, and the
// catalog where it tidies its items, as the phone has them.

func (h *Web) mountApp3(mux *http.ServeMux) {
	mux.HandleFunc("GET /app/h/{household}/history", h.inHousehold(h.appHistory))
	mux.HandleFunc("GET /app/h/{household}/items", h.inHousehold(h.appItems))
	mux.HandleFunc("POST /app/h/{household}/items/{item}/rename", h.inHousehold(h.appRenameItem))
	mux.HandleFunc("POST /app/h/{household}/items/{item}/merge", h.inHousehold(h.appMergeItem))
	mux.HandleFunc("POST /app/h/{household}/items/{item}/retire", h.inHousehold(h.appRetireItem))
}

type historyData struct {
	Base string
	View *service.WebHistory
}

func (h *Web) appHistory(w http.ResponseWriter, r *http.Request, sess *auth.Session, sc domain.Scope) {
	view, err := h.svc.WebHistory(r.Context(), sc, r.URL.Query().Get("month"))
	if h.problem(w, r, err, nil) {
		return
	}
	p, err := h.memberPage(r, sess, sc, "History", "history")
	if err != nil {
		h.fail(w, r, err)
		return
	}
	p.Live = false
	p.Data = historyData{Base: "/app/h/" + sc.HouseholdID, View: view}
	h.render(w, http.StatusOK, "app_history", p)
}

type itemsData struct {
	Base  string
	Items []service.WebItem
	// All is every item's name, for the field that asks which one to merge into.
	All    []string
	Search string
	Error  string
	// The item whose row is a field for its name, the one being merged, and
	// the one whose Retire waits for its second word, from the page's query.
	Rename, Merge, Arm string
}

func (h *Web) appItems(w http.ResponseWriter, r *http.Request, sess *auth.Session, sc domain.Scope) {
	h.renderItems(w, r, sess, sc, http.StatusOK, "")
}

func (h *Web) renderItems(w http.ResponseWriter, r *http.Request, sess *auth.Session, sc domain.Scope, status int, problem string) {
	q := r.URL.Query()
	items, err := h.svc.WebItems(r.Context(), sc, q.Get("q"))
	if h.problem(w, r, err, nil) {
		return
	}
	d := itemsData{Base: "/app/h/" + sc.HouseholdID, Items: items, Search: q.Get("q"), Error: problem, Rename: q.Get("rename"), Merge: q.Get("merge"), Arm: q.Get("arm")}
	if d.Merge != "" {
		all, err := h.svc.WebItems(r.Context(), sc, "")
		if h.problem(w, r, err, nil) {
			return
		}
		for _, it := range all {
			if it.ID != d.Merge {
				d.All = append(d.All, it.Name)
			}
		}
	}
	p, err := h.memberPage(r, sess, sc, "All items", "history")
	if err != nil {
		h.fail(w, r, err)
		return
	}
	p.Live = false
	p.Data = d
	h.render(w, status, "app_items", p)
}

// itemsDone answers a tidy-up: the items again, the search kept, the field gone.
func (h *Web) itemsDone(w http.ResponseWriter, r *http.Request, sess *auth.Session, sc domain.Scope, err error) {
	if h.problem(w, r, err, func(msg string) { h.renderItems(w, r, sess, sc, http.StatusUnprocessableEntity, msg) }) {
		return
	}
	to := "/app/h/" + sc.HouseholdID + "/items"
	if s := r.PostFormValue("q"); s != "" {
		to += "?q=" + urlQuery(s)
	}
	http.Redirect(w, r, to, http.StatusSeeOther) //nolint:gosec // G710: the items of the scope's household
}

func (h *Web) appRenameItem(w http.ResponseWriter, r *http.Request, sess *auth.Session, sc domain.Scope) {
	h.itemsDone(w, r, sess, sc, h.svc.WebRenameItem(r.Context(), sc, sess.Credential, r.PathValue("item"), r.PostFormValue("name")))
}

func (h *Web) appMergeItem(w http.ResponseWriter, r *http.Request, sess *auth.Session, sc domain.Scope) {
	h.itemsDone(w, r, sess, sc, h.svc.WebMergeItem(r.Context(), sc, sess.Credential, r.PathValue("item"), r.PostFormValue("into")))
}

func (h *Web) appRetireItem(w http.ResponseWriter, r *http.Request, sess *auth.Session, sc domain.Scope) {
	h.itemsDone(w, r, sess, sc, h.svc.WebRetireItem(r.Context(), sc, sess.Credential, r.PathValue("item")))
}

func urlQuery(s string) string { return url.QueryEscape(s) }
