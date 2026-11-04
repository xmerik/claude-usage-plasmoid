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
    readonly property string command: "python3 -I '" + collector + "'"
        + remotes.map(r => " --remote '" + r + "'").join("")
    readonly property var failedHosts: usage && usage.hosts ? usage.hosts.filter(h => !h.ok) : []

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
    function refresh() {
        executable.disconnectSource(command)
        executable.connectSource(command)
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
        for (const h of failedHosts)
            s += "\n⚠ " + (h.stale ? i18n("%1 unreachable, showing cached data", h.name) : i18n("%1 unreachable", h.name))
        return s
    }

    Plasmoid.contextualActions: [
        PlasmaCore.Action {
            text: i18n("Refresh")
            icon.name: "view-refresh"
            onTriggered: root.refresh()
        }
    ]

    compactRepresentation: MouseArea {
        id: compact
        readonly property bool vertical: Plasmoid.formFactor === PlasmaCore.Types.Vertical
        Layout.minimumWidth: vertical ? -1 : row.implicitWidth + Kirigami.Units.smallSpacing * 2
        Layout.preferredWidth: Layout.minimumWidth
        hoverEnabled: true
        onClicked: root.expanded = !root.expanded

        RowLayout {
            id: row
            anchors.centerIn: parent
            spacing: Kirigami.Units.smallSpacing

            Kirigami.Icon {
                visible: root.cfg.showIcon || compact.vertical
                source: root.errorText || root.failedHosts.length ? "dialog-warning" : "view-statistics"
                Layout.preferredWidth: Kirigami.Units.iconSizes.small
                Layout.preferredHeight: Kirigami.Units.iconSizes.small
            }
            PlasmaComponents.Label {
                visible: !compact.vertical
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
        Layout.preferredHeight: content.implicitHeight + Kirigami.Units.largeSpacing * 2
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
                    onClicked: root.refresh()
                    PlasmaComponents.ToolTip.text: i18n("Refresh")
                    PlasmaComponents.ToolTip.visible: hovered
                }
            }
        }

        ColumnLayout {
            id: content
            anchors.fill: parent
            anchors.margins: Kirigami.Units.largeSpacing
            spacing: Kirigami.Units.largeSpacing

            PlasmaExtras.PlaceholderMessage {
                visible: !!root.errorText
                Layout.fillWidth: true
                iconName: "dialog-warning"
                text: i18n("Couldn't read usage")
                explanation: root.errorText
            }

            Repeater {
                model: root.failedHosts
                Kirigami.InlineMessage {
                    required property var modelData
                    Layout.fillWidth: true
                    visible: true
                    type: modelData.stale ? Kirigami.MessageType.Warning : Kirigami.MessageType.Error
                    text: (modelData.stale
                           ? i18n("%1 is unreachable, so its numbers are from %2.", modelData.name, root.fmtTime(modelData.fetched))
                           : i18n("%1 is unreachable and not included.", modelData.name)) + "\n" + modelData.error
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
                    { title: i18n("Hosts (7 days)"), items: root.usage.hosts.length > 1 ? root.usage.week.hosts : [] },
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
                            PlasmaComponents.Label { text: modelData.name; elide: Text.ElideMiddle; Layout.fillWidth: true }
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

            Item { Layout.fillHeight: true }

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
