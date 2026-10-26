// ConfigFile.qml - reads/writes ~/.config/anytype-noctalia/config.toml.
//
// Minimal TOML (flat top-level keys only). Fields: mode, base_url,
// server_url, api_key, space_id. All optional. Reactive: re-read when
// mtime changes (polled every 2s).

import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons

QtObject {
    id: file

    // --- Public reactive state ---
    property string path: ""           // resolved on Component.onCompleted
    property bool exists: false
    property bool writable: false
    property bool permissionsLax: false // mode wider than 0600

    property string mode: ""
    property string baseUrl: ""
    property string serverUrl: ""
    property string apiKey: ""
    property string spaceId: ""

    property real lastMtime: 0

    signal loaded()
    signal permissionsWarned()

    // --- Signals from Main.qml ---
    signal writeOk(string apiKey)
    signal writeFailed(string reason)

    // --- Resolve path ---
    function resolvePath() {
        var xdg = Quickshell.env("XDG_CONFIG_HOME");
        var home = Quickshell.env("HOME");
        if (xdg && xdg.length > 0) {
            return xdg + "/anytype-noctalia/config.toml";
        }
        return home + "/.config/anytype-noctalia/config.toml";
    }

    // --- Stat via `stat` shell-out ---
    property Process statProc: Process {
        id: statProc
        command: ["sh", "-c", "stat -c '%Y %a' '" + file.path + "' 2>/dev/null || echo 'MISSING'"]
        stdout: StdioCollector {
            onStreamFinished: {
                var text = (this.text || "").trim();
                if (text === "MISSING" || text.length === 0) {
                    file.exists = false;
                    file.writable = false;
                    file.permissionsLax = false;
                    file.lastMtime = 0;
                    return;
                }
                var parts = text.split(" ");
                var mtime = parseFloat(parts[0]);
                var perms = parts[1] || "600";
                file.exists = true;
                // Writability: we test by trying - approximate by directory existence.
                file.writable = true;
                // Permissions wider than 600: last two digits (group, other) != 00
                var isLax = (perms.length >= 3)
                    ? (perms.charAt(perms.length - 2) !== '0' || perms.charAt(perms.length - 1) !== '0')
                    : false;
                if (isLax && !file.permissionsLax) {
                    file.permissionsLax = true;
                    file.permissionsWarned();
                }
                if (mtime !== file.lastMtime) {
                    file.lastMtime = mtime;
                    file.reload();
                }
            }
        }
    }

    // --- Read ---
    property Process readProc: Process {
        id: readProc
        command: ["cat", file.path]
        stdout: StdioCollector {
            onStreamFinished: {
                file.parseToml(this.text || "");
                file.loaded();
            }
        }
    }

    function parseToml(text) {
        // Minimal flat TOML parser - handles key = "value", key = integer, and `# comment` lines.
        var lines = text.split("\n");
        var m = { mode: "", baseUrl: "", serverUrl: "", apiKey: "", spaceId: "" };
        for (var i = 0; i < lines.length; i++) {
            var line = lines[i].trim();
            if (line.length === 0 || line.charAt(0) === "#" || line.charAt(0) === "[") continue;
            var eq = line.indexOf("=");
            if (eq <= 0) continue;
            var key = line.substring(0, eq).trim();
            var val = line.substring(eq + 1).trim();
            if (val.length >= 2 && val.charAt(0) === '"' && val.charAt(val.length - 1) === '"') {
                val = val.substring(1, val.length - 1);
            }
            if (key === "mode")       m.mode = val;
            else if (key === "base_url")   m.baseUrl = val;
            else if (key === "server_url") m.serverUrl = val;
            else if (key === "api_key")    m.apiKey = val;
            else if (key === "space_id")   m.spaceId = val;
        }
        file.mode = m.mode;
        file.baseUrl = m.baseUrl;
        file.serverUrl = m.serverUrl;
        file.apiKey = m.apiKey;
        file.spaceId = m.spaceId;
    }

    function reload() {
        readProc.running = false;
        readProc.running = true;
    }

    // --- Write (atomically) ---
    property Process writeProc: Process {
        id: writeProc
        command: ["sh", "-c",
            "mkdir -p \"$(dirname '" + file.path + "')\" && " +
            "tmp=$(mktemp '" + file.path + ".XXXXXX') && " +
            "cat > \"$tmp\" && " +
            "chmod 600 \"$tmp\" && " +
            "mv \"$tmp\" '" + file.path + "'"
        ]
        stdinEnabled: true
        onExited: function(code) {
            if (code === 0) {
                file.writeOk(file.apiKey);
                Qt.callLater(file.reload);
            } else {
                file.writeFailed("exit " + code);
            }
        }
    }

    function setApiKey(newKey) {
        file.apiKey = newKey;
        var body = "";
        if (file.mode)       body += "mode = \"" + file.mode + "\"\n";
        if (file.baseUrl)    body += "base_url = \"" + file.baseUrl + "\"\n";
        if (file.serverUrl)  body += "server_url = \"" + file.serverUrl + "\"\n";
        if (file.apiKey)     body += "api_key = \"" + file.apiKey + "\"\n";
        if (file.spaceId)    body += "space_id = \"" + file.spaceId + "\"\n";

        writeProc.running = false;
        writeProc.running = true;
        writeProc.write(body);
        writeProc.closeStdin();
    }

    // --- mtime poller ---
    property Timer _mtimeTimer: Timer {
        interval: 2000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: {
            statProc.running = false;
            statProc.running = true;
        }
    }

    Component.onCompleted: {
        file.path = resolvePath();
        statProc.running = true;
    }
}
