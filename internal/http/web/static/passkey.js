// Passkeys for the web client: the two WebAuthn ceremonies, each a JSON round trip with the
// server. Buttons carry data-passkey="login" or "register"; a browser without passkeys sees
// no button at all. Our own file, no library, served from /static under the page's CSP.
(function () {
  'use strict';
  var buttons = document.querySelectorAll('[data-passkey]');
  if (!buttons.length) return;
  if (!window.PublicKeyCredential || !navigator.credentials) {
    buttons.forEach(function (b) { b.hidden = true; });
    return;
  }
  function toB64(buf) {
    var s = '';
    new Uint8Array(buf).forEach(function (c) { s += String.fromCharCode(c); });
    return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
  }
  function fromB64(s) {
    s = s.replace(/-/g, '+').replace(/_/g, '/');
    while (s.length % 4) s += '=';
    var bin = atob(s), out = new Uint8Array(bin.length);
    for (var i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
    return out;
  }
  function say(text) {
    var p = document.getElementById('passkey-error');
    if (!p) return;
    p.textContent = text;
    p.hidden = !text;
  }
  function csrf() {
    var m = document.querySelector('meta[name="csrf"]');
    return m ? m.content : '';
  }
  async function call(path, body) {
    var r = await fetch(path, {
      method: body ? 'POST' : 'GET',
      credentials: 'same-origin',
      headers: body ? { 'Content-Type': 'application/json', 'X-CSRF-Token': csrf() } : {},
      body: body ? JSON.stringify(body) : undefined
    });
    var data = null;
    try { data = await r.json(); } catch (e) { data = null; }
    if (!r.ok) throw new Error((data && data.error) || ('The server said ' + r.status + '.'));
    return data;
  }
  async function login() {
    var opts = (await call('/app/passkey/login/begin')).publicKey;
    opts.challenge = fromB64(opts.challenge);
    (opts.allowCredentials || []).forEach(function (c) { c.id = fromB64(c.id); });
    var cred = await navigator.credentials.get({ publicKey: opts });
    var res = cred.response;
    var out = await call('/app/passkey/login/finish', {
      id: cred.id, rawId: toB64(cred.rawId), type: cred.type,
      response: {
        clientDataJSON: toB64(res.clientDataJSON), authenticatorData: toB64(res.authenticatorData),
        signature: toB64(res.signature), userHandle: res.userHandle ? toB64(res.userHandle) : null
      },
      clientExtensionResults: cred.getClientExtensionResults()
    });
    window.location.href = out.to || '/app';
  }
  async function register() {
    var opts = (await call('/app/passkey/register/begin')).publicKey;
    opts.challenge = fromB64(opts.challenge);
    opts.user.id = fromB64(opts.user.id);
    (opts.excludeCredentials || []).forEach(function (c) { c.id = fromB64(c.id); });
    var cred = await navigator.credentials.create({ publicKey: opts });
    var res = cred.response;
    var out = await call('/app/passkey/register/finish', {
      id: cred.id, rawId: toB64(cred.rawId), type: cred.type,
      response: {
        clientDataJSON: toB64(res.clientDataJSON), attestationObject: toB64(res.attestationObject),
        transports: res.getTransports ? res.getTransports() : []
      },
      clientExtensionResults: cred.getClientExtensionResults()
    });
    window.location.href = out.to || window.location.href;
  }
  buttons.forEach(function (b) {
    b.addEventListener('click', function () {
      say('');
      b.disabled = true;
      (b.dataset.passkey === 'register' ? register() : login())
        .catch(function (e) { say(e && e.name === 'NotAllowedError' ? 'Nothing happened. Try again.' : (e.message || String(e))); })
        .finally(function () { b.disabled = false; });
    });
  });
})();
