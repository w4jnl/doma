// doma's own script for the family's pages, served from /static under the page's CSP, no
// library. Two things: the page hears that its household changed and asks for its rows again,
// and the arrow keys walk the matches under the add field.
(function () {
  'use strict';
  var shell = document.querySelector('[data-live]');
  if (shell && window.EventSource) {
    var stream = null;
    var tell = function () {
      // a row being edited is not pulled from under the person; the save reads the rows again
      if (document.querySelector('[data-editing]')) return;
      document.body.dispatchEvent(new Event('doma:changed'));
    };
    var open = function () {
      if (stream) return;
      stream = new EventSource(shell.getAttribute('data-live'));
      stream.addEventListener('changed', tell);
    };
    var close = function () {
      if (!stream) return;
      stream.close();
      stream = null;
    };
    // a tab out of sight listens to nothing; back in sight it catches up at once
    document.addEventListener('visibilitychange', function () {
      if (document.visibilityState === 'visible') { open(); tell(); } else { close(); }
    });
    open();
  }
  document.addEventListener('keydown', function (e) {
    var add = document.getElementById('add');
    var box = document.getElementById('suggest');
    if (!add || !box) return;
    var rows = box.querySelectorAll('button');
    var at = Array.prototype.indexOf.call(rows, document.activeElement);
    if (document.activeElement !== add && at < 0) return;
    if (e.key === 'ArrowDown' && rows.length) {
      e.preventDefault();
      rows[Math.min(at + 1, rows.length - 1)].focus();
    } else if (e.key === 'ArrowUp' && at >= 0) {
      e.preventDefault();
      (at === 0 ? add : rows[at - 1]).focus();
    } else if (e.key === 'Escape' && rows.length) {
      box.textContent = '';
      add.focus();
    }
  });
})();
