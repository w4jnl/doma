# doma behind Traefik and Authelia

A compose stack of three containers: Traefik terminates TLS, Authelia signs the operator in,
doma serves the family. Authelia stands in front of the admin pages only. Everything a phone, a
guest, the apps or a probe reach stays open, because those paths carry their own credential and
must work from a phone on mobile data without a browser sign-in.

| Who opens it | Paths | Through Authelia |
| --- | --- | --- |
| the operator, in a browser | `/`, `/setup`, `/admin` and everything under it | yes |
| a family member's phone browser, from an invite QR or link | `/i/…`, `/static/` | no |
| a guest with no app | `/g/…`, `/static/` | no |
| the apps | `/api/…`, `/sync/…`, `/photos/…` | no |
| probes and Prometheus | `/healthz`, `/readyz`, `/metrics` | no |

`traefik.yaml` has the two routers: `doma-open` at a higher priority with the open paths and no
middleware, `doma-admin` for the rest through Authelia's forward auth, which passes `Remote-User`
on and adds a shared secret. `/metrics` is open to the network, so set `DOMA_METRICS_TOKEN` and
it asks for `Authorization: Bearer <token>`.

**One sign-in.** doma runs with `admin.auth = proxy`: it takes the admin's name from `Remote-User`,
believed only from Traefik's addresses (`admin.proxy_cidrs`) when the request also carries
`X-Auth-Proxy-Secret` (`admin.proxy_secret`), on every request, and serves no password form. Sign
out goes to Authelia's logout page (`admin.proxy_logout_url`). The setup page still asks for an
admin password once; it is kept for a switch back to `admin.auth = password`, which is the
default and the whole gate on a host without Authelia, such as a dev or test setup with `make run`
or the plain `../traefik.yaml`. It is one or the other, never both.

**Who gets in.** Authelia's rule in `authelia/configuration.yml` admits the group `doma-admin`
with two factors. The group lives in LLDAP: Authelia's `lldap` backend reads a person's groups
from `memberOf`, so whoever is in the LLDAP group `doma-admin` may open the admin pages and nobody
else. The name has no colon because an LLDAP group is an LDAP `cn`.

## Already running Traefik, Authelia and LLDAP

You need three things from this folder, nothing else:

1. An LLDAP group `doma-admin` with the operator in it.
2. The `access_control` rule from `authelia/configuration.yml` in your Authelia configuration.
3. The `doma-open` and `doma-admin` routers, the `doma-secret` middleware and the `doma` service
   from `traefik.yaml` in your Traefik dynamic configuration, with `Remote-User` in your
   `authelia` middleware's `authResponseHeaders`.

Run doma itself from `../compose.yaml` or `../doma.service` on the same network, with
`DOMA_SERVER_BASE_URL` set to the https name, `DOMA_SERVER_TRUSTED_PROXIES` covering Traefik, and
the `[admin]` keys from `../doma.toml.example`: `auth = "proxy"`, `proxy_cidrs` with Traefik's
addresses, `proxy_secret` the same value Traefik adds, and `proxy_logout_url` if you want Sign out.

## A fresh stack

LLDAP is assumed to run already, on a docker network named in `.env`, with a read-only service
user `uid=authelia`; Authelia joins that network. Then:

```sh
cp .env.example .env     # hostnames, mail, the LLDAP base DN and bind password, two random secrets
docker compose up -d
```

Open `https://doma.example.com`. Authelia asks for the LLDAP account and a second factor, then
doma's setup page asks for a name and a password, once. From there the README at the repository
root continues: create the household, make the owner invite, scan it with the app.

For a trial without LLDAP, switch `authelia/configuration.yml` to the file backend as its comment
says; `authelia/users_database.yml` has one user, `operator` with the password `change-me`, in the
group `doma-admin`. Drop the `lldap` network from `compose.yaml` for that.

## Check it

Run from outside, through the proxy, with your own names:

```sh
B=https://doma.example.com
curl -sI $B/admin | grep -i '^location'       # Authelia's sign-in page
curl -sI $B/i/x | head -1                      # 404 from doma, no redirect
curl -sI $B/g/x | head -1                      # 404 from doma, no redirect
curl -s  $B/healthz                            # ok <version>
curl -sI -X POST $B/sync/v1 | head -1          # 401 from doma, no redirect
```

Then from a phone on mobile data: open an invite QR with the camera, the invite page loads and
its button opens doma; the app syncs; a guest link opens in Safari. In a browser, `/admin` goes
through Authelia straight to the households page, with no second password; `doma serve -d` logs
"admin signed in by the proxy" with the name, or "proxy sign-in refused" with the reason.

`go test ./internal/http -run TestOpenPathsNeedNoBrowserSession` reads the open router's rule from
`traefik.yaml` and checks it against the server's routes, so a new route and this folder cannot
drift apart.

## When something is off

- The invite page or a guest link lands on Authelia: the `doma-open` router lost its priority, or
  a path is missing from its rule. Compare with the table above.
- Authelia says access denied after a correct sign-in: the account is not in the LLDAP group
  `doma-admin`, or the rule's `domain` does not match `DOMA_HOST`.
- Pictures stay pending in the app and never show on another phone: `/photos/` is missing from
  the `doma-open` rule, so the uploads and downloads land on Authelia's sign-in.
- `/metrics` answers anyone: `DOMA_METRICS_TOKEN` is empty.
- After Authelia, doma shows "Sign in first": the name or the secret did not arrive. The log says
  which: the peer is outside `admin.proxy_cidrs`, `X-Auth-Proxy-Secret` differs from
  `admin.proxy_secret` (Traefik and doma must read the same `DOMA_ADMIN_PROXY_SECRET`), or
  `Remote-User` is missing from the `authelia` middleware's `authResponseHeaders`.
- The admin is signed out on every request: `DOMA_SERVER_BASE_URL` is not https, so doma's
  session cookie is not marked Secure and the browser drops it on an https page.
- Traefik logs a template error: `DOMA_HOST` or `AUTH_HOST` is missing from its environment; the
  file provider expands `{{ env "…" }}`, not `${…}`.
