import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons
import qs.Commons as Commons
import "Model.js" as Model

// Pulse — adaptive performance profiles.
//
// Deliberately small. The panel is three rows and a slider-free layout, and it
// opens in one frame: anything that grows or measures itself after the fact
// (a Repeater over live data, a chart that resizes, a list that arrives late)
// is a thing that can stutter when the machine is already under pressure —
// which is exactly when this panel gets opened.
//
// The decision logic is not here either. `bin/pulse-ctl` owns it, because a
// threshold that changes what your desktop looks like belongs somewhere it can
// be tested from a shell. This panel reads the snapshot that daemon writes.
Panel {
  id: root
  moduleName: "io.github.USERNAME.pulse"
  ipcTarget: "io.github.USERNAME.pulse"

  readonly property string pluginDir: Model.pluginDir()
  readonly property string ctl: pluginDir + "/bin/pulse-ctl"
  readonly property string python: Model.pythonBinary()
  readonly property string snapshotPath: Model.snapshotPath()

  property var status: Model.emptyStatus()
  property string lastError: ""

  readonly property string profile: String(status.applied || "full")
  readonly property bool enabled: status.enabled !== false
  readonly property bool fresh: Model.isFresh(status)
  readonly property real temp: status.temp === null || status.temp === undefined ? -1 : Number(status.temp)

  // One line of fact, built from at most two short strings.
  readonly property string headline: {
    if (!fresh) return strings.t("pulse.stale")
    if (!enabled) return strings.t("pulse.pinned")
    if (temp < 0) return strings.t("pulse.noThermal")
    return strings.t("pulse.tempMeta").arg(Commons.I18n.formatNumber(temp, 0))
  }

  readonly property string subline: {
    if (!fresh || !enabled) return ""
    var reasons = status.reasons || []
    if (reasons.length > 0) return String(reasons[0])
    return strings.t("pulse.relaxed")
  }

  Commons.Translations {
    id: strings
    directory: Qt.resolvedUrl("i18n")
  }

  // The bar sizes the widget slot from these. Without them the button is
  // zero-sized and the panel anchors to a point rather than an icon, which
  // puts the popup off the edge of the screen.
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // Snapshot watcher. This is the whole reason the widget needs no timer:
  // FileView follows the daemon's file, so the panel repaints when the daemon
  // writes and costs nothing when it does not.
  FileView {
    id: snapshotFile
    path: root.snapshotPath
    watchChanges: true
    printErrors: false
    onLoaded: root.applySnapshot(text())
    onFileChanged: reload()
  }

  function applySnapshot(raw) {
    var parsed = Model.parseSnapshot(raw)
    if (parsed.ok) {
      root.status = parsed.status
      root.lastError = ""
    } else if (parsed.error !== "") {
      root.lastError = parsed.error
    }
  }

  function runCommand(args) {
    if (ctlProc.running) return
    ctlProc.command = [root.python, root.ctl, "--plugin-dir", root.pluginDir].concat(args)
    ctlProc.running = true
  }

  function pin(value) {
    runCommand(["profile", value])
  }

  function toggleAdaptation() {
    runCommand(["enable", enabled ? "off" : "on"])
  }

  onOpenedChanged: if (opened) snapshotFile.reload()

  Process {
    id: ctlProc
    stdout: StdioCollector {
      waitForEnd: true
    }
    onExited: function(code) {
      if (code !== 0) root.lastError = strings.t("pulse.commandFailed")
      // The daemon owns the snapshot; read what it wrote rather than assume.
      Qt.callLater(function() { snapshotFile.reload() })
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
    onPressed: function(b) { root.toggle() }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: panel.loadedContent
    contentWidth: panel.fittedContentWidth(Style.space(300))
    contentHeight: panel.fittedContentHeight(panel.loadedContentHeight, Style.space(360))

    content: PanelKeyCatcher {
      id: keyCatcher
      implicitHeight: column.implicitHeight
      anchors.fill: parent
      onCloseRequested: root.close()

      Column {
        id: column
        width: parent.width
        spacing: Style.space(12)

        // ---------- what is happening, in two lines ----------
        Row {
          width: parent.width
          spacing: Style.space(14)

          Text {
            textFormat: Text.PlainText
            text: Model.profileGlyph(root.profile, root.enabled, root.fresh)
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.display
            anchors.verticalCenter: parent.verticalCenter
          }

          Column {
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(1)
            width: parent.width - Style.space(14) - Style.font.display

            Text {
              textFormat: Text.PlainText
              text: root.headline
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
              width: parent.width
            }

            Text {
              textFormat: Text.PlainText
              visible: root.subline !== ""
              text: root.subline
              color: Qt.darker(root.bar.foreground, 1.4)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
              width: parent.width
            }
          }
        }

        PanelSeparator { foreground: root.bar.foreground }

        // ---------- three profiles, one press each ----------
        Column {
          width: parent.width
          spacing: Style.spacing.sm

          Repeater {
            // Gaps expanded in the Repeater rather than an itemType delegate
            // with a Timeout-based call: three fixed rows, built once, no
            // data that can arrive mid-frame.
            model: Model.profileRows(root.status, root.fresh, strings)

            Toggle {
              required property var modelData
              width: parent.width
              label: modelData.label
              description: modelData.hint
              checked: modelData.checked
              foreground: root.bar.foreground
              accent: Commons.Color.accent
              fontFamily: root.bar.fontFamily
              onClicked: root.pin(modelData.id)
            }
          }
        }

        PanelSeparator { foreground: root.bar.foreground }

        // ---------- one switch, one button ----------
        Toggle {
          width: parent.width
          label: strings.t("pulse.auto")
          description: strings.t("pulse.autoHint")
          checked: root.enabled
          foreground: root.bar.foreground
          accent: Commons.Color.accent
          fontFamily: root.bar.fontFamily
          onClicked: root.toggleAdaptation()
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width
          visible: root.lastError !== ""
          text: root.lastError
          color: Commons.Color.urgent
          wrapMode: Text.Wrap
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }
  }
}