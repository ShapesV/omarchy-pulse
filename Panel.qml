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
    if (isGame) return strings.t("pulse.game.active").arg(root.temp >= 0
      ? Commons.I18n.formatNumber(root.temp, 0) + " °C"
      : strings.t("pulse.profile.game"))
    if (!fresh) return strings.t("pulse.stale")
    if (!enabled) return strings.t("pulse.pinned")
    if (temp < 0) return strings.t("pulse.noThermal")
    return strings.t("pulse.tempMeta").arg(Commons.I18n.formatNumber(temp, 0))
  }

  readonly property bool isGame: Model.isGame(status)

  // The long form of what the running profile actually does. One paragraph,
  // for the profile that is on, so the cards above can stay one line each.
  readonly property string detailText: {
    if (isGame) return strings.t("pulse.detail.game")
    if (profile === "light") return strings.t("pulse.detail.light")
    if (profile === "medium") return strings.t("pulse.detail.medium")
    return strings.t("pulse.detail.full")
  }

  readonly property string subline: {
    if (isGame) return strings.t("pulse.game.hint")
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
    contentWidth: panel.fittedContentWidth(Style.space(560))
    contentHeight: panel.fittedContentHeight(panel.loadedContentHeight, Style.space(420))

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

        // ---------- profiles, side by side ----------
        //
        // Three columns rather than three stacked rows: a profile difference
        // is a difference of degree, and putting them along one axis makes
        // the whole ladder readable in one glance instead of one scroll.
        // The explanation sits under each name, wrapped, because "Light" and
        // "Medium" mean nothing until you know what stops happening.
        Grid {
          width: parent.width
          columns: 3
          columnSpacing: Style.spacing.sm
          rowSpacing: Style.spacing.sm

          Repeater {
            // Fixed rows, built once from local catalogue strings.
            model: Model.profileRows(root.status, root.fresh, strings)

            Button {
              required property var modelData
              width: (parent.width - Style.spacing.sm * 2) / 3
              height: Math.max(cardBody.implicitHeight + Style.space(20), Style.space(92))

              bordered: true
              // The game card is a report, not a control. Button's own MouseArea ignores
              // `enabled`, so the guard has to be in the handler as well.
              active: modelData.checked
              opacity: modelData.id === "game" ? 0.75 : 1.0

              Column {
                id: cardBody
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Style.space(10)
                anchors.rightMargin: Style.space(10)
                spacing: Style.space(4)

                Text {
                  textFormat: Text.PlainText
                  width: parent.width
                  text: modelData.label
                  color: root.bar.foreground
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.subtitle
                  font.bold: true
                  elide: Text.ElideRight
                }

                Text {
                  textFormat: Text.PlainText
                  width: parent.width
                  text: modelData.short
                  color: Qt.darker(root.bar.foreground, 1.5)
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.WordWrap
                }
              }

              onClicked: {
                if (modelData.id === "game") return
                root.pin(modelData.id)
              }
            }
          }
        }

        // The full explanation for the profile that is actually running.
        // Cards carry the one-line version; this says what changed and why.
        Text {
          textFormat: Text.PlainText
          width: parent.width
          visible: root.detailText !== ""
          text: root.detailText
          color: Qt.darker(root.bar.foreground, 1.25)
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
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