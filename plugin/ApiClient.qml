// ApiClient.qml - Anytype HTTP client (localhost + server modes).
//
// Owns: effective base URL resolution, token resolution precedence
// (env -> config.toml -> pluginSettings), challenge pairing (localhost),
// request assembly, error classification, Retry-After-aware single retry,
// and single-flight guard per path.
//
// Everything else in the plugin (notifier, quick-add) goes through this.

import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons

QtObject {
    id: client

    // --- Externally injected ---
    property var pluginApi: null
    // ConfigFile component - set by Main.qml so we can read ~/.config/anytype-noctalia/config.toml
    property var configFile: null

    // --- Settings-fed properties ---
    property var cfg: pluginApi?.pluginSettings || ({})
    property var defaults: pluginApi?.manifest?.metadata?.defaultSettings || ({})

    readonly property string mode: cfg.mode ?? defaults.mode ?? "localhost"
    readonly property string baseUrl: cfg.baseUrl ?? defaults.baseUrl ?? "http://127.0.0.1:31009"
    readonly property string serverUrl: cfg.serverUrl ?? defaults.serverUrl ?? ""
    readonly property string envApiKey: Quickshell.env("ANYTYPE_API_KEY") || ""

    // --- Signals ---
    signal errorClassified(string path, var classification)
    signal pairingSucceeded(string apiKey)
    signal pairingFailed(string reason)

    // --- Single-flight guard ---
    // paths currently in-flight; subsequent calls for the same path are dropped
    property var _inFlight: ({})

    // --- Error classes ---
    // ok | offline | unauthorized | notFound | rateLimited | serverError | parseError | notPaired | timeout

    // ============================================================
    // D9: Deployment-mode selection
    // ============================================================

    function effectiveBaseUrl() {
        if (mode === "server") {
            return (serverUrl || "").replace(/\/+$/, "");
        }
        return (baseUrl || "http://127.0.0.1:31009").replace(/\/+$/, "");
    }

    function offlineHint() {
        // openAnytypeDesktop: whether the Panel should hint "start Anytype desktop"
        return { openAnytypeDesktop: mode === "localhost" };
    }

    // ============================================================
    // D8: Token resolution precedence (env -> config file -> settings)
    // ============================================================

    function resolveToken() {
        if (envApiKey && envApiKey.length > 0) return envApiKey;
        if (configFile && configFile.apiKey && configFile.apiKey.length > 0) return configFile.apiKey;
        if (cfg.apiKey && cfg.apiKey.length > 0) return cfg.apiKey;
        return "";
    }

    function tokenSource() {
        // for Settings UI to show "env var" / "config file" / "plugin settings" / "none"
        if (envApiKey && envApiKey.length > 0) return "env";
        if (configFile && configFile.apiKey && configFile.apiKey.length > 0) return "config";
        if (cfg.apiKey && cfg.apiKey.length > 0) return "settings";
        return "none";
    }

    // ============================================================
    // Error classification (spec: api-client "Error classification")
    // ============================================================

    function classify(xhr) {
        // Called from onreadystatechange when readyState === DONE.
        // Returns {class, status, retryAfter?, shouldRePair?, hint?}
        var status = xhr.status || 0;

        if (status === 0) {
            return { class: "offline", status: 0, hint: offlineHint() };
        }
        if (status === 200 || status === 201 || status === 204) {
            return { class: "ok", status: status };
        }
        if (status === 401 || status === 403) {
            return { class: "unauthorized", status: status, shouldRePair: true };
        }
        if (status === 404) {
            return { class: "notFound", status: status };
        }
        if (status === 429) {
            var retryAfter = parseInt(xhr.getResponseHeader("Retry-After") || "", 10);
            if (isNaN(retryAfter) || retryAfter <= 0) retryAfter = 2;
            return { class: "rateLimited", status: 429, retryAfter: retryAfter };
        }
        if (status >= 500 && status < 600) {
            return { class: "serverError", status: status };
        }
        return { class: "serverError", status: status };
    }

    // ============================================================
    // Core request (get/post) + single-flight + 429 retry
    // ============================================================

    function _buildUrl(path) {
        var base = effectiveBaseUrl();
        if (path.indexOf("/") !== 0) path = "/" + path;
        return base + path;
    }

    // callback(result): result = {ok: bool, class, status, data?, error?}
    function _request(method, path, body, authed, callback) {
        if (_inFlight[path]) {
            // single-flight: drop silently
            return;
        }

        var token = authed ? resolveToken() : "";
        if (authed && token.length === 0) {
            var np = { ok: false, class: "notPaired", status: 0, error: "no token" };
            errorClassified(path, np);
            if (callback) callback(np);
            return;
        }

        _inFlight[path] = true;

        var attempt = 0;
        var doSend = function() {
            attempt++;
            var xhr = new XMLHttpRequest();
            xhr.timeout = 10000; // 10 s per spec
            xhr.ontimeout = function() {
                delete _inFlight[path];
                var r = { ok: false, class: "offline", status: 0, hint: offlineHint(), error: "timeout" };
                errorClassified(path, r);
                if (callback) callback(r);
            };
            xhr.onreadystatechange = function() {
                if (xhr.readyState !== XMLHttpRequest.DONE) return;

                var c = classify(xhr);

                // 429 single retry per spec "Rate-limit-friendly retry"
                if (c.class === "rateLimited" && attempt === 1) {
                    var ms = (c.retryAfter || 2) * 1000;
                    Logger && Logger.w && Logger.w("anytype", "429, retrying in", ms, "ms");
                    _retryTimer.delay = ms;
                    _retryTimer.callback = doSend;
                    _retryTimer.start();
                    return;
                }

                delete _inFlight[path];

                var data = null;
                if (c.class === "ok" && xhr.responseText) {
                    try {
                        data = JSON.parse(xhr.responseText);
                    } catch (e) {
                        c = { class: "parseError", status: xhr.status, error: e.toString() };
                    }
                }

                var res = {
                    ok: c.class === "ok",
                    class: c.class,
                    status: c.status,
                    retryAfter: c.retryAfter,
                    shouldRePair: c.shouldRePair,
                    hint: c.hint,
                    data: data,
                    error: xhr.responseText
                };

                if (!res.ok) errorClassified(path, res);
                if (callback) callback(res);
            };

            xhr.open(method, _buildUrl(path));
            if (authed && token.length > 0) {
                xhr.setRequestHeader("Authorization", "Bearer " + token);
            }
            if (body) {
                xhr.setRequestHeader("Content-Type", "application/json");
                xhr.send(JSON.stringify(body));
            } else {
                xhr.send();
            }
        };

        doSend();
    }

    // Hidden Timer used for the single 429 retry.
    property Timer _retryTimer: Timer {
        property int delay: 0
        property var callback: null
        interval: delay
        repeat: false
        running: false
        onTriggered: {
            if (callback) {
                var cb = callback;
                callback = null;
                cb();
            }
        }
    }

    // ============================================================
    // Public API (used by notifier + quick-add)
    // ============================================================

    function get(path, callback) {
        _request("GET", path, null, true, callback);
    }

    function post(path, body, callback) {
        _request("POST", path, body, true, callback);
    }

    function listSpaces(callback) {
        get("/v1/spaces", callback);
    }

    function listSpaceLists(spaceId, callback) {
        // v1 endpoint for collections / sets
        get("/v1/spaces/" + encodeURIComponent(spaceId) + "/lists", callback);
    }

    function listCollectionObjects(spaceId, collectionId, sinceTs, callback) {
        // Primary endpoint for the notifier. On v1 we fall back to global
        // list filtered by type/collection; v2 has a first-class
        // /v2/.../collections/{id}/objects endpoint.
        var path = "/v1/spaces/" + encodeURIComponent(spaceId)
                 + "/lists/" + encodeURIComponent(collectionId)
                 + "/objects?sort=-last_modified_date";
        if (sinceTs && sinceTs > 0) {
            path += "&since=" + sinceTs;
        }
        get(path, callback);
    }

    function createObject(spaceId, body, callback) {
        post("/v1/spaces/" + encodeURIComponent(spaceId) + "/objects", body, callback);
    }

    function addToCollection(spaceId, listId, ids, callback) {
        post("/v1/spaces/" + encodeURIComponent(spaceId) + "/lists/" + encodeURIComponent(listId) + "/objects", ids, callback);
    }

    // ============================================================
    // Pairing (localhost mode: challenge; server mode: token paste)
    // ============================================================

    function requestChallenge(appName, callback) {
        // POST /v1/auth/challenges  (unauthed)
        _request("POST", "/v1/auth/challenges", { app_name: appName || "anytype-noctalia" }, false, callback);
    }

    function pair(challengeId, code, callback) {
        // POST /v1/auth/api_keys  (unauthed)
        _request("POST", "/v1/auth/api_keys", { challenge_id: challengeId, code: code }, false, function(res) {
            if (res.ok && res.data && res.data.api_key) {
                pairingSucceeded(res.data.api_key);
            } else {
                pairingFailed(res.class === "ok" ? "no api_key in response" : res.class);
            }
            if (callback) callback(res);
        });
    }

    // Server-mode: no challenge endpoint, user pastes the token directly.
    // This writes the token through the same precedence chain (preferring config file).
    function setTokenDirectly(apiKey) {
        if (configFile && configFile.writable) {
            configFile.setApiKey(apiKey);
        } else if (pluginApi) {
            pluginApi.pluginSettings.apiKey = apiKey;
            pluginApi.saveSettings();
        }
        pairingSucceeded(apiKey);
    }
}
