import QtQuick
import Quickshell.Io

// Transport recovery only. Never use this timer for window placement or focus.
Socket {
    id: root
    connected: false
    property bool stopping: false
    property int retryDelay: 250
    signal interrupted()
    signal restored()

    function scheduleReconnect() {
        if (!stopping && path !== "" && !retry.running) retry.start();
    }

    onConnectionStateChanged: {
        if (connected) {
            retry.stop();
            retryDelay = 250;
            restored();
        } else if (!stopping) {
            interrupted();
            scheduleReconnect();
        }
    }
    function handleError() {
        if (stopping) return;
        connected = false;
        interrupted();
        scheduleReconnect();
    }
    // Quickshell 0.3.2 still uses its native socket after emitting error.
    // Disconnecting synchronously here can null it underneath that callback.
    onError: Qt.callLater(root.handleError)
    onPathChanged: {
        connected = false;
        retryDelay = 250;
        scheduleReconnect();
    }
    property Timer reconnectTimer: Timer {
        id: retry
        interval: root.retryDelay
        repeat: false
        onTriggered: {
            if (root.stopping || root.connected || root.path === "") return;
            root.retryDelay = Math.min(root.retryDelay * 2, 4000);
            root.connected = true;
        }
    }
    Component.onCompleted: if (path !== "") connected = true;
    Component.onDestruction: {
        stopping = true;
        retry.stop();
        connected = false;
    }
}
