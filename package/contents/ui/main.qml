import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.components as PlasmaComponents
import org.kde.plasma.extras as PlasmaExtras
import org.kde.plasma.plasma5support as P5Support
import org.kde.kirigami as Kirigami

PlasmoidItem {
    id: root

    property var usage: null
    property string errorText: ""
    readonly property var cfg: Plasmoid.configuration
    readonly property string collector: Qt.resolvedUrl("../code/collect.py").toString().replace(/^file:\/\//, "")
    // Each remote is "host:/path"; anything outside a conservative charset is dropped
    // because it ends up on a shell command line.
    readonly property var remotes: (cfg.remotes || "").split(/[\s,]+/)
        .filter(r => /^[A-Za-z0-9._@-]+:[A-Za-z0-9._~\/-]*$/.test(r))
    function command(force) {
        return "python3 -I '" + collector + "' --top " + (cfg.topItems >= 0 ? Math.floor(cfg.topItems) : 5)
            + remotes.map(r => " --remote '" + r + "'").join("")
            + (force ? " --force" : "")
    }
    // No active block and nothing wrong: optionally hide the label (and park the icon in
    // the system tray's hidden section, when it lives there).
    readonly property bool idle: !!(usage && usage.ok && !usage.block) && !errorText && errorHosts.length === 0
    readonly property bool hideLabel: cfg.hideWhenIdle && idle
    Plasmoid.status: hideLabel && !expanded ? PlasmaCore.Types.PassiveStatus : PlasmaCore.Types.ActiveStatus
    // Offline hosts (asleep, away) are expected and only get a quiet label; real errors
    // (key rejected, python3 missing, ...) get a one-line banner and the warning icon.
    readonly property var errorHosts: usage && usage.hosts ? usage.hosts.filter(h => !h.ok && !h.offline) : []
    readonly property var offlineHosts: usage && usage.hosts ? usage.hosts.filter(h => !h.ok && h.offline) : []

    function shortError(e) {
        if (/permission denied/i.test(e)) return i18n("SSH key rejected")
        if (/host key verification failed|remote host identification has changed/i.test(e)) return i18n("SSH host key changed")
        if (/python3.*not found|no such file.*python3/i.test(e)) return i18n("python3 not found on host")
        const line = (e || "").split("\n")[0]
        return line.length > 60 ? line.slice(0, 57) + "…" : line
    }
    function hostNote(name) {
        for (const h of (usage && usage.hosts) || []) {
            if (h.name !== name || h.ok) continue
            const when = h.stale ? " · " + fmtTime(h.fetched) : ""
            return (h.offline ? i18n("offline") : i18n("error")) + when
        }
        return ""
    }
    // Every configured host, including ones with no tokens this week or no cached data.
    readonly property var hostRows: {
        if (!usage || !usage.ok || !usage.hosts || usage.hosts.length < 2) return []
        const rows = usage.week.hosts.map(h => Object.assign({}, h, { note: hostNote(h.name) }))
        for (const h of usage.hosts)
            if (!rows.some(r => r.name === h.name))
                rows.push({ name: h.name, tokens: 0, cost: 0, note: hostNote(h.name) })
        return rows
    }

    readonly property var panelBucket: {
        if (!usage || !usage.ok) return null
        if (cfg.panelPeriod === 0) return usage.block
        if (cfg.panelPeriod === 2) return usage.week
        return usage.today
    }

    function fmtTokens(n) {
        if (n === undefined || n === null) return "–"
        if (n >= 1e9) return (n / 1e9).toFixed(n >= 1e10 ? 0 : 1) + "B"
        if (n >= 1e6) return (n / 1e6).toFixed(n >= 1e7 ? 0 : 1) + "M"
        if (n >= 1e3) return (n / 1e3).toFixed(n >= 1e4 ? 0 : 1) + "K"
        return String(n)
    }
    function fmtCost(c) {
        if (c === undefined || c === null) return "–"
        return "$" + (c >= 100 ? c.toFixed(0) : c.toFixed(2))
    }
    function fmtMinutes(m) {
        if (m === undefined || m === null) return ""
        return m >= 60 ? Math.floor(m / 60) + "h" + String(m % 60).padStart(2, "0") : m + "m"
    }
    function fmtTime(iso) {
        return iso ? new Date(iso).toLocaleTimeString(Qt.locale(), Locale.ShortFormat) : ""
    }
    // force: also retry remote hosts that were offline a moment ago (manual refreshes).
    function refresh(force) {
        const cmd = command(!!force)
        executable.disconnectSource(cmd)
        executable.connectSource(cmd)
    }
    function blockLine(b) {
        return i18n("≈%1/h · ≈%2 by reset", fmtCost(b.costPerHour), fmtCost(b.projectedCost))
    }
    function summaryText() {
        if (!usage || !usage.ok) return errorText || i18n("Claude Code usage unavailable")
        const line = (label, b) => i18n("%1: %2 tokens · ≈%3 · %4 sessions", label, fmtTokens(b.tokens), fmtCost(b.cost), b.sessions)
        const out = [i18n("Claude Code usage (%1)", new Date(usage.updated).toLocaleString(Qt.locale(), Locale.ShortFormat))]
        if (usage.block)
            out.push(i18n("5h block: %1 tokens · ≈%2 · resets in %3 · %4", fmtTokens(usage.block.tokens),
                          fmtCost(usage.block.cost), fmtMinutes(usage.block.minutesLeft), blockLine(usage.block)))
        out.push(line(i18n("Today"), usage.today), line(i18n("Last 7 days"), usage.week), line(i18n("Last 30 days"), usage.month))
        return out.join("\n")
    }
    function copySummary() {
        clipHelper.text = summaryText()
        clipHelper.selectAll()
        clipHelper.copy()
        clipHelper.text = ""
    }
    TextEdit { id: clipHelper; visible: false }

    // Cost alerts: at most one per 5-hour block and one per day, remembered in the config
    // so a Plasma restart doesn't repeat them.
    function checkAlerts() {
        if (!usage || !usage.ok) return
        const b = usage.block
        if (cfg.alertBlockCost > 0 && b && b.cost >= cfg.alertBlockCost && cfg.alertedBlock !== b.start) {
            cfg.alertedBlock = b.start
            notify(i18n("5-hour block passed %1", fmtCost(cfg.alertBlockCost)),
                   i18n("≈%1 so far, resets in %2 (%3).", fmtCost(b.cost), fmtMinutes(b.minutesLeft), blockLine(b)))
        }
        const day = new Date().toDateString()
        if (cfg.alertDayCost > 0 && usage.today.cost >= cfg.alertDayCost && cfg.alertedDay !== day) {
            cfg.alertedDay = day
            notify(i18n("Today passed %1", fmtCost(cfg.alertDayCost)),
                   i18n("≈%1 and %2 tokens so far today.", fmtCost(usage.today.cost), fmtTokens(usage.today.tokens)))
        }
    }
    // KNotifications' QML module is used when installed; otherwise fall back to notify-send.
    // It's loaded at runtime so a missing module can't break the whole widget.
    property var notifier: null
    Component.onCompleted: {
        const c = Qt.createComponent("Notifier.qml")
        if (c.status === Component.Ready) notifier = c.createObject(root)
    }
    function notify(title, text) {
        if (notifier) {
            notifier.title = title
            notifier.text = text
            notifier.sendEvent()
            return
        }
        const q = s => "'" + String(s).replace(/'/g, "'\\''") + "'"
        notifySource.connectSource("notify-send -a " + q(i18n("Claude Code Usage")) + " -i view-statistics "
                                   + q(title) + " " + q(text))
    }
    P5Support.DataSource {
        id: notifySource
        engine: "executable"
        connectedSources: []
        onNewData: (source) => disconnectSource(source)
    }

    P5Support.DataSource {
        id: executable
        engine: "executable"
        connectedSources: []
        onNewData: (source, data) => {
            disconnectSource(source)
            if (data["exit code"] !== 0 && !data.stdout) {
                root.errorText = (data.stderr || i18n("Collector exited with code %1", data["exit code"])).trim()
                return
            }
            try {
                const parsed = JSON.parse(data.stdout)
                root.usage = parsed
                root.errorText = parsed.ok ? "" : parsed.error
                root.checkAlerts()
            } catch (e) {
                root.errorText = i18n("Could not read collector output: %1", e.message)
            }
        }
    }

    Timer {
        interval: Math.max(10, root.cfg.refreshSeconds) * 1000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: root.refresh()
    }

    // Refresh as soon as the popup opens so the numbers are never a minute stale.
    onExpandedChanged: if (root.expanded) refresh()

    Plasmoid.icon: "view-statistics"
    toolTipMainText: i18n("Claude Code usage")
    toolTipSubText: {
        if (errorText) return errorText
        if (!usage) return i18n("Loading…")
        const t = usage.today, b = usage.block
        let s = i18n("Today: %1 tokens · ≈%2", fmtTokens(t.tokens), fmtCost(t.cost))
        if (b) s += "\n" + i18n("5h block: %1 tokens · resets in %2", fmtTokens(b.tokens), fmtMinutes(b.minutesLeft))
                    + "\n" + blockLine(b)
        else s += "\n" + i18n("No active 5-hour block")
        s += "\n" + i18n("Middle-click to refresh")
        for (const h of errorHosts)
            s += "\n⚠ " + h.name + ": " + shortError(h.error)
        for (const h of offlineHosts)
            s += "\n" + (h.stale ? i18n("%1 offline, last seen %2", h.name, fmtTime(h.fetched)) : i18n("%1 offline", h.name))
        return s
    }

    Plasmoid.contextualActions: [
        PlasmaCore.Action {
            text: i18n("Refresh")
            icon.name: "view-refresh"
            onTriggered: root.refresh(true)
        },
        PlasmaCore.Action {
            text: i18n("Copy Summary")
            icon.name: "edit-copy"
            enabled: !!(root.usage && root.usage.ok)
            onTriggered: root.copySummary()
        }
    ]

    compactRepresentation: MouseArea {
        id: compact
        readonly property bool vertical: Plasmoid.formFactor === PlasmaCore.Types.Vertical
        Layout.minimumWidth: vertical ? -1 : row.implicitWidth + Kirigami.Units.smallSpacing * 2
        Layout.preferredWidth: Layout.minimumWidth
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.MiddleButton
        onClicked: (mouse) => {
            if (mouse.button === Qt.MiddleButton) root.refresh(true)
            else root.expanded = !root.expanded
        }

        RowLayout {
            id: row
            anchors.centerIn: parent
            spacing: Kirigami.Units.smallSpacing

            Kirigami.Icon {
                // Always shown when the label is hidden, so the widget never shrinks to nothing.
                visible: root.cfg.showIcon || compact.vertical || root.hideLabel
                source: root.errorText || root.errorHosts.length ? "dialog-warning" : "view-statistics"
                Layout.preferredWidth: Kirigami.Units.iconSizes.small
                Layout.preferredHeight: Kirigami.Units.iconSizes.small
            }
            PlasmaComponents.Label {
                visible: !compact.vertical && !root.hideLabel
                text: {
                    if (root.errorText) return i18n("error")
                    const b = root.panelBucket
                    const parts = []
                    if (root.cfg.showTokens) parts.push(root.fmtTokens(b ? b.tokens : 0))
                    if (root.cfg.showCost) parts.push(root.fmtCost(b ? b.cost : 0))
                    if (root.cfg.showReset && root.usage && root.usage.block)
                        parts.push("⟳ " + root.fmtMinutes(root.usage.block.minutesLeft))
                    return root.usage ? parts.join(" · ") : "…"
                }
                font.features: { "tnum": 1 }
            }
        }
    }

    fullRepresentation: PlasmaExtras.Representation {
        Layout.minimumWidth: Kirigami.Units.gridUnit * 20
        Layout.minimumHeight: Kirigami.Units.gridUnit * 22
        Layout.preferredWidth: Kirigami.Units.gridUnit * 22
        Layout.preferredHeight: content.implicitHeight + Kirigami.Units.largeSpacing * 2 + Kirigami.Units.gridUnit * 2
        collapseMarginsHint: true

        header: PlasmaExtras.PlasmoidHeading {
            RowLayout {
                anchors.fill: parent
                Kirigami.Heading {
                    level: 3
                    text: i18n("Claude Code usage")
                    Layout.fillWidth: true
                }
                PlasmaComponents.ToolButton {
                    icon.name: "view-refresh"
                    onClicked: root.refresh(true)
                    PlasmaComponents.ToolTip.text: i18n("Refresh")
                    PlasmaComponents.ToolTip.visible: hovered
                }
            }
        }

        PlasmaComponents.ScrollView {
            id: scroll
            anchors.fill: parent
            contentWidth: availableWidth
            QQC2.ScrollBar.horizontal.policy: QQC2.ScrollBar.AlwaysOff

            Item {
                width: scroll.availableWidth
                implicitHeight: content.implicitHeight + Kirigami.Units.largeSpacing * 2

                ColumnLayout {
                    id: content
                    x: Kirigami.Units.largeSpacing
                    y: Kirigami.Units.largeSpacing
                    width: parent.width - Kirigami.Units.largeSpacing * 2
                    spacing: Kirigami.Units.largeSpacing

                    PlasmaExtras.PlaceholderMessage {
                        visible: !!root.errorText
                        Layout.fillWidth: true
                        iconName: "dialog-warning"
                        text: i18n("Couldn't read usage")
                        explanation: root.errorText
                    }

                    Repeater {
                        model: root.errorHosts
                        Kirigami.InlineMessage {
                            required property var modelData
                            Layout.fillWidth: true
                            visible: true
                            type: Kirigami.MessageType.Warning
                            text: modelData.name + ": " + root.shortError(modelData.error)
                            HoverHandler { id: errHover }
                            PlasmaComponents.ToolTip.text: modelData.error
                                + (modelData.stale ? "\n" + i18n("Showing numbers from %1.", root.fmtTime(modelData.fetched)) : "")
                            PlasmaComponents.ToolTip.visible: errHover.hovered
                        }
                    }

                    // Current 5-hour block
                    ColumnLayout {
                        visible: !root.errorText && !!root.usage
                        Layout.fillWidth: true
                        spacing: Kirigami.Units.smallSpacing

                        RowLayout {
                            Layout.fillWidth: true
                            PlasmaComponents.Label {
                                text: i18n("Current 5-hour block")
                                font.bold: true
                                Layout.fillWidth: true
                            }
                            PlasmaComponents.Label {
                                opacity: 0.7
                                text: root.usage && root.usage.block
                                      ? i18n("%1–%2 · resets in %3", root.fmtTime(root.usage.block.start),
                                             root.fmtTime(root.usage.block.end), root.fmtMinutes(root.usage.block.minutesLeft))
                                      : i18n("No active block")
                            }
                        }
                        PlasmaComponents.ProgressBar {
                            Layout.fillWidth: true
                            visible: !!(root.usage && root.usage.block)
                            from: 0
                            to: 300
                            value: root.usage && root.usage.block ? 300 - root.usage.block.minutesLeft : 0
                        }
                        PlasmaComponents.Label {
                            visible: !!(root.usage && root.usage.block)
                            text: root.usage && root.usage.block
                                  ? i18n("%1 tokens · ≈%2 · %3 requests", root.fmtTokens(root.usage.block.tokens),
                                         root.fmtCost(root.usage.block.cost), root.usage.block.messages)
                                  : ""
                        }
                        PlasmaComponents.Label {
                            visible: !!(root.usage && root.usage.block)
                            opacity: 0.7
                            text: root.usage && root.usage.block ? root.blockLine(root.usage.block) : ""
                            PlasmaComponents.ToolTip.text: i18n("Average since the block's first request, projected to the reset if usage continues at this pace.")
                            PlasmaComponents.ToolTip.visible: burnHover.hovered
                            HoverHandler { id: burnHover }
                        }
                    }

                    // Period summary table
                    GridLayout {
                        visible: !root.errorText && !!root.usage
                        Layout.fillWidth: true
                        columns: 4
                        columnSpacing: Kirigami.Units.largeSpacing
                        rowSpacing: Kirigami.Units.smallSpacing

                        // One flat list of cells, row by row: header row, then Today / 7 days / 30 days.
                        Repeater {
                            model: {
                                const cells = [{ t: "" }, { t: i18n("Tokens"), h: true }, { t: i18n("≈ Cost"), h: true }, { t: i18n("Sessions"), h: true }]
                                if (root.usage && root.usage.ok) {
                                    for (const [label, b] of [[i18n("Today"), root.usage.today],
                                                              [i18n("Last 7 days"), root.usage.week],
                                                              [i18n("Last 30 days"), root.usage.month]]) {
                                        cells.push({ t: label, first: true }, { t: root.fmtTokens(b.tokens) },
                                                   { t: root.fmtCost(b.cost) }, { t: String(b.sessions) })
                                    }
                                }
                                return cells
                            }
                            PlasmaComponents.Label {
                                required property var modelData
                                text: modelData.t
                                font.bold: !!modelData.first
                                opacity: modelData.h ? 0.7 : 1
                                font.features: { "tnum": 1 }
                                Layout.fillWidth: !!modelData.first || modelData.t === ""
                                Layout.alignment: modelData.first || modelData.t === "" ? Qt.AlignLeft : Qt.AlignRight
                            }
                        }
                    }

                    // Last 7 days bar chart (by tokens)
                    ColumnLayout {
                        visible: !root.errorText && !!root.usage
                        Layout.fillWidth: true
                        spacing: Kirigami.Units.smallSpacing

                        PlasmaComponents.Label { text: i18n("Daily tokens"); font.bold: true }
                        RowLayout {
                            id: bars
                            Layout.fillWidth: true
                            Layout.preferredHeight: Kirigami.Units.gridUnit * 4
                            Layout.minimumHeight: Layout.preferredHeight
                            Layout.maximumHeight: Layout.preferredHeight
                            spacing: Kirigami.Units.smallSpacing
                            readonly property real peak: {
                                let m = 1
                                if (root.usage && root.usage.days) for (const d of root.usage.days) m = Math.max(m, d.tokens)
                                return m
                            }
                            Repeater {
                                model: root.usage && root.usage.days ? root.usage.days : []
                                ColumnLayout {
                                    required property var modelData
                                    required property int index
                                    Layout.fillWidth: true
                                    Layout.fillHeight: true
                                    spacing: 2
                                    Item {
                                        Layout.fillWidth: true
                                        Layout.fillHeight: true
                                        Rectangle {
                                            anchors.bottom: parent.bottom
                                            anchors.horizontalCenter: parent.horizontalCenter
                                            width: Math.min(parent.width, Kirigami.Units.gridUnit * 1.5)
                                            height: Math.max(modelData.tokens > 0 ? 2 : 0, parent.height * modelData.tokens / bars.peak)
                                            radius: 2
                                            color: index === 6 ? Kirigami.Theme.highlightColor
                                                               : Qt.alpha(Kirigami.Theme.highlightColor, 0.55)
                                        }
                                        HoverHandler { id: barHover }
                                        PlasmaComponents.ToolTip.text: i18n("%1: %2 tokens · ≈%3", modelData.date,
                                                                            root.fmtTokens(modelData.tokens), root.fmtCost(modelData.cost))
                                        PlasmaComponents.ToolTip.visible: barHover.hovered
                                    }
                                    PlasmaComponents.Label {
                                        text: modelData.date
                                        opacity: 0.7
                                        font: Kirigami.Theme.smallFont
                                        Layout.alignment: Qt.AlignHCenter
                                    }
                                }
                            }
                        }
                    }

                    // Top projects and models over the last 7 days
                    Repeater {
                        model: root.usage && root.usage.ok ? [
                            { title: i18n("Hosts (7 days)"), items: root.hostRows },
                            { title: i18n("Projects (7 days)"), items: root.usage.week.projects },
                            { title: i18n("Models (7 days)"), items: root.usage.week.models }
                        ] : []
                        ColumnLayout {
                            required property var modelData
                            visible: !root.errorText && modelData.items.length > 0
                            Layout.fillWidth: true
                            spacing: 2
                            PlasmaComponents.Label { text: modelData.title; font.bold: true }
                            Repeater {
                                model: modelData.items
                                RowLayout {
                                    required property var modelData
                                    Layout.fillWidth: true
                                    PlasmaComponents.Label {
                                        text: modelData.other ? i18np("%1 other", "%1 others", modelData.count) : modelData.name
                                        opacity: modelData.other ? 0.7 : 1
                                        elide: Text.ElideMiddle
                                        Layout.fillWidth: true
                                    }
                                    PlasmaComponents.Label {
                                        visible: !!modelData.note
                                        text: modelData.note || ""
                                        opacity: 0.6
                                        font: Kirigami.Theme.smallFont
                                    }
                                    PlasmaComponents.Label { text: root.fmtTokens(modelData.tokens); opacity: 0.7; font.features: { "tnum": 1 } }
                                    PlasmaComponents.Label {
                                        text: root.fmtCost(modelData.cost)
                                        horizontalAlignment: Text.AlignRight
                                        Layout.minimumWidth: Kirigami.Units.gridUnit * 3
                                        font.features: { "tnum": 1 }
                                    }
                                }
                            }
                        }
                    }

                    PlasmaComponents.Label {
                        Layout.fillWidth: true
                        wrapMode: Text.WordWrap
                        opacity: 0.6
                        font: Kirigami.Theme.smallFont
                        text: root.usage && root.usage.ok
                              ? i18n("Updated %1 · ≈ cost is Claude Code's API-equivalent estimate, not your plan's bill.",
                                     root.fmtTime(root.usage.updated))
                              : ""
                    }
                }
            }
        }
    }
}
