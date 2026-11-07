# Security policy

doma is a network service for one family or a few. It serves a sync endpoint to the family's
iPhones and Macs, a web page to guests who were given a link, and admin pages to the operator.
The attack surface is small and named; what an attacker can reach, and what stands in the way:

- **Device keys.** Every app request is signed with a key that never leaves the phone's
  Keychain; the server checks the signature, a five minute timestamp window and a nonce per
  credential. A lost phone is revoked from the Family screen or `/admin`, and its next request
  gets 401.
- **Invites and guest links** are 256-bit random tokens stored as SHA-256, shown once in a QR
  or link, single use for invites and time-limited for both; lookups are constant-time and rate
  limited per address.
- **Households** are the tenant boundary. Every query on family data filters on the household,
  a guest sees one home and one list, and anything outside the caller's households is a 404,
  never a 403, so households cannot be enumerated.
- **Photos** are re-encoded server-side to strip metadata and served with `nosniff` from signed
  URLs; the quota is enforced before the body is read.
- **The web client** signs a family member's browser in by a passkey (WebAuthn, discoverable,
  through go-webauthn) or, the first time, by their phone vouching for the browser with a signed
  request and a single-use five minute code. Its session cookie and forms are guarded like the
  admin's.
- **The admin login** is argon2id with a `Secure, HttpOnly, SameSite=Lax` session cookie, CSRF
  double-submit on every form, a login rate limit and optional TOTP.
- **Outbound.** The server makes no outbound connection except to APNs when `push.enabled` is
  on and to the vision model the operator names when `vision.enabled` is on (an endpoint of
  their own, or `api.anthropic.com` with `vision.provider = "anthropic"`), and none at all
  with both off. The model is sent a picture and the names of the home's staples, nothing about
  the people. No update check, no telemetry, no CDN; CI greps for dials outside the push and
  vision packages.
- **Secrets at rest.** The APNs key and the admin TOTP secret are encrypted under
  `secrets.key_file`. Back it up with the database.

## Supported versions

Only the latest release gets fixes. Update from the
[releases page](https://github.com/w4jnl/doma/releases) or pull the next image.

## Reporting a vulnerability

Use GitHub's private vulnerability reporting for this repository:
<https://github.com/w4jnl/doma/security/advisories/new>. Describe what the attacker controls (a
signed request, an invite or guest link, a photo upload, the admin login) and what they gain.
You will get an answer within a week; fixes ship as a patch release with a note in
`CHANGELOG.md`. Please do not open a public issue for something exploitable before it is fixed.

## Deployment advice

- Terminate TLS at your proxy and set `server.base_url` to the public https address, so the
  admin cookie is `Secure` and invite and guest links are right.
- Put no sign-in in front of doma: it authenticates every route itself, and invite and guest
  links must open from a phone on mobile data.
- Back up the database, the photos directory and `secret.key` together; `/admin/server` has
  *Back up now*.
