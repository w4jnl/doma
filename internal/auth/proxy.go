package auth

import (
	"crypto/subtle"
	"net"
	"net/http"
)

// The proxy's sign-in: with admin.auth = "proxy" the reverse proxy in front
// (Authelia behind Traefik) signs the admin in and names them in Remote-User.
// doma believes the header only from a peer inside the trusted networks that
// also sends the shared secret; those two settings are the whole boundary,
// so a wide network or a leaked secret is an admin.
const (
	ProxyUserHeader   = "Remote-User"
	ProxySecretHeader = "X-Auth-Proxy-Secret" //nolint:gosec // G101: the header's name, not a secret
)

// Proxy checks a request's proxy identity.
type Proxy struct {
	nets   []*net.IPNet
	secret string
	// LogoutURL is where Sign out sends the browser, the proxy's own logout
	// page; empty hides the button.
	LogoutURL string
}

// NewProxy returns a checker for peers in cidrs, which config validated,
// carrying the secret.
func NewProxy(cidrs []string, secret, logoutURL string) *Proxy {
	p := &Proxy{secret: secret, LogoutURL: logoutURL}
	for _, c := range cidrs {
		if _, n, err := net.ParseCIDR(c); err == nil {
			p.nets = append(p.nets, n)
		}
	}
	return p
}

// Identify returns the user the proxy vouches for, or "" and why not. The
// peer is the direct connection, never X-Forwarded-For: the proxy itself
// must be the one talking.
func (p *Proxy) Identify(r *http.Request) (user, reason string) {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		host = r.RemoteAddr
	}
	ip := net.ParseIP(host)
	trusted := false
	for _, n := range p.nets {
		if ip != nil && n.Contains(ip) {
			trusted = true
			break
		}
	}
	if !trusted {
		return "", "peer " + host + " is not in admin.proxy_cidrs"
	}
	if subtle.ConstantTimeCompare([]byte(r.Header.Get(ProxySecretHeader)), []byte(p.secret)) != 1 {
		return "", ProxySecretHeader + " does not match admin.proxy_secret"
	}
	user = r.Header.Get(ProxyUserHeader)
	if user == "" {
		return "", "no " + ProxyUserHeader + " header"
	}
	return user, ""
}
