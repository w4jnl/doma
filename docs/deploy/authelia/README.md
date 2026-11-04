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
| the apps | `/api/…`, `/sync/…` | no |
| probes and Prometheus | `/healthz`, `/readyz`, `/metrics` | no |

`traefik.yaml` has the two routers: `doma-open` at a higher priority with the open paths and no
middleware, `doma-admin` for the rest through Authelia's forward auth. `/metrics` is open to the
network, so set `DOMA_METRICS_TOKEN` and it asks for `Authorization: Bearer <token>`.

**Two sign-ins, on purpose.** doma reads no identity header from the proxy, so behind Authelia the
operator passes Authelia and then types doma's own admin password, once per twelve hours. Keep
doma's TOTP off when Authelia does the second factor. On a host without Authelia, such as a dev
or test setup with `make run` or the plain `../traefik.yaml`, that same password is the whole
gate: nothing to configure, nothing to switch.

**Who gets in.** Authelia's rule in `authelia/configuration.yml` admits the group `doma-admin`
with two factors. The group lives in LLDAP: Authelia's `lldap` backend reads a person's groups
from `memberOf`, so whoever is in the LLDAP group `doma-admin` may open the admin pages and nobody
else. The name has no colon because an LLDAP group is an LDAP `cn`.

## Already running Traefik, Authelia and LLDAP

You need three things from this folder, nothing else:

1. An LLDAP group `doma-admin` with the operator in it.
2. The `access_control` rule from `authelia/configuration.yml` in your Authelia configuration.
3. The `doma-open` and `doma-admin` routers and the `doma` service from `traefik.yaml` in your
   Traefik dynamic configuration, with the `authelia` middleware you already have.

Run doma itself from `../compose.yaml` or `../doma.service` on the same network, with
`DOMA_SERVER_BASE_URL` set to the https name and `DOMA_SERVER_TRUSTED_PROXIES` covering Traefik.

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
through Authelia, then doma's password, then the households page.

`go test ./internal/http -run TestOpenPathsNeedNoBrowserSession` reads the open router's rule from
`traefik.yaml` and checks it against the server's routes, so a new route and this folder cannot
drift apart.

## When something is off

- The invite page or a guest link lands on Authelia: the `doma-open` router lost its priority, or
  a path is missing from its rule. Compare with the table above.
- Authelia says access denied after a correct sign-in: the account is not in the LLDAP group
  `doma-admin`, or the rule's `domain` does not match `DOMA_HOST`.
- `/metrics` answers anyone: `DOMA_METRICS_TOKEN` is empty.
- The admin is signed out on every request: `DOMA_SERVER_BASE_URL` is not https, so doma's
  session cookie is not marked Secure and the browser drops it on an https page.
- Traefik logs a template error: `DOMA_HOST` or `AUTH_HOST` is missing from its environment; the
  file provider expands `{{ env "…" }}`, not `${…}`.
