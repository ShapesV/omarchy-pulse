import QtQuick
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons
import "Model.js" as Model

// Pulse — the bar icon.
//
// This is the plugin's entry point, and it has to be a BarWidget: the bar
// injects `bar`, `settings` and `fixedEdge` into the widget it is given and
// sizes the slot from its implicitWidth/implicitHeight. Anything else is not
// draggable and does not sit in the row.
//
// The popup lives in Panel.qml and is loaded on demand, the way the stock
// widgets do it — the icon is cheap, and the panel only exists while open.
BarWidget {
  id: root
  moduleName: "io.github.shapesv.pulse"

  readonly property bool opened: panelLoader.item
    ? panelLoader.item.opened === true
    : false
  readonly property bool popoutSwitchClosing: panelLoader.item
    ? panelLoader.item.popoutSwitchClosing === true
    : false

  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function toggle() { if (panelLoader.item) panelLoader.item.toggle() }
  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  function injectPanel() {
    if (!panelLoader.item) return
    panelLoader.item.bar = root.bar
    panelLoader.item.anchorItem = button
    panelLoader.item.hostWidget = root
  }

  // The bar reads these to lay out the slot. Without them the widget has no
  // size, which is what put the icon outside the row.
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()

  // A single file the daemon rewrites every tick. Reading it here (rather
  // than in the panel) keeps the icon correct while the panel is closed.
  FileView {
    id: snapshotFile
    path: Model.snapshotPath()
    watchChanges: true
    printErrors: false
    onLoaded: root.applySnapshot(text())
    onFileChanged: reload()
  }

  property var status: Model.emptyStatus()

  function applySnapshot(raw) {
    var parsed = Model.parseSnapshot(raw)
    if (parsed.ok) root.status = parsed.status
  }

  readonly property string profile: String(status.applied || "full")
  readonly property bool enabled: status.enabled !== false
  readonly property bool fresh: Model.isFresh(status)
  readonly property real temp: status.temp === null || status.temp === undefined ? -1 : Number(status.temp)

  function refreshSnapshot() {
    // Force a re-read: the daemon writes on its own schedule, and a command
    // that just landed should show up without waiting for the next tick.
    snapshotFile.reload()
  }

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // One gamepad glyph chosen locally from a fixed set. Nothing user- or
    // network-supplied reaches this property.
    text: Model.profileGlyph(root.profile, root.enabled, root.fresh)
    tooltipText: Model.barTooltip(root.profile, root.temp, root.enabled, root.fresh)
    onPressed: function(b) {
      if (b === Qt.LeftButton) root.toggle()
    }
  }
}