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
    // `events` is the full set of future-only events parsed from the JSON,
    // in chronological order. `currentIdx` is the cursor into it; −1 means
    // "no current event" (idle). All displayed scalars (nextTitle, nextStart,
    // nextUrl, haveData) are readonly derivations so the array is the single
    // source of truth — earlier iterations cached the head in writable
    // scalars and only refreshed them on file change, which silently failed
    // when the fetcher stalled and the displayed event's start slipped into
    // the past (pill showed "now" for hours instead of advancing).
    property var events: []
    property int currentIdx: -1
    readonly property var currentEvent:
        currentIdx >= 0 && currentIdx < events.length ? events[currentIdx] : null
    readonly property bool haveData: currentEvent !== null
    readonly property var nextStart: currentEvent ? new Date(Date.parse(currentEvent.start)) : null
    readonly property string nextTitle: currentEvent ? (currentEvent.title || "(no title)") : ""
    readonly property string nextUrl: currentEvent ? (currentEvent.url || "") : ""

    // countdownNow ticks every second so the displayed minutes/hours
    // tick down naturally even when the underlying JSON hasn't changed.
    property real countdownNow: Date.now()

    // ── Urgency level ──────────────────────────────────────────────────
    // Single source of truth for "how worried should the user be right
    // now". Both the icon color and the text color derive from this
    // level via tiny lookup expressions below, so the two can never
    // drift in their threshold semantics — earlier iterations had
    // independent if-chains for color vs. iconColor that happened to
    // produce identical visual results today but invited a bug the next
    // time someone tweaked one branch without the other.
    //
    // Returns "normal" | "warning" | "error".
    readonly property string urgencyLevel: {
        if (!root.haveData || !root.nextStart)
            return "normal";
        const minutesUntil = (root.nextStart.getTime() - root.countdownNow) / 60000;
        if (minutesUntil < 5)
            return "error";           // <5 min OR currently happening
        if (minutesUntil < 15)
            return "warning";         // <15 min — start wrapping up
        return "normal";
    }

    readonly property color urgencyColor:
        urgencyLevel === "error"   ? Theme.error
      : urgencyLevel === "warning" ? Theme.warning
      :                              Theme.widgetTextColor

    readonly property color urgencyIconColor:
        urgencyLevel === "error"   ? Theme.error
      : urgencyLevel === "warning" ? Theme.warning
      :                              Theme.widgetIconColor

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
        if (!Array.isArray(arr)) {
            _clear();
            return;
        }
        // morgen-fetch already filters to future events and sorts by
        // start, but we re-filter here defensively: the JSON can be a
        // few minutes stale, and _advanceIfExpired walks this array
        // every second expecting future-only contents. Pruning past
        // entries at parse time keeps that loop short.
        const nowMs = Date.now();
        const future = [];
        for (const ev of arr) {
            const startMs = Date.parse(ev.start);
            if (isNaN(startMs))
                continue;
            if (startMs <= nowMs)
                continue;
            future.push(ev);
        }
        root.events = future;
        root.currentIdx = future.length > 0 ? 0 : -1;
    }

    function _advanceIfExpired() {
        // Called every second by the countdown ticker. If the currently
        // displayed event's start has slipped into the past (fetcher
        // hasn't rewritten the JSON yet, or a meeting just started while
        // the pill was showing it), walk forward to the next entry whose
        // start is still in the future. Exhausting the array drops us
        // back to idle ("--") — fresher than lying about a past event.
        if (root.currentIdx < 0)
            return;
        const nowMs = Date.now();
        let i = root.currentIdx;
        while (i < root.events.length) {
            const startMs = Date.parse(root.events[i].start);
            if (!isNaN(startMs) && startMs > nowMs)
                break;
            i++;
        }
        if (i !== root.currentIdx)
            root.currentIdx = (i < root.events.length) ? i : -1;
    }

    function _clear() {
        root.events = [];
        root.currentIdx = -1;
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
        // through root.countdownNow. Also calls _advanceIfExpired so the
        // currently-displayed event rolls over to the next future entry
        // the moment its start crosses now — without waiting for the
        // FileView to deliver a new snapshot. With a healthy fetcher the
        // two converge within minutes; with a stalled fetcher this is
        // what keeps the pill honest.
        //
        // Gated on `haveData` so the ticker stops between meetings.
        // When _advanceIfExpired exhausts the array it sets
        // currentIdx=-1, which flips haveData false and stops this
        // Timer — saving wakeups until the next FileView reload
        // restores a future event.
        interval: 1000
        repeat: true
        running: root.haveData
        onTriggered: {
            root._advanceIfExpired();
            root.countdownNow = Date.now();
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
        // HTTPS allowlist: morgen-fetch sources the URL from a calendar
        // event's `virtualRoom.url` field, which is attacker-controllable
        // by anyone who can put an event on the user's calendar. xdg-open
        // would dispatch `javascript:`, `data:text/html,...`, `file:///`,
        // or even flag-style strings like `--version` to the user's
        // browser — most of those are exploitable surfaces. Real meeting
        // join links are always `https://` (Zoom/Meet/Teams); rejecting
        // anything else costs nothing.
        if (!/^https?:\/\//i.test(root.nextUrl))
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
                // two-copy trick: render `title + " • "` twice
                // butt-jointed inside a Row, animate Row.x from 0 to
                // -(title + bullet) width, loop infinitely. The bullet
                // baked into each copy serves as the visible separator
                // between marquee repeats — earlier iterations tried an
                // empty Row spacing for separation, but at a 32 px clip
                // width even a small empty gap reads as "huge padding"
                // with maybe one stray letter on the edge. With a bullet
                // in the text stream, the clip is always showing
                // glyphs — title characters most of the cycle, " • "
                // briefly as the loop seam passes. Two identical copies
                // mean the wrap at -bulletEndWidth back to 0 is
                // visually unchanged (both copies are the same text);
                // no snap, no flash.
                //
                // needsScrolling is decided against the PLAIN title
                // width (titleSizer below), independent of titleText's
                // actual rendered text. This avoids a circular binding
                // (titleText.text depends on needsScrolling, which
                // would otherwise depend on titleText.implicitWidth).
                id: titleClip
                visible: root.haveData
                width: root.widgetThickness - 4
                height: titleText.implicitHeight
                clip: true
                anchors.horizontalCenter: parent.horizontalCenter

                readonly property bool needsScrolling: titleSizer.implicitWidth > width
                // titleText.implicitWidth includes the trailing bullet
                // when scrolling, so loopDistance == title + bullet width.
                readonly property real loopDistance: titleText.implicitWidth
                property real scrollX: 0

                // Hidden sizer for the plain title, used purely to
                // decide whether the title fits. Kept out of the
                // visible Row so it doesn't affect layout.
                StyledText {
                    id: titleSizer
                    visible: false
                    text: root.nextTitle
                    font.pixelSize: Theme.fontSizeSmall
                }

                Row {
                    spacing: 0
                    anchors.verticalCenter: parent.verticalCenter
                    x: titleClip.needsScrolling
                       ? -titleClip.scrollX
                       : (titleClip.width - titleText.implicitWidth) / 2

                    StyledText {
                        id: titleText
                        // Trailing bullet only when we're going to
                        // marquee — for short titles that fit, render
                        // the title plain so the static display isn't
                        // visually cluttered by a dangling separator.
                        text: titleClip.needsScrolling
                              ? (root.nextTitle + "  •  ")
                              : root.nextTitle
                        font.pixelSize: Theme.fontSizeSmall
                        color: root.urgencyColor
                        elide: Text.ElideNone
                        wrapMode: Text.NoWrap
                    }

                    StyledText {
                        visible: titleClip.needsScrolling
                        text: root.nextTitle + "  •  "
                        font.pixelSize: Theme.fontSizeSmall
                        color: root.urgencyColor
                        elide: Text.ElideNone
                        wrapMode: Text.NoWrap
                    }
                }

                // 30 Hz Timer-driven marquee. The previous NumberAnimation
                // was driven by Qt's animation framework at vsync (120 Hz
                // on this display), which forced two QSGRender threads to
                // ~10% CPU continuously for an animation showing 3 px of
                // motion per frame. Throttling to ~30 Hz cuts the repaint
                // cadence to ~25% without changing the perceived scroll
                // speed: 33 ms × (1 px / 80 ms) = 0.4125 px/tick, matching
                // the original Easing.Linear 12.5 px/sec pace.
                //
                // Visibility gating preserved from the original — when the
                // pill is hidden (workspace switch, collapsed bar) the
                // Timer stops cold instead of ticking invisible work.
                Timer {
                    id: marqueeTimer
                    interval: 33
                    repeat: true
                    running: titleClip.needsScrolling && titleClip.visible
                    onTriggered: {
                        const next = titleClip.scrollX + 0.4125
                        titleClip.scrollX = next >= titleClip.loopDistance
                                          ? next - titleClip.loopDistance
                                          : next
                    }
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
                // Idle state matches the vertical pill: just "--" with
                // neutral color (urgencyColor falls back to
                // widgetTextColor when !haveData). The earlier wording
                // "no upcoming" diverged from the Epic spec's "render
                // '--' countdown" for idle and left the two layouts
                // inconsistent.
                text: root.haveData
                      ? (root._formatCountdown(root.nextStart) + ": " + root.nextTitle)
                      : "--"
                font.pixelSize: Theme.barTextSize(root.barThickness, root.barConfig ? root.barConfig.fontScale : 1.0, root.barConfig ? root.barConfig.maximizeWidgetText : false)
                color: root.urgencyColor
                anchors.verticalCenter: parent.verticalCenter
            }
        }
    }
}
