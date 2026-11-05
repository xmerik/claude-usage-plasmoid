// Loaded at runtime by main.qml; if org.kde.notification isn't installed this fails to load
// and main.qml falls back to notify-send.
import QtQuick
import org.kde.notification

Notification {
    componentName: "plasma_workspace"
    eventId: "notification"
    iconName: "view-statistics"
}
