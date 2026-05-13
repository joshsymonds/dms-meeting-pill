// dms-meeting-pill: countdown to the next upcoming calendar event, with
// optional one-click join when the event has a virtual-room URL.
//
// Data source: ~/.local/share/morgen-fetch/upcoming-events.json (produced
// by morgen-fetch). The JSON is sorted by start ascending, future-only,
// with each entry carrying {uid, title, start, end, url}. We read it via
// FileView with watchChanges so the pill updates the instant morgen-fetch
// writes a new snapshot — no polling here, just a 1s ticker to make the
// displayed countdown tick down between file rewrites.
//
// Rendering: 3-row vertical pill — identity icon, truncated title,
// countdown. Color state escalates as the next event approaches:
//   • >15min:   widgetText/widgetIcon (normal)
//   • 5–15min:  Theme.warning (yellow)
//   • <5min OR
//     happening: Theme.error   (red)
//
// Click: if the next event has a URL, xdg-open it. If not, no-op. The
// click handler is wired through PluginComponent.pillClickAction so
// BasePill's existing MouseArea drives it — no custom MouseArea needed.
import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Modules.Plugins
import qs.Widgets

PluginComponent {
    id: root
    pluginId: "meetingPill"

    // ── Settings ───────────────────────────────────────────────────────
    // Title truncation budget. 5 chars + "…" = 6 chars fits inside the
    // 36px pill width at Theme.fontSizeSmall (12px ≈ 6px per char in
    // Material Sans). Override via pluginData.maxTitleChars if you have
    // a wider bar or want a different visual balance.
    property int maxTitleChars: (pluginData && pluginData.maxTitleChars) ? pluginData.maxTitleChars : 5

    // ── Live state ─────────────────────────────────────────────────────
    property string nextTitle: ""
    property var nextStart: null     // JS Date or null
    property string nextUrl: ""      // empty string when no URL (QML's null vs string mix is awkward)
    property bool haveData: false

    // countdownNow ticks every second so the displayed minutes/hours
    // tick down naturally even when the underlying JSON hasn't changed.
    property real countdownNow: Date.now()

    // ── Urgency color (drives icon + text tint) ────────────────────────
    // Single source of truth for "how worried should the user be right
    // now"; wired to every visual element so the whole pill flashes
    // through warning → error as the meeting approaches.
    readonly property color urgencyColor: {
        if (!root.haveData || !root.nextStart)
            return Theme.widgetTextColor;
        const minutesUntil = (root.nextStart.getTime() - root.countdownNow) / 60000;
        if (minutesUntil <= 0)
            return Theme.error;       // currently happening
        if (minutesUntil < 5)
            return Theme.error;       // <5 min — drop everything
        if (minutesUntil < 15)
            return Theme.warning;     // <15 min — start wrapping up
        return Theme.widgetTextColor;
    }

    readonly property color urgencyIconColor: {
        // Same logic, but fall back to widgetIconColor (which often
        // differs slightly from widgetTextColor) when not urgent.
        if (!root.haveData || !root.nextStart)
            return Theme.widgetIconColor;
        const minutesUntil = (root.nextStart.getTime() - root.countdownNow) / 60000;
        if (minutesUntil < 5)
            return Theme.error;
        if (minutesUntil < 15)
            return Theme.warning;
        return Theme.widgetIconColor;
    }

    // ── Helpers ────────────────────────────────────────────────────────
    function _truncate(s, maxChars) {
        if (!s)
            return "";
        if (s.length <= maxChars)
            return s;
        // slice operates on UTF-16 code units — fine for English titles;
        // CJK/emoji titles may truncate at a visually awkward column,
        // but the alternative (grapheme-cluster iteration) is overkill
        // for a 5-char budget.
        return s.slice(0, maxChars - 1) + "…";
    }

    function _formatCountdown(start) {
        if (!start)
            return "--";
        const ms = start.getTime() - root.countdownNow;
        if (ms <= 0)
            return "now";
        const totalMin = Math.floor(ms / 60000);
        if (totalMin < 1)
            return "<1m";
        if (totalMin < 60)
            return totalMin + "m";
        const totalHr = Math.floor(totalMin / 60);
        if (totalHr < 24)
            return totalHr + "h";
        return Math.floor(totalHr / 24) + "d";
    }

    function _refreshFromFile() {
        let raw = eventsFile.text;
        console.log("meetingPill: typeof eventsFile.text =", typeof raw);
        if (typeof raw === "function")
            raw = raw();
        console.log("meetingPill: raw length =", raw ? raw.length : "<null>");
        console.log("meetingPill: path =", root._eventsPath);
        if (!raw) {
            _clear();
            return;
        }
        let arr;
        try {
            arr = JSON.parse(raw);
            console.log("meetingPill: parsed", arr.length, "events");
        } catch (e) {
            // Malformed JSON — most likely we caught a write mid-rename
            // (shouldn't happen with the .tmp pattern morgen-fetch uses
            // but cheap to guard). Hold current state until next reload.
            console.log("meetingPill: JSON.parse failed:", e);
            return;
        }
        if (!Array.isArray(arr) || arr.length === 0) {
            _clear();
            return;
        }
        // morgen-fetch already filters to future events and sorts by
        // start, so the first array entry is canonically "next". We
        // double-check the start is still in the future (the JSON could
        // be a few minutes stale).
        const nowMs = Date.now();
        for (const ev of arr) {
            const startMs = Date.parse(ev.start);
            if (isNaN(startMs))
                continue;
            if (startMs <= nowMs)
                continue;
            root.nextTitle = ev.title || "(no title)";
            root.nextStart = new Date(startMs);
            root.nextUrl = ev.url || "";
            root.haveData = true;
            return;
        }
        _clear();
    }

    function _clear() {
        root.nextTitle = "";
        root.nextStart = null;
        root.nextUrl = "";
        root.haveData = false;
    }

    // ── File watcher ──────────────────────────────────────────────────
    // Path is interpolated from Quickshell.env("HOME") at QML eval —
    // setting it imperatively after construction also caused
    // "Cannot read property 'preload' of null" in FileView's internal
    // onPathChanged, so we just commit to the eval-time string. If
    // Quickshell.env returns falsy for any reason we fall back to a
    // sane default. `watchChanges: true` handles reloads; no manual
    // onFileChanged handler (no such signal on this Quickshell version).
    readonly property string _eventsPath: (Quickshell.env("HOME") || "") + "/.local/share/morgen-fetch/upcoming-events.json"

    FileView {
        id: eventsFile
        path: root._eventsPath
        watchChanges: true
        blockLoading: false
        onLoaded: {
            console.log("meetingPill: FileView onLoaded fired");
            root._refreshFromFile();
        }
        onLoadFailed: function(error) {
            console.log("meetingPill: FileView load failed:", error);
        }
    }

    Component.onCompleted: {
        console.log("meetingPill: COMPONENT LOADED, path =", root._eventsPath);
    }

    Timer {
        // 1 s countdown ticker. Used by urgencyColor and _formatCountdown
        // through root.countdownNow. The FileView handles new-data
        // updates separately on file change.
        interval: 1000
        repeat: true
        running: true
        onTriggered: {
            root.countdownNow = Date.now();
            // The next event's `start` doesn't change between FileView
            // reloads but `_formatCountdown` reads `countdownNow`; the
            // urgencyColor binding will re-evaluate automatically since
            // it depends on countdownNow. Nothing else to do here.
        }
    }

    // ── Click handler ──────────────────────────────────────────────────
    // BasePill (which wraps our content) emits a clicked signal that
    // PluginComponent forwards to pillClickAction if it's set. Using
    // this hook means we don't need our own MouseArea — clean.
    Process {
        id: launcher
        // Reset to "" so QML doesn't try to launch on initial binding.
        // Each click sets command + flips running=true.
        command: []
    }

    pillClickAction: () => {
        if (!root.nextUrl)
            return;
        launcher.command = ["xdg-open", root.nextUrl];
        launcher.running = true;
    }

    // ── Vertical bar pill ──────────────────────────────────────────────
    // 3-row: icon + truncated title + countdown. The Column is the
    // BasePill's content directly (no Item wrapper, no double-wrap) —
    // same pattern as the bandwidth/gpu pills.
    verticalBarPill: Component {
        Column {
            spacing: 2

            DankIcon {
                name: "event_upcoming"
                size: Theme.iconSizeSmall
                color: root.urgencyIconColor
                anchors.horizontalCenter: parent.horizontalCenter
            }

            StyledText {
                // Only render the title row when we actually have data —
                // otherwise the empty StyledText still occupies a row
                // of vertical space and makes the idle pill look broken.
                visible: root.haveData
                text: root._truncate(root.nextTitle, root.maxTitleChars)
                font.pixelSize: Theme.fontSizeSmall
                color: root.urgencyColor
                anchors.horizontalCenter: parent.horizontalCenter
            }

            StyledText {
                text: root._formatCountdown(root.nextStart)
                font.pixelSize: Theme.fontSizeSmall
                color: root.urgencyColor
                anchors.horizontalCenter: parent.horizontalCenter
            }
        }
    }

    // ── Horizontal bar pill ────────────────────────────────────────────
    // Width to spare here, so we keep the full title alongside the
    // countdown: "12m: Standup".
    horizontalBarPill: Component {
        Row {
            spacing: Theme.spacingS

            DankIcon {
                name: "event_upcoming"
                size: Theme.barIconSize(root.barThickness, undefined, root.barConfig ? root.barConfig.maximizeWidgetIcons : false, root.barConfig ? root.barConfig.iconScale : 1.0)
                color: root.urgencyIconColor
                anchors.verticalCenter: parent.verticalCenter
            }

            StyledText {
                text: root.haveData
                      ? (root._formatCountdown(root.nextStart) + ": " + root.nextTitle)
                      : "no upcoming"
                font.pixelSize: Theme.barTextSize(root.barThickness, root.barConfig ? root.barConfig.fontScale : 1.0, root.barConfig ? root.barConfig.maximizeWidgetText : false)
                color: root.urgencyColor
                anchors.verticalCenter: parent.verticalCenter
            }
        }
    }
}
