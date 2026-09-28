/*
 * secure_fetch.js - cross-cutting request behaviour for every page.
 * Loaded in <head> (base.html and admin_users.html) before any page script, so
 * every fetch() call in the app goes through it without the page knowing.
 *
 *  - CSRF: attaches the page's token (<meta name="csrf-token">) to every
 *    same-origin POST/PUT/PATCH/DELETE. If the server reports the token stale
 *    (X-CSRF-Failed - e.g. the user signed in again in another tab), fetch a
 *    fresh one and retry ONCE. The server rejected the first attempt before
 *    doing anything, so the retry is safe for any request.
 *  - A 401 marked X-Auth-Required means the session ended (expired, revoked,
 *    or the account was removed): go to the login page instead of leaving the
 *    page half-rendered. The login form's own wrong-password 401 carries no
 *    marker, so it never redirects.
 */
(function () {
    'use strict';
    if (window.__secureFetchInstalled) return;
    window.__secureFetchInstalled = true;

    var nativeFetch = window.fetch.bind(window);
    var UNSAFE = /^(POST|PUT|PATCH|DELETE)$/i;

    function pageToken() {
        var m = document.querySelector('meta[name="csrf-token"]');
        return m ? m.getAttribute('content') : '';
    }

    function sameOrigin(url) {
        try { return new URL(url, window.location.href).origin === window.location.origin; }
        catch (e) { return false; }
    }

    function prepare(input, init) {
        var opts = Object.assign({}, init || {});
        var isRequest = typeof Request !== 'undefined' && input instanceof Request;
        var method = (opts.method || (isRequest ? input.method : 'GET')).toUpperCase();
        var url = typeof input === 'string' ? input : (isRequest ? input.url : String(input));
        if (UNSAFE.test(method) && sameOrigin(url)) {
            var headers = new Headers(opts.headers || (isRequest ? input.headers : undefined));
            headers.set('X-CSRF-Token', pageToken());
            opts.headers = headers;
        }
        return opts;
    }

    window.fetch = function (input, init) {
        return nativeFetch(input, prepare(input, init)).then(function (res) {
            if (res.status === 403 && res.headers.get('X-CSRF-Failed') === '1'
                    && !(init && init.__csrfRetried)) {
                return nativeFetch('/api/csrf-token', { credentials: 'same-origin' })
                    .then(function (r) { return r.json(); })
                    .then(function (d) {
                        var m = document.querySelector('meta[name="csrf-token"]');
                        if (m && d && d.token) m.setAttribute('content', d.token);
                        return window.fetch(input, Object.assign({}, init || {}, { __csrfRetried: true }));
                    });
            }
            if (res.status === 401 && res.headers.get('X-Auth-Required') === '1'
                    && !window.__redirectingToLogin) {
                window.__redirectingToLogin = true;
                window.location.href = '/login?expired=1';
            }
            return res;
        });
    };
})();
