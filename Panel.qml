import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons
import qs.Commons as Commons
import "Model.js" as Model

// The Pulse popup. Loaded by BarWidget.qml, which owns the bar slot.
//
// Deliberately small. It is three rows and two lines of text, built once:
// anything that grows or measures itself after the fact — a Repeater over
// live data, a chart that resizes, a list that arrives late — is something
// that can stutter when the machine is already under pressure, which is
// exactly when this panel gets opened.
//
// The decision logic is not here either. `bin/pulse-ctl` owns it, because a
// threshold that changes what your desktop looks like belongs somewhere it
// can be tested from a shell.
Panel {
  id: root
  moduleName: "io.github.shapesv.pulse"
  ipcTarget: "io.github.shapesv.pulse"

  // Set by BarWidget after loading.
  property Item anchorItem: null
  property Item hostWidget: null

  readonly property string pluginDir: Model.pluginDir()
  readonly property string ctl: pluginDir + "/bin/pulse-ctl"
  readonly property string python: Model.pythonBinary()

  // The icon already watches the snapshot; share its reading rather than
  // opening a second FileView on the same file.
  readonly property var status: hostWidget ? hostWidget.status : Model.emptyStatus()
  readonly property string profile: String(status.applied || "full")
  readonly property bool enabled: status.enabled !== false
  readonly property bool fresh: Model.isFresh(status)
  readonly property real temp: status.temp === null || status.temp === undefined ? -1 : Number(status.temp)

  property string lastError: ""

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

  onOpenedChanged: if (opened && root.hostWidget) root.hostWidget.refreshSnapshot()

  Process {
    id: ctlProc
    stdout: StdioCollector {
      waitForEnd: true
    }
    onExited: function(code) {
      if (code !== 0) root.lastError = strings.t("pulse.commandFailed")
      // The daemon owns the snapshot; read what it wrote rather than assume.
      Qt.callLater(function() {
        if (root.hostWidget) root.hostWidget.refreshSnapshot()
      })
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
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
            // Three fixed rows, built once from local catalogue strings.
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