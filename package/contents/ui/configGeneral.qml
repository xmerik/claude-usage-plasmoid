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
