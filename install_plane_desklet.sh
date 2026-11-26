#!/usr/bin/env bash
# Installs the "Plane Count" Cinnamon desklet for the current user.
set -e

UUID="planecount@joe"
DIR="$HOME/.local/share/cinnamon/desklets/$UUID"
mkdir -p "$DIR"

cat > "$DIR/metadata.json" <<'EOF'
{
    "uuid": "planecount@joe",
    "name": "Plane Count",
    "description": "Aircraft tracked by your map.flights station, updated every 5 minutes",
    "max-instances": "1"
}
EOF

cat > "$DIR/desklet.js" <<'EOF'
const Desklet = imports.ui.desklet;
const St = imports.gi.St;
const Mainloop = imports.mainloop;
const Util = imports.misc.util;
const GLib = imports.gi.GLib;
const ByteArray = imports.byteArray;

const URL = "http://mapflights.local/api/live";
const POLL = 60;       // seconds between checks, to catch planes for the 24h total
const SHOW_EVERY = 5;  // update the display every 5th check (5 minutes)
const WINDOW = 86400;  // seconds (24 hours)
// Kept outside the desklet folder so reinstalling does not erase it
const DATA_DIR = GLib.build_filenamev([GLib.get_user_data_dir(), "planecount"]);
const HISTORY = GLib.build_filenamev([DATA_DIR, "history.json"]);
const GRAPH_W = 260;   // graph size in pixels
const GRAPH_H = 90;
const MAX_GAP = 450;   // seconds; longer breaks are left blank on the graph
const MAX_AGE = 60;    // count aircraft heard from within this many seconds

function PlaneDesklet(metadata, deskletId) {
    this._init(metadata, deskletId);
}

PlaneDesklet.prototype = {
    __proto__: Desklet.Desklet.prototype,

    _init: function(metadata, deskletId) {
        Desklet.Desklet.prototype._init.call(this, metadata, deskletId);
        this.setHeader("Plane Count");

        let box = new St.BoxLayout({
            vertical: true,
            style: "background-color: rgba(11,18,32,0.85); border-radius: 12px; padding: 14px 24px;"
        });
        let title = new St.Label({ text: "AIRCRAFT TRACKED",
            style: "color: #8a94a8; font-size: 10pt; text-align: center;" });
        this._count = new St.Label({ text: "--",
            style: "color: #facc15; font-size: 40pt; font-weight: bold; text-align: center;" });
        this._detail = new St.Label({ text: "Checking...",
            style: "color: #ffffff; font-size: 10pt; text-align: center;" });
        this._daily = new St.Label({ text: " ",
            style: "color: #38bdf8; font-size: 13pt; font-weight: bold; text-align: center; padding-top: 8px;" });
        this._scale = new St.Label({ text: "24h graph",
            style: "color: #8a94a8; font-size: 9pt; padding-top: 10px;" });
        this._graph = new St.DrawingArea({ width: GRAPH_W, height: GRAPH_H });
        this._graph.connect("repaint", area => this._draw(area));
        let axis = new St.Label({ text: "24h ago  -->  now (right edge)",
            style: "color: #8a94a8; font-size: 8pt; text-align: center;" });
        let legend = new St.BoxLayout({ style: "spacing: 14px;" });
        legend.add(new St.Label({ text: "\u25A0 tracked", style: "color: #facc15; font-size: 8pt;" }));
        legend.add(new St.Label({ text: "\u25A0 with position", style: "color: #38bdf8; font-size: 8pt;" }));
        this._time = new St.Label({ text: " ",
            style: "color: #8a94a8; font-size: 9pt; text-align: center;" });

        [title, this._count, this._detail, this._daily, this._scale, this._graph, axis, legend, this._time].forEach(l => box.add(l));
        this.setContent(box);

        this._removed = false;
        this._ticks = 0;
        this._load();
        this._update(true);
        this._timer = Mainloop.timeout_add_seconds(POLL, () => {
            this._ticks++;
            this._update(this._ticks % SHOW_EVERY === 0);
            return true;
        });
    },

    // planes: aircraft address -> time last heard. since: start of this history.
    _load: function() {
        this._planes = {};
        this._samples = [];  // [time, tracked, with position], one per display update
        this._since = null;
        this._last = null;
        try {
            let [ok, bytes] = GLib.file_get_contents(HISTORY);
            let saved = JSON.parse(ByteArray.toString(bytes));
            if (saved.planes) {
                this._planes = saved.planes;
                this._since = saved.since;
                this._last = saved.last;
                this._samples = saved.samples || [];
            }
        } catch (e) {
            // no history yet, or unreadable: start fresh
        }
    },

    _save: function() {
        try {
            GLib.mkdir_with_parents(DATA_DIR, 0o700);
            GLib.file_set_contents(HISTORY, JSON.stringify(
                { since: this._since, last: this._last, planes: this._planes,
                  samples: this._samples }));
        } catch (e) {
            global.logError("planecount: could not save history: " + e);
        }
    },

    _prune: function(now) {
        for (let hex in this._planes) {
            if (now - this._planes[hex] > WINDOW) delete this._planes[hex];
        }
    },

    _record: function(aircraft) {
        let now = Math.floor(Date.now() / 1000);
        // after a break of 24 hours or more, the history starts over
        if (!this._since || now - this._last > WINDOW) this._since = now;
        this._last = now;
        aircraft.forEach(a => {
            // "~" marks temporary addresses, which could count a plane twice
            if (!a.hex || a.hex.charAt(0) === "~") return;
            let heard = now - Math.floor(a.seen || 0);
            this._planes[a.hex] = Math.max(heard, this._planes[a.hex] || 0);
        });
        this._prune(now);
        this._save();
    },

    _update: function(refresh) {
        Util.spawn_async(["curl", "-fsS", "--connect-timeout", "10", "--max-time", "20", URL],
            output => {
                if (!this._removed) this._handle(output, refresh);
            });
    },

    _handle: function(output, refresh) {
        let planes = null;
        try {
            let data = JSON.parse(output);
            if (data.source && data.source.ok === false) throw new Error("receiver error");
            this._record(data.aircraft);
            planes = data.aircraft.filter(a => (a.seen || 0) <= MAX_AGE);
        } catch (e) {
            planes = null;
        }
        if (refresh) {
            if (planes) this._addSample(planes);
            this._show(planes);
        }
    },

    _addSample: function(planes) {
        let now = Math.floor(Date.now() / 1000);
        let positioned = planes.filter(a => a.lat != null && a.lon != null).length;
        this._samples.push([now, planes.length, positioned]);
        this._pruneSamples(now);
        this._save();
    },

    _pruneSamples: function(now) {
        this._samples = this._samples.filter(p => now - p[0] <= WINDOW);
    },

    _peak: function() {
        return this._samples.reduce((m, p) => Math.max(m, p[1]), 0);
    },

    _draw: function(area) {
        let cr = area.get_context();
        let [w, h] = area.get_surface_size();
        let now = Math.floor(Date.now() / 1000);
        let top = Math.max(this._peak(), 1);
        let x = t => 2 + (w - 4) * (1 - (now - t) / WINDOW);
        let y = n => h - 2 - (h - 4) * n / top;

        // grid: zero, half and peak lines, plus a mark every 6 hours
        cr.setLineWidth(1);
        cr.setSourceRGBA(1, 1, 1, 0.15);
        [0, top / 2, top].forEach(n => { cr.moveTo(0, y(n)); cr.lineTo(w, y(n)); });
        [0, 1, 2, 3, 4].forEach(i => { cr.moveTo(x(now - i * WINDOW / 4), 0); cr.lineTo(x(now - i * WINDOW / 4), h); });
        cr.stroke();

        cr.setLineWidth(2);
        cr.setLineCap(1);  // round, so a lone reading shows as a dot
        [[1, 0.98, 0.80, 0.08], [2, 0.22, 0.74, 0.97]].forEach(([col, r, g, b]) => {
            cr.setSourceRGBA(r, g, b, 1);
            let previous = null;
            this._samples.forEach(p => {
                if (previous === null || p[0] - previous > MAX_GAP) {
                    cr.moveTo(x(p[0]), y(p[col]));
                    cr.lineTo(x(p[0]) + 0.1, y(p[col]));
                } else {
                    cr.lineTo(x(p[0]), y(p[col]));
                }
                previous = p[0];
            });
            cr.stroke();
        });
        cr.$dispose();
    },

    _show: function(planes) {
        let time = new Date().toLocaleTimeString();
        if (planes) {
            let positioned = planes.filter(a => a.lat != null && a.lon != null).length;
            this._count.set_text(String(planes.length));
            this._detail.set_text(positioned + " with position");
            this._time.set_text("Updated " + time);
        } else {
            this._count.set_text("--");
            this._detail.set_text("No data from station");
            this._time.set_text("Tried " + time);
        }

        let now = Math.floor(Date.now() / 1000);
        this._prune(now);
        let total = Object.keys(this._planes).length;
        let text = "Last 24h: " + total + " unique";
        if (!this._since) {
            text = "Last 24h: --";
        } else if (now - this._since < WINDOW) {
            let hours = Math.floor((now - this._since) / 3600);
            text += "\n(building: " + hours + " of 24 h)";
        }
        this._daily.set_text(text);

        this._pruneSamples(now);
        this._scale.set_text("24h graph (scale 0 to " + Math.max(this._peak(), 1) + ")");
        this._graph.queue_repaint();
    },

    on_desklet_removed: function() {
        this._removed = true;
        if (this._timer) {
            Mainloop.source_remove(this._timer);
            this._timer = null;
        }
    }
};

function main(metadata, deskletId) {
    return new PlaneDesklet(metadata, deskletId);
}
EOF

echo "Installed to $DIR"
echo "Next: right-click the desktop > Add Desklets > Plane Count > add it."
