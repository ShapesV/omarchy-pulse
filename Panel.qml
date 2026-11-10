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
// The decision logic is not here. `bin/pulse-ctl` owns it, because a threshold
// that changes what your desktop looks like belongs somewhere it can be tested
// from a shell rather than inside a long-lived QML process. This panel reads
// the snapshot that daemon writes and sends it one-off commands.
//
// That split also keeps the widget free in the background: no process is
// spawned on a timer, and the only thing that runs while the panel is closed
// is the systemd service doing its once-a-tick read.
Panel {
  id: root
  moduleName: "io.github.USERNAME.pulse"
  ipcTarget: "io.github.USERNAME.pulse"

  readonly property string pluginDir: Model.pluginDir()
  readonly property string ctl: pluginDir + "/bin/pulse-ctl"
  readonly property string python: Model.pythonBinary()
  readonly property string snapshotPath: Model.snapshotPath()

  property var status: Model.emptyStatus()
  property bool busy: false
  property string lastError: ""

  readonly property string profile: String(status.applied || "full")
  readonly property bool enabled: status.enabled !== false
  readonly property var reasons: status.reasons || []
  readonly property var history: status.history || []
  readonly property real temp: status.temp === null || status.temp === undefined ? -1 : Number(status.temp)
  readonly property bool fresh: Model.isFresh(status)

  readonly property string heroTitle: {
    if (!enabled) return strings.t("pulse.pinned")
    if (profile === "light") return strings.t("pulse.profile.light")
    if (profile === "medium") return strings.t("pulse.profile.medium")
    return strings.t("pulse.profile.full")
  }

  readonly property string heroMeta: {
    if (temp < 0) return strings.t("pulse.noThermal")
    return strings.t("pulse.tempMeta").arg(Commons.I18n.formatNumber(temp, 0))
  }

  readonly property string heroDetail: {
    if (!fresh) return strings.t("pulse.stale")
    if (reasons.length > 0) return reasons.join(" · ")
    if (!enabled) return strings.t("pulse.pinnedDetail")
    return strings.t("pulse.relaxed")
  }

  Commons.Translations {
    id: strings
    directory: Qt.resolvedUrl("i18n")
  }

  // ------------------------------------------------ snapshot watcher
  //
  // FileView watches the daemon's output file, so the panel repaints when the
  // daemon writes and costs nothing when it does not. This is the whole
  // reason the widget does not need a polling timer.
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
    busy = true
  }

  function pin(value) {
    // Re-pinning the profile that is already pinned turns adaptation back on,
    // so the two controls cannot contradict each other.
    if (enabled && String(status.configured || "") === value) {
      runCommand(["enable", "on"])
      return
    }
    runCommand(["profile", value])
  }

  function toggleAdaptation() {
    runCommand(["enable", enabled ? "off" : "on"])
  }

  function releaseControl() {
    runCommand(["stop"])
  }

  onOpenedChanged: if (opened) snapshotFile.reload()

  Process {
    id: ctlProc
    stdout: StdioCollector {
      waitForEnd: true
    }
    onExited: function(code) {
      root.busy = false
      if (code !== 0) root.lastError = strings.t("pulse.commandFailed")
      // The daemon owns the snapshot; give it a moment to take the change,
      // then read whatever it wrote rather than pretending we know.
      Qt.callLater(function() { snapshotFile.reload() })
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // One glyph, chosen locally from a fixed set. Nothing user- or
    // network-supplied reaches this text property.
    text: Model.profileGlyph(root.profile, root.enabled, root.fresh)
    onPressed: function(b) { root.toggle() }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: panel.loadedContent
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(panel.loadedContentHeight, Style.space(560))

    content: PanelKeyCatcher {
      id: keyCatcher
      implicitHeight: column.implicitHeight
      anchors.fill: parent
      onCloseRequested: root.close()

      ScrollView {
        id: scrollArea
        anchors.fill: parent
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        ScrollBar.vertical.policy: column.implicitHeight > height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff

        Column {
          id: column
          width: scrollArea.availableWidth
          spacing: Style.space(14)

          // ---------- hero: current profile, temperature, why ----------
          PanelHero {
            width: parent.width
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
            title: root.heroTitle
            meta: root.heroMeta
            detail: root.heroDetail
            metaOpacity: root.fresh ? 1.0 : 0.5
            iconComponent: Component {
              Text {
                textFormat: Text.PlainText
                text: Model.profileGlyph(root.profile, root.enabled, root.fresh)
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.display
              }
            }
          }

          // ---------- temperature sparkline ----------
          Sparkline {
            width: parent.width
            height: Style.space(40)
            visible: root.history.length > 1
            values: root.history
            foreground: root.bar.foreground
            accent: Commons.Color.accent
          }

          PanelSeparator { foreground: root.bar.foreground }

          // ---------- profiles ----------
          PanelSectionHeader {
            text: strings.t("pulse.profiles")
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
          }

          Column {
            width: parent.width
            spacing: Style.spacing.sm

            Repeater {
              model: [
                { id: "light", label: strings.t("pulse.profile.light"), hint: strings.t("pulse.hint.light") },
                { id: "medium", label: strings.t("pulse.profile.medium"), hint: strings.t("pulse.hint.medium") },
                { id: "full", label: strings.t("pulse.profile.full"), hint: strings.t("pulse.hint.full") }
              ]

              Toggle {
                required property var modelData
                width: parent.width
                label: modelData.label
                description: modelData.hint
                // Configured profile is what the config asks for; the hero
                // above shows what the sensors actually got. Keeping the two
                // apart is the difference between "asked for" and "got".
                checked: String(root.status.configured || "medium") === modelData.id
                foreground: root.bar.foreground
                accent: Commons.Color.accent
                fontFamily: root.bar.fontFamily
                onClicked: root.pin(modelData.id)
              }
            }
          }

          // ---------- sensors ----------
          PanelSeparator { foreground: root.bar.foreground }

          Column {
            width: parent.width
            spacing: Style.spacing.sm

            Repeater {
              model: Model.sensorRows(root.status, strings)

              Row {
                required property var modelData
                width: parent.width
                spacing: Style.space(8)

                Text {
                  textFormat: Text.PlainText
                  text: modelData.label
                  color: Qt.darker(root.bar.foreground, 1.3)
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  width: parent.width * 0.42
                  elide: Text.ElideRight
                  anchors.verticalCenter: parent.verticalCenter
                }

                Text {
                  textFormat: Text.PlainText
                  text: modelData.value
                  color: modelData.ok ? root.bar.foreground : Qt.darker(root.bar.foreground, 1.9)
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  elide: Text.ElideRight
                  anchors.verticalCenter: parent.verticalCenter
                }
              }
            }
          }

          // ---------- adaptation ----------
          PanelSeparator { foreground: root.bar.foreground }

          Column {
            width: parent.width
            spacing: Style.spacing.sm

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

            Button {
              width: parent.width
              text: strings.t("pulse.release")
              bordered: true
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              onClicked: root.releaseControl()
            }
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

  // A plain polyline of recent temperatures. Drawn rather than charted: it is
  // forty numbers, and a chart library for forty numbers is a dependency with
  // a release schedule.
  component Sparkline: Item {
    id: spark
    property var values: []
    property color foreground: Commons.Color.foreground
    property color accent: Commons.Color.accent

    readonly property real lo: {
      var min = Infinity
      for (var i = 0; i < values.length; i++) min = Math.min(min, Number(values[i]))
      return isFinite(min) ? min : 0
    }
    readonly property real hi: {
      var max = -Infinity
      for (var i = 0; i < values.length; i++) max = Math.max(max, Number(values[i]))
      return isFinite(max) ? max : 1
    }

    Canvas {
      id: canvas
      anchors.fill: parent

      Connections {
        target: spark
        function onValuesChanged() { canvas.requestPaint() }
      }

      onPaint: {
        var ctx = getContext("2d")
        ctx.reset()
        var n = spark.values.length
        if (n < 2) return

        var span = Math.max(1, spark.hi - spark.lo)
        var stepX = width / (n - 1)
        var pad = Math.max(1, Style.space(2))

        ctx.beginPath()
        for (var i = 0; i < n; i++) {
          var y = height - pad - ((Number(spark.values[i]) - spark.lo) / span) * (height - pad * 2)
          if (i === 0) ctx.moveTo(0, y)
          else ctx.lineTo(i * stepX, y)
        }
        ctx.lineWidth = Math.max(1, Style.space(1))
        ctx.strokeStyle = spark.accent
        ctx.stroke()

        // Axis line, faint so it reads as chrome rather than as data.
        ctx.beginPath()
        ctx.moveTo(0, height - 1)
        ctx.lineTo(width, height - 1)
        ctx.strokeStyle = Qt.alpha(spark.foreground, 0.2)
        ctx.lineWidth = 1
        ctx.stroke()
      }
    }
  }
}