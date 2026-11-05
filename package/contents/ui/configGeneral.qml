import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import org.kde.kcmutils as KCM

KCM.SimpleKCM {
    property alias cfg_refreshSeconds: refresh.value
    property alias cfg_panelPeriod: period.currentIndex
    property alias cfg_showCost: showCost.checked
    property alias cfg_showTokens: showTokens.checked
    property alias cfg_showReset: showReset.checked
    property alias cfg_showIcon: showIcon.checked
    property alias cfg_remotes: remotes.text
    property alias cfg_hideWhenIdle: hideWhenIdle.checked
    property alias cfg_topItems: topItems.value
    property alias cfg_alertBlockCost: alertBlock.value
    property alias cfg_alertDayCost: alertDay.value

    readonly property var dollars: (v) => v === 0 ? i18n("Off") : "$" + v
    readonly property var parseDollars: (t) => /off/i.test(t) ? 0 : (parseInt(String(t).replace(/[^0-9]/g, "")) || 0)

    Kirigami.FormLayout {
        QQC2.SpinBox {
            id: refresh
            Kirigami.FormData.label: i18n("Refresh every:")
            from: 10
            to: 3600
            stepSize: 10
            textFromValue: (v) => i18np("%1 second", "%1 seconds", v)
            valueFromText: (t) => parseInt(t)
        }

        QQC2.ComboBox {
            id: period
            Kirigami.FormData.label: i18n("Panel shows:")
            model: [i18n("Current 5-hour block"), i18n("Today"), i18n("Last 7 days")]
        }

        QQC2.CheckBox {
            id: showIcon
            Kirigami.FormData.label: i18n("In the panel:")
            text: i18n("Icon")
        }
        QQC2.CheckBox {
            id: showTokens
            text: i18n("Tokens")
        }
        QQC2.CheckBox {
            id: showCost
            text: i18n("Estimated cost")
        }
        QQC2.CheckBox {
            id: showReset
            text: i18n("Time until the 5-hour block resets")
        }
        QQC2.CheckBox {
            id: hideWhenIdle
            text: i18n("Only the icon when no 5-hour block is active")
        }

        QQC2.SpinBox {
            id: topItems
            Kirigami.FormData.label: i18n("Projects and models:")
            from: 0
            to: 50
            textFromValue: (v) => v === 0 ? i18n("Show all") : i18n("Top %1, then others", v)
            valueFromText: (t) => parseInt(t) || 0
        }

        Item { Kirigami.FormData.isSection: true }

        QQC2.SpinBox {
            id: alertBlock
            Kirigami.FormData.label: i18n("Notify when the 5-hour block passes:")
            from: 0
            to: 100000
            stepSize: 5
            editable: true
            textFromValue: (v) => dollars(v)
            valueFromText: (t) => parseDollars(t)
        }
        QQC2.SpinBox {
            id: alertDay
            Kirigami.FormData.label: i18n("Notify when today passes:")
            from: 0
            to: 100000
            stepSize: 5
            editable: true
            textFromValue: (v) => dollars(v)
            valueFromText: (t) => parseDollars(t)
        }
        QQC2.Label {
            Layout.maximumWidth: Kirigami.Units.gridUnit * 18
            wrapMode: Text.WordWrap
            font: Kirigami.Theme.smallFont
            opacity: 0.7
            text: i18n("Estimated API-equivalent cost. At most one notification per block and per day.")
        }

        Item { Kirigami.FormData.isSection: true }

        QQC2.TextArea {
            id: remotes
            Kirigami.FormData.label: i18n("Remote hosts:")
            Layout.minimumWidth: Kirigami.Units.gridUnit * 18
            Layout.minimumHeight: Kirigami.Units.gridUnit * 4
            placeholderText: "server:~/.claude"
        }
        QQC2.Label {
            Layout.maximumWidth: Kirigami.Units.gridUnit * 18
            wrapMode: Text.WordWrap
            font: Kirigami.Theme.smallFont
            opacity: 0.7
            text: i18n("One per line: an SSH host (from ~/.ssh/config) and its Claude folder. Needs key-based SSH and python3 on the host. Only token counts are transferred.")
        }
    }
}
