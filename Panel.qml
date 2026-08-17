import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Bar widget + popup for hybrid GPU control via cardwire.
//
// The bar shows the discrete GPU's real power state at a glance; the panel adds
// mode switching and — the reason this plugin exists — the list of processes
// actually holding the card open.
Panel {
  id: root
  moduleName: "io.github.rawritude.dgpu-control"
  ipcTarget: "io.github.rawritude.dgpu-control"
  manageIpc: false

  // Required: without an implicit size the button's `anchors.fill: parent`
  // collapses to zero and the widget renders nothing, silently. Not circular —
  // BarIconButton's implicitWidth comes from `fixedWidth: slotSize`.
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property bool verticalBar: bar ? bar.vertical : false

  // Settings can arrive as real JSON booleans or as strings depending on
  // whether `omarchy bar set` was given --json. A plain truthiness test would
  // read the string "false" as true.
  function boolSetting(name, fallback) {
    var v = root.setting(name, fallback)
    return typeof v === "string" ? v.toLowerCase() === "true" : !!v
  }
  readonly property bool warnWhenAwake: root.boolSetting("warnWhenAwake", true)

  // nf-md-memory: an IC with pins, which is the closest honest depiction of a
  // GPU in this font — JetBrainsMono Nerd Font has no graphics-card glyph.
  // Built from its codepoint, never pasted as a literal: it sits outside the
  // BMP, does not survive every editor or pipeline, and if it is silently lost
  // the label becomes "", which makes BarIconButton.hasVisualContent false and
  // renders an invisible widget with no error anywhere.
  //
  // The glyph deliberately never changes with state — colour and the adjacent
  // label carry that. A bar icon that changes shape makes the whole cluster
  // shift and is harder to find at a glance.
  readonly property string gpuGlyph: String.fromCodePoint(0xF035B)

  // nf-fa-refresh. In the BMP so a literal would survive, but built the same
  // way so the rule has no exceptions to remember.
  readonly property string refreshGlyph: String.fromCodePoint(0xF021)

  readonly property string barLabel: {
    var g = root.gpuGlyph
    if (root.verticalBar) return g
    if (!cardwire.available) return g
    if (cardwire.discreteOffLimits) return "off " + g
    // Smart still uses the card, so an awake one must still be visible here;
    // showing only "auto" hid exactly the state worth noticing.
    if (cardwire.discreteOnDemand)
      return (cardwire.discreteAwake ? cardwire.discretePowerState : "auto") + " " + g
    if (cardwire.discreteAwake) return cardwire.discretePowerState + " " + g
    return g
  }

  // Quiet / Balanced / Performance are real destinations. "custom" is appended
  // only once the fine limits already deviate from firmware defaults, so it
  // reports a state rather than offering one — selecting it is a no-op.
  readonly property var profileOptions: {
    var base = [
      { value: "quiet",       label: "Quiet",       tooltip: "Lowest power and fan noise" },
      { value: "balanced",    label: "Balanced",    tooltip: "Default envelope" },
      { value: "performance", label: "Performance", tooltip: "Highest sustained power" }
    ]
    if (armoury.userAdjusted) base.push({ value: "custom", label: "Custom",
      tooltip: "One or more limits differ from firmware defaults" })
    return base
  }

  readonly property var modeOptions: [
    { value: "integrated", label: "Integrated", tooltip: "Block the discrete GPU entirely" },
    { value: "hybrid",     label: "Hybrid",     tooltip: "Both GPUs available; dGPU parks when idle" },
    { value: "smart",      label: "Smart",      tooltip: "cardwire decides per application and power source" }
  ]

  ArmouryService {
    id: armoury
    detailWanted: root.opened
  }

  // The 250ms timer chain that used to live here is gone: ArmouryService now
  // queues writes and pumps the queue from the process's own exit, so nothing
  // is dropped when a firmware write runs long.

  CardwireService {
    id: cardwire
    fallbackPollMs: root.setting("fallbackPollMs", 300000)
    activePollMs: root.setting("activePollMs", 3000)
    detailWanted: root.opened
  }

  IpcHandler {
    target: "io.github.rawritude.dgpu-control"
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function integrated(): void { cardwire.setMode("integrated") }
    function hybrid(): void { cardwire.setMode("hybrid") }
    function smart(): void { cardwire.setMode("smart") }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.barLabel
    // Compare against the glyph rather than testing barLabel.length: the
    // codepoint is a surrogate pair, so `.length` is 2 for the bare glyph and a
    // `> 1` test would widen the slot permanently.
    slotSize: Style.bar.iconSlot * (root.barLabel !== root.gpuGlyph && !vertical ? 2.2 : 1)
    // Highlight only when the card is genuinely out of a low-power state.
    active: root.warnWhenAwake && cardwire.discreteAwake && !cardwire.discreteOffLimits
    onPressed: function(buttonCode) { root.toggle() }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(460))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        var k = String(t).toLowerCase()
        if (k === "i") cardwire.setMode("integrated")
        else if (k === "h") cardwire.setMode("hybrid")
        else if (k === "s") cardwire.setMode("smart")
        else if (k === "r") cardwire.refresh()
      }

      Flickable {
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height

        Column {
          id: column
          width: parent.width
          spacing: Style.space(8)

          Row {
            width: parent.width
            spacing: Style.space(8)
            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: "GPU"
              font.family: root.fontFamily
              font.pixelSize: Style.space(13)
              font.bold: true
              color: Color.foreground
            }
            Item { width: Math.max(0, column.width - Style.space(120)); height: 1 }
            PanelActionButton {
              anchors.verticalCenter: parent.verticalCenter
              iconText: root.refreshGlyph
              tooltipText: "Refresh"
              foreground: root.dim
              hoverColor: Color.foreground
              onClicked: cardwire.refresh()
            }
          }

          // ---- mode switch ----
          ButtonGroup {
            width: parent.width
            options: root.modeOptions
            value: String(cardwire.mode || "").toLowerCase()
            foreground: Color.foreground
            background: Color.background
            accent: Color.accent
            fontFamily: root.fontFamily
            focusable: false
            enabled: cardwire.available && !cardwire.busy
            opacity: enabled ? 1.0 : 0.5
            onChanged: function(value) { cardwire.setMode(value) }
          }

          Text {
            width: parent.width
            wrapMode: Text.WordWrap
            visible: !cardwire.available
            text: "cardwire is not responding.\n\nThis plugin drives the cardwire daemon, "
                + "which manages hybrid GPUs on Wayland. Install it and run "
                + "`systemctl enable --now cardwired`. On a machine with only one GPU "
                + "there is nothing here to control."
            textFormat: Text.PlainText
            font.family: root.fontFamily
            font.pixelSize: Style.space(11)
            color: root.dim
          }

          // Action failures are kept separate from read failures so the refresh
          // that follows a failed mode change cannot erase the reason.
          Text {
            width: parent.width
            wrapMode: Text.WordWrap
            visible: cardwire.actionError !== ""
            text: cardwire.actionError
            textFormat: Text.PlainText
            font.family: root.fontFamily
            font.pixelSize: Style.space(11)
            color: Color.urgent
          }

          PanelSeparator { width: parent.width; visible: cardwire.gpus.length > 0 }

          // ---- the cards ----
          Repeater {
            model: cardwire.gpus
            delegate: Column {
              required property var modelData
              width: column.width
              spacing: Style.space(1)

              Row {
                width: parent.width
                spacing: Style.space(6)
                Text {
                  width: parent.width - Style.space(130)
                  elide: Text.ElideRight
                  // Vendor-supplied string; AutoText would sniff it for markup.
                  text: root.nameOf(modelData)
                  textFormat: Text.PlainText
                  font.family: root.fontFamily
                  font.pixelSize: Style.space(11)
                  color: Color.foreground
                }
                Text {
                  text: root.statusOf(modelData)
                  textFormat: Text.PlainText
                  font.family: root.fontFamily
                  font.pixelSize: Style.space(11)
                  // Keyed off the mode, not the blocked flag: Smart reports
                  // blocked=true permanently, which would have made an awake
                  // card render as dim/parked.
                  color: (modelData.discrete && cardwire.discreteOffLimits) ? root.dim
                       : (modelData.discrete && cardwire.discreteAwake ? Color.urgent : Color.accent)
                }
              }

              Text {
                text: modelData.pci + "  ·  " + modelData.driver
                textFormat: Text.PlainText
                font.family: root.fontFamily
                font.pixelSize: Style.space(10)
                color: root.dim
              }
            }
          }

          PanelSeparator { width: parent.width }

          // ---- what is holding the discrete GPU open ----
          Text {
            text: cardwire.discreteAwake ? "Using the discrete GPU" : "Attached to the discrete GPU"
            font.family: root.fontFamily
            font.pixelSize: Style.space(11)
            font.bold: true
            color: Color.foreground
            visible: !!cardwire.discrete && !cardwire.discreteOffLimits
          }

          Text {
            width: parent.width
            wrapMode: Text.WordWrap
            visible: !!cardwire.discrete && !cardwire.discreteOffLimits
            // Process names come from the daemon, i.e. from whatever is running
            // on this machine. PlainText, not AutoText.
            text: root.renderingText()
            textFormat: Text.PlainText
            font.family: root.fontFamily
            font.pixelSize: Style.space(10)
            // Only accent it when the card is genuinely awake; in D3cold these
            // are open handles that are not costing anything, and colouring
            // them as active contradicted the D3cold shown just above.
            color: cardwire.discreteAwake ? Color.urgent : root.dim
          }

          Text {
            width: parent.width
            wrapMode: Text.WordWrap
            visible: !!cardwire.discrete && !cardwire.discreteOffLimits && root.holdingText() !== ""
            text: "Also attached: " + root.holdingText()
            textFormat: Text.PlainText
            font.family: root.fontFamily
            font.pixelSize: Style.space(10)
            color: root.dim
          }

          // ---- ASUS power: profile first, limits second ----
          PanelSeparator { width: parent.width; visible: armoury.available }

          Text {
            text: "Power profile"
            font.family: root.fontFamily
            font.pixelSize: Style.space(11)
            font.bold: true
            color: Color.foreground
            visible: armoury.available
          }

          ButtonGroup {
            width: parent.width
            visible: armoury.available
            options: root.profileOptions
            value: armoury.userAdjusted ? "custom" : armoury.profile
            foreground: Color.foreground
            background: Color.background
            accent: Color.accent
            fontFamily: root.fontFamily
            focusable: false
            // "custom" only appears once a limit was changed by hand, so
            // selecting it is inherently a no-op.
            onChanged: function(value) { if (value !== "custom") armoury.setProfile(value) }
          }

          Text {
            width: parent.width
            wrapMode: Text.WordWrap
            visible: armoury.available && armoury.autoSwitches
            text: "asusd switches profile automatically on AC and battery, so a "
                + "choice here lasts until the next plug or unplug."
            textFormat: Text.PlainText
            font.family: root.fontFamily
            font.pixelSize: Style.space(10)
            color: root.dim
          }

          Text {
            text: "Fine limits"
            font.family: root.fontFamily
            font.pixelSize: Style.space(11)
            font.bold: true
            color: Color.foreground
            visible: armoury.available
          }

          Text {
            width: parent.width
            wrapMode: Text.WordWrap
            visible: armoury.available && !armoury.limitsWritable
            text: "Read-only: this asusd is not applying limit changes. 6.3.8 has an "
                + "upstream getter/setter bug that makes property writes silently no-op; "
                + "it needs \u2265 6.4.0. The profile buttons above DO work \u2014 they apply "
                + "the tuning groups from /etc/asusd/asusd.ron."
            textFormat: Text.PlainText
            font.family: root.fontFamily
            font.pixelSize: Style.space(10)
            color: Color.urgent
          }

          Text {
            width: parent.width
            wrapMode: Text.WordWrap
            visible: armoury.available && cardwire.discreteOffLimits
            text: "GPU limits are inactive while the discrete GPU is blocked. They keep "
                + "their values and apply again in Hybrid."
            textFormat: Text.PlainText
            font.family: root.fontFamily
            font.pixelSize: Style.space(10)
            color: root.dim
          }

          Repeater {
            model: armoury.available ? armoury.attrNames : []
            delegate: Column {
              required property var modelData
              readonly property var attr: armoury.attrFor(modelData)
              // Dimmed, not hidden, while the card they describe is off the
              // table: the values persist and apply again in Hybrid.
              readonly property bool inert: armoury.isGpuAttr(modelData) && cardwire.discreteOffLimits
              width: column.width
              spacing: Style.space(2)
              visible: !!attr && attr.valid
              opacity: inert ? 0.5 : 1.0

              Row {
                width: parent.width
                spacing: Style.space(6)
                Text {
                  text: armoury.labelFor(modelData)
                  textFormat: Text.PlainText
                  font.family: root.fontFamily
                  font.pixelSize: Style.space(10)
                  color: root.dim
                }
                Item { width: Math.max(0, parent.width - Style.space(190)); height: 1 }
                Text {
                  text: attr && attr.valid ? (attr.current + armoury.unitFor(modelData)) : ""
                  textFormat: Text.PlainText
                  font.family: root.fontFamily
                  font.pixelSize: Style.space(10)
                  color: attr && attr.valid && attr.current !== attr.def ? Color.accent : root.dim
                }
              }

              Item {
                width: parent.width
                height: Style.space(18)
                PanelSlider {
                  anchors.fill: parent
                  bar: root.bar
                  enabled: armoury.limitsWritable
                  opacity: enabled ? 1.0 : 0.45
                  minimum: attr && attr.valid ? attr.min : 0
                  maximum: attr && attr.valid ? attr.max : 1
                  step: attr && attr.valid ? attr.step : 1
                  value: attr && attr.valid ? attr.current : 0
                  integer: true
                  // Write on release only; firing per drag pixel would hammer
                  // the firmware.
                  onReleased: function(v) { armoury.setValue(modelData, v) }
                }
              }
            }
          }

          Row {
            width: parent.width
            spacing: Style.space(6)
            visible: armoury.available && armoury.deviates
            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: "Reset limits (also clears the profile's saved group)"
              textFormat: Text.PlainText
              font.family: root.fontFamily
              font.pixelSize: Style.space(10)
              color: root.dim
            }
            PanelActionButton {
              anchors.verticalCenter: parent.verticalCenter
              iconText: root.refreshGlyph
              tooltipText: "Restore every limit to its firmware default. Note: asusd "
                            + "persists its tuning state, so this also overwrites the "
                            + "active profile's saved group in asusd.ron."
              foreground: root.dim
              hoverColor: Color.urgent
              onClicked: armoury.restoreAllDefaults()
            }
          }

          Text {
            width: parent.width
            wrapMode: Text.WordWrap
            visible: armoury.lastError !== ""
            text: armoury.lastError
            textFormat: Text.PlainText
            font.family: root.fontFamily
            font.pixelSize: Style.space(10)
            color: Color.urgent
          }

          PanelSeparator { width: parent.width }

          Text {
            width: parent.width
            wrapMode: Text.WordWrap
            text: "i  integrated    h  hybrid    s  smart    r  refresh"
            font.family: root.fontFamily
            font.pixelSize: Style.space(10)
            color: root.dim
          }
        }
      }
    }
  }

  function nameOf(g) {
    return g && g.name ? String(g.name) : "(unknown GPU)"
  }

  // "display" is only true of the card actually driving the screen. Labelling
  // every non-discrete GPU that way would mislabel a second unused iGPU.
  function statusOf(g) {
    if (!g) return ""
    if (g.discrete && cardwire.discreteOnDemand) return "on demand"
    if (g.blocked) return "blocked"
    if (g.discrete) return cardwire.discretePowerState
    if (g["default"]) return "display"
    return "idle"
  }

  // cardwire's Lsof returns { device-node: [process, ...] }, and the node
  // matters: holders of /dev/dri/card* are mostly session bookkeeping (systemd,
  // logind) that would be there regardless, while holders of the render node
  // and /dev/nvidia* are the ones actually doing GPU work and keeping the card
  // out of D3cold. Flattening them together buries the signal in the noise.
  function splitHolders() {
    var rendering = {}, holding = {}
    var h = cardwire.holders || ({})
    for (var node in h) {
      if (!h.hasOwnProperty(node)) continue
      // nvidiactl is the control node, not a rendering one: a process holding
      // only it is not doing GPU work.
      var isRender = node.indexOf("render") >= 0
                     || (node.indexOf("/dev/nvidia") === 0 && node.indexOf("nvidiactl") < 0)
      var target = isRender ? rendering : holding
      var procs = h[node] || []
      for (var i = 0; i < procs.length; i++) {
        var pn = String(procs[i])
        if (pn === "cardwired") continue   // the daemon reporting itself
        target[pn] = true
      }
    }
    // A process doing real work should not also be listed as a bystander.
    for (var r in rendering) if (holding[r]) delete holding[r]
    return { rendering: Object.keys(rendering).sort(),
             holding: Object.keys(holding).sort() }
  }

  function renderingText() {
    var n = root.splitHolders().rendering
    return n.length === 0 ? "Nothing \u2014 the card is free to stay parked." : n.join(", ")
  }

  function holdingText() {
    var n = root.splitHolders().holding
    return n.length === 0 ? "" : n.join(", ")
  }

}
