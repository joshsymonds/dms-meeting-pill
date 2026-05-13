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
import QtCore
import QtQuick
import Quickshell.Io
import qs.Common
import qs.Modules.Plugins
import qs.Widgets

PluginComponent {
    id: root
    pluginId: "meetingPill"

    // ── Settings ───────────────────────────────────────────────────────
    // No truncation — when the title doesn't fit in the pill width it
    // scrolls (marquee). Static truncation to "Stand…" / "Perm…" was
    // unhelpful for distinguishing meetings and visually strained the
    // 36px pill width.

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
        // text() is a function on FileView (not a property); calling it
        // triggers a synchronous read under blockLoading:true and
        // returns the file contents.
        const raw = eventsFile.text();
        if (!raw) {
            _clear();
            return;
        }
        let arr;
        try {
            arr = JSON.parse(raw);
        } catch (e) {
            // Malformed JSON — most likely we caught a write mid-rename
            // (shouldn't happen with the .tmp pattern morgen-fetch uses
            // but cheap to guard). Hold current state until next reload.
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
    // The working FileView contract (verified against Quickshell.Io's
    // qmltypes and DMS's own SettingsData.qml):
    //
    //   • `text()` is a SYNCHRONOUS method, not a property. With
    //     `blockLoading: true` it triggers an immediate blocking read,
    //     returns the file contents as a string. Don't wait for an
    //     `onLoaded` signal — call text() directly when you need data.
    //   • `onFileChanged` fires when the watched file mutates on disk.
    //     Re-call text() from there to refresh.
    //   • A debounce timer coalesces morgen-fetch's atomic-rename event
    //     burst (multiple inotify events per rename) into one refresh.
    //
    // DMS's SettingsData.qml drives reads from Component.onCompleted +
    // onFileChanged; the `loaded` signal exists but the synchronous
    // text() flow is what they actually rely on. We do the same.
    Timer {
        id: reloadDebounce
        interval: 50
        repeat: false
        onTriggered: root._refreshFromFile()
    }

    FileView {
        id: eventsFile
        path: StandardPaths.writableLocation(StandardPaths.GenericDataLocation) + "/morgen-fetch/upcoming-events.json"
        blockLoading: true
        watchChanges: true
        printErrors: false
        onFileChanged: reloadDebounce.restart()
    }

    Component.onCompleted: root._refreshFromFile()

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
    // 3-row: icon + scrolling title marquee + countdown. Title row is a
    // clipped Item containing a StyledText that scrolls horizontally
    // when its natural width exceeds the pill width. Same animation
    // shape as DMS's Media widget (Modules/DankBar/Widgets/Media.qml):
    // pause → scroll → pause → reset → loop. Static truncation in 36px
    // was unreadable; marquee lets the full title come through over
    // time at the cost of needing to wait a few seconds.
    verticalBarPill: Component {
        Column {
            spacing: 2

            DankIcon {
                name: "event_upcoming"
                size: Theme.iconSizeSmall
                color: root.urgencyIconColor
                anchors.horizontalCenter: parent.horizontalCenter
            }

            Item {
                // Marquee clip rectangle. Continuous scroll using the
                // two-copy trick: render the title twice (separated by
                // `gap`) inside a Row, animate the Row's x from 0 to
                // -(titleWidth + gap), loop infinitely. When the
                // animation wraps the second copy is positioned
                // exactly where the first was at x=0, so the wrap is
                // visually seamless — no snap, no pause, no reset
                // flash. The second copy is `visible: needsScrolling`
                // so a fitting title just renders once, centered.
                id: titleClip
                visible: root.haveData
                // DEBUG: massively oversize the clip Item to see what's
                // actually constraining the visible marquee window. If
                // the visible scroll area expands when width=200, then
                // root.widgetThickness is small. If it stays narrow,
                // something else (Column? Loader? BasePill?) is the
                // limiting parent.
                width: 200
                height: titleText.implicitHeight
                clip: true
                anchors.horizontalCenter: parent.horizontalCenter

                Rectangle {
                    anchors.fill: parent
                    color: "magenta"
                    opacity: 0.25
                    z: -1
                }

                readonly property real titleWidth: titleText.implicitWidth
                readonly property real gap: 24   // px between text repeats
                readonly property bool needsScrolling: titleWidth > width
                property real scrollX: 0

                Row {
                    spacing: titleClip.gap
                    anchors.verticalCenter: parent.verticalCenter
                    x: titleClip.needsScrolling
                       ? -titleClip.scrollX
                       : (titleClip.width - titleClip.titleWidth) / 2

                    StyledText {
                        id: titleText
                        text: root.nextTitle
                        font.pixelSize: Theme.fontSizeSmall
                        color: root.urgencyColor
                        // StyledText defaults to elide: ElideRight and
                        // wrapMode: WordWrap. Both must be overridden
                        // or the text gets shortened ("Perm…") before
                        // the marquee can even consider scrolling.
                        elide: Text.ElideNone
                        wrapMode: Text.NoWrap
                    }

                    StyledText {
                        // Second copy — invisible (and so contributes
                        // nothing to the Row's natural width) when the
                        // first copy already fits the clip.
                        visible: titleClip.needsScrolling
                        text: root.nextTitle
                        font.pixelSize: Theme.fontSizeSmall
                        color: root.urgencyColor
                        elide: Text.ElideNone
                        wrapMode: Text.NoWrap
                    }
                }

                NumberAnimation on scrollX {
                    running: titleClip.needsScrolling
                    loops: Animation.Infinite
                    from: 0
                    to: titleClip.titleWidth + titleClip.gap
                    // 80 ms per pixel — readable pace; previous 60 ms
                    // felt jittery. Min 800ms so a barely-overflowing
                    // title doesn't whip past.
                    duration: Math.max(800, (titleClip.titleWidth + titleClip.gap) * 80)
                    easing.type: Easing.Linear
                }
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
