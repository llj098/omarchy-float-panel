#!/usr/bin/env python3
"""Real Quickshell/QLocalSocket recovery, isolated from the desktop and Hyprland."""
import os
import resource
from pathlib import Path
import shutil
import signal
import socket
import subprocess
import tempfile
import time

resource.setrlimit(resource.RLIMIT_CORE, (0, 0))

ROOT = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="float-panel-socket-") as directory:
    base = Path(directory)
    runtime = base / "runtime"
    runtime.mkdir(mode=0o700)
    shutil.copyfile(ROOT / "ReconnectingEventSocket.qml", base / "ReconnectingEventSocket.qml")
    path = base / "events.sock"
    (base / "shell.qml").write_text('''import QtQuick
import Quickshell
import Quickshell.Io
ShellRoot {
    property int messages: 0
    ReconnectingEventSocket {
        path: Quickshell.env("TEST_EVENT_SOCKET")
        parser: SplitParser {
            splitMarker: "\\n"
            onRead: function(data) {
                if (data !== "epoch-" + messages) throw new Error("bad event " + data);
                messages++;
                if (messages === 3) {
                    console.info("EVENT_SOCKET_TEST_OK");
                    Qt.quit();
                }
            }
        }
    }
    Timer { interval: 12000; running: true; onTriggered: Qt.exit(1) }
}
''')
    env = dict(os.environ, QT_QPA_PLATFORM="offscreen", XDG_RUNTIME_DIR=str(runtime),
               XDG_CACHE_HOME=str(base / "cache"), TEST_EVENT_SOCKET=str(path),
               QT_QUICK_BACKEND="software", QT_QPA_PLATFORMTHEME="", QT_STYLE_OVERRIDE="Fusion")
    # Deliberately start without a server: the initial error must also recover.
    process = subprocess.Popen(["qs", "--no-color", "-p", str(base)], env=env,
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, start_new_session=True)
    try:
        time.sleep(0.6)
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        server.bind(str(path))
        server.listen()
        server.settimeout(6)
        for epoch in range(3):
            connection, _ = server.accept()
            with connection:
                connection.sendall(f"epoch-{epoch}\n".encode())
                time.sleep(0.1)
            # Both peer closures must recover without a shortcut or config reload.
        output, _ = process.communicate(timeout=6)
        assert process.returncode == 0 and "EVENT_SOCKET_TEST_OK" in output, output
        print("EVENT_SOCKET_TEST_OK (initial refusal + two peer disconnects; real Quickshell)")
    except Exception:
        os.killpg(process.pid, signal.SIGKILL)
        output, _ = process.communicate(timeout=5)
        print(output)
        raise
    finally:
        server.close() if 'server' in locals() else None
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()

# Exercise the ACTUAL request cleanup functions/handlers from both QML files,
# not an independent reimplementation of their behavior.
import re
for filename, function, pending in [
    ("TaskList.qml", "resetClientsRequest", "clientsRequestPending"),
    ("AppSwitcher.qml", "resetRequest", "snapshotRequestPending"),
]:
    source = (ROOT / filename).read_text()
    cleanup = re.search(r"(?m)^( +)function " + function + r"\(\) \{.*?^\1\}", source, re.S).group(0)
    error_handler = re.search(r"onError: (Qt.callLater\(root\." + function + r"\))", source).group(1)
    with tempfile.TemporaryDirectory(prefix="float-panel-request-") as directory:
        base = Path(directory)
        runtime = base / "runtime"
        runtime.mkdir(mode=0o700)
        path = base / "request.sock"
        (base / "shell.qml").write_text('''import QtQuick
import Quickshell
import Quickshell.Io
ShellRoot {
    id: root
    property bool clientsRequestPending: true
    property var pendingActivationGroup: null
    property string pendingWorkspaceName: "test"
    property bool snapshotRequestPending: true
    property var pendingClients: null
    property var pendingMonitors: null
    property int pendingDirection: 0
    property bool commitWhenReady: false
    ''' + cleanup + '''
    Socket {
        id: clientsSocket
        path: Quickshell.env("TEST_EVENT_SOCKET")
        connected: true
        onError: ''' + error_handler + '''
    }
    Socket { id: monitorsSocket; connected: false }
    Timer {
        interval: 20; running: true; repeat: true
        onTriggered: if (!root.''' + pending + ''') {
            console.info("REQUEST_ERROR_TEST_OK"); Qt.quit();
        }
    }
    Timer { interval: 6000; running: true; onTriggered: Qt.exit(1) }
}
''')
        env = dict(os.environ, QT_QPA_PLATFORM="offscreen", XDG_RUNTIME_DIR=str(runtime),
                   XDG_CACHE_HOME=str(base / "cache"), TEST_EVENT_SOCKET=str(path),
                   QT_QUICK_BACKEND="software", QT_QPA_PLATFORMTHEME="", QT_STYLE_OVERRIDE="Fusion")
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as server:
            server.bind(str(path))
            server.listen()
            server.settimeout(5)
            process = subprocess.Popen(["qs", "--no-color", "-p", str(base)], env=env,
                                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                       text=True, start_new_session=True)
            try:
                connection, _ = server.accept()
                with connection:
                    time.sleep(0.1)
                output, _ = process.communicate(timeout=5)
                assert process.returncode == 0 and "REQUEST_ERROR_TEST_OK" in output, output
                print(f"REQUEST_ERROR_TEST_OK ({filename}; actual handler, real peer disconnect)")
            except Exception:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                output, _ = process.communicate(timeout=5)
                print(output)
                raise
            finally:
                if process.poll() is None:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
