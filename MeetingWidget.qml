// dms-meeting-pill: countdown to the next upcoming calendar event.
//
// Data source: `khal list --json ... now 48h`. khal reads any vdir-format
// directory of ICS files, so this pill works with vdirsyncer-, morgen-
// fetch-, or any other source that drops ICS into khal's configured
// path. We don't talk to the calendar provider directly — let khal own
// that abstraction.
//
// Rendering: small identity icon (`event_upcoming` — calendar with an
// arrow into it, literally "an upcoming event") over a compact countdown
// string. Two rows, matches the CpuMonitor/RamMonitor profile so the
// pill fits the bar's vertical budget alongside the other monitors.
//
// Click → opens a popout with the next few events (TODO; v1 ships with
// pill-only).
import QtQuick
import Quickshell.Io
import qs.Common
import qs.Modules.Plugins
import qs.Widgets

PluginComponent {
    id: root
    pluginId: "meetingPill"

    // ── Settings ───────────────────────────────────────────────────────
    // 60 s khal poll — meetings don't change minute-to-minute but the
    // countdown updates by-minute, so a 60 s cadence keeps the displayed
    // value within one tick of correct. Override via pluginData.
    property int intervalMs: (pluginData && pluginData.intervalMs) ? pluginData.intervalMs : 60000

    // How far ahead to scan for the next event. 48h covers "tomorrow
    // afternoon" reliably; events further out generally aren't actionable
    // glance-data anyway.
    property string lookahead: (pluginData && pluginData.lookahead) ? pluginData.lookahead : "48h"

    // ── Live state ─────────────────────────────────────────────────────
    property string nextTitle: ""
    property var nextStart: null    // JS Date or null
    property bool haveData: false

    // Recompute the displayed countdown every minute even when we
    // haven't re-fetched. This way the pill ticks down naturally between
    // khal polls.
    property real countdownNow: Date.now()

    // ── Helpers ────────────────────────────────────────────────────────
    function _formatCountdown(start) {
        if (!start)
            return "--";
        const ms = start.getTime() - root.countdownNow;
        if (ms <= 0)
            return "now";
        const totalSec = Math.floor(ms / 1000);
        const totalMin = Math.floor(totalSec / 60);
        if (totalMin < 1)
            return "<1m";
        if (totalMin < 60)
            return totalMin + "m";
        const totalHr = Math.floor(totalMin / 60);
        if (totalHr < 24)
            return totalHr + "h";
        const totalDay = Math.floor(totalHr / 24);
        return totalDay + "d";
    }

    // khal emits one JSON array PER DAY, separated by newlines. So the
    // output for a 48h window can be:
    //   [{event1}, {event2}]\n[{event3}]\n
    // We parse each line as its own array and flatten. Empty start-time
    // marks an all-day event — skip those (they're status markers like
    // "PTO" or holidays, not "meetings" you need a countdown for).
    function _findNextEvent(stdout) {
        const lines = String(stdout).split("\n").filter(l => l.trim());
        let best = null;
        let bestMs = Infinity;
        const nowMs = Date.now();
        for (const line of lines) {
            let arr;
            try {
                arr = JSON.parse(line);
            } catch (e) {
                continue;
            }
            if (!Array.isArray(arr))
                continue;
            for (const ev of arr) {
                if (!ev["start-time"])
                    continue;
                // Construct an ISO-ish local datetime; JS Date parses
                // "YYYY-MM-DDTHH:MM" as local time which matches khal's
                // output semantics (khal prints in the user's configured
                // timezone). UTC offsets aren't included by khal's
                // start-date/start-time fields.
                const d = new Date(ev["start-date"] + "T" + ev["start-time"]);
                if (isNaN(d.getTime()))
                    continue;
                const dt = d.getTime() - nowMs;
                if (dt <= 0)
                    continue;
                if (dt < bestMs) {
                    bestMs = dt;
                    best = {
                        title: ev["title"] || "(no title)",
                        start: d
                    };
                }
            }
        }
        return best;
    }

    // ── Poll ──────────────────────────────────────────────────────────
    Process {
        id: khalProc
        command: [
            "khal", "list",
            "--json", "title",
            "--json", "start-date",
            "--json", "start-time",
            "--notstarted",
            "now",
            root.lookahead
        ]
        stdout: StdioCollector {
            id: collector
            onStreamFinished: {
                let raw = collector.text;
                if (typeof raw === "function")
                    raw = raw();
                const next = root._findNextEvent(raw);
                if (next) {
                    root.nextTitle = next.title;
                    root.nextStart = next.start;
                    root.haveData = true;
                } else {
                    root.nextTitle = "";
                    root.nextStart = null;
                    root.haveData = false;
                }
            }
        }
    }

    Timer {
        // Poll khal every intervalMs (default 60s). Triggers on start so
        // the pill populates immediately instead of waiting a full
        // interval after shell startup.
        interval: root.intervalMs
        repeat: true
        running: true
        triggeredOnStart: true
        onTriggered: khalProc.running = true
    }

    Timer {
        // Tick countdownNow once per second so the displayed minute
        // ticks down naturally between khal re-fetches. Could be every
        // 60s but 1s keeps the rounding aligned with the wall clock.
        interval: 1000
        repeat: true
        running: true
        onTriggered: root.countdownNow = Date.now()
    }

    // ── Vertical bar pill ──────────────────────────────────────────────
    // 2-row pill (icon + countdown) — matches CpuMonitor/RamMonitor/
    // gpuPill height profile. No title in the pill itself; the
    // countdown is the at-a-glance actionable value, and a future popout
    // can expose the meeting title and full agenda.
    verticalBarPill: Component {
        Column {
            spacing: 2

            DankIcon {
                name: "event_upcoming"
                size: Theme.iconSizeSmall
                color: Theme.widgetIconColor
                anchors.horizontalCenter: parent.horizontalCenter
            }

            StyledText {
                text: root._formatCountdown(root.nextStart)
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.widgetTextColor
                anchors.horizontalCenter: parent.horizontalCenter
            }
        }
    }

    // ── Horizontal bar pill ────────────────────────────────────────────
    // On a horizontal bar we have width for the title alongside the
    // countdown.
    horizontalBarPill: Component {
        Row {
            spacing: Theme.spacingS

            DankIcon {
                name: "event_upcoming"
                size: Theme.barIconSize(root.barThickness, undefined, root.barConfig ? root.barConfig.maximizeWidgetIcons : false, root.barConfig ? root.barConfig.iconScale : 1.0)
                color: Theme.widgetIconColor
                anchors.verticalCenter: parent.verticalCenter
            }

            StyledText {
                text: root.haveData
                      ? (root._formatCountdown(root.nextStart) + ": " + root.nextTitle)
                      : "no upcoming"
                font.pixelSize: Theme.barTextSize(root.barThickness, root.barConfig ? root.barConfig.fontScale : 1.0, root.barConfig ? root.barConfig.maximizeWidgetText : false)
                color: Theme.widgetTextColor
                anchors.verticalCenter: parent.verticalCenter
            }
        }
    }
}
