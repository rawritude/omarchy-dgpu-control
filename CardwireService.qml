import QtQuick
import Quickshell.Io

// Talks to the cardwire daemon.
//
// Quickshell has no generic D-Bus client (Quickshell.Services covers UPower,
// Mpris, Pipewire, Polkit and friends, but not arbitrary buses), so this shells
// out. Two deliberate differences from how other plugins do that:
//
//  1. Everything is read as JSON — `cardwire list --json` and
//     `busctl --json=short` — and parsed with JSON.parse. No scraping of
//     human-formatted table or gdbus output, which breaks the moment upstream
//     adjusts a column.
//
//  2. Output is captured with StdioCollector. No temp files. A widely-copied
//     ASUS plugin writes daemon output to fixed paths in shared /tmp
//     (/tmp/am-aura.txt and friends); a shell redirect follows symlinks, so any
//     other local uid that pre-creates that path gets an arbitrary write as you.
//
// Nothing here wakes the discrete GPU. cardwire's PowerState() reports the real
// PCI D-state without touching the device, unlike nvidia-smi or lspci, both of
// which resume a runtime-suspended card just by being run.
Item {
  id: svc

  // Safety net only. State changes arrive as D-Bus signals, so this exists to
  // recover from a missed signal, not to discover changes.
  property int fallbackPollMs: 300000
  // While the panel is open we do poll, because the one thing with no signal
  // behind it is the process list: a program opening or closing the GPU emits
  // nothing on the bus.
  property int activePollMs: 3000

  // True while the panel is visible: fetches the per-GPU process list too.
  property bool detailWanted: false

  // ---- observed state -------------------------------------------------
  property bool available: false          // is the daemon reachable at all
  property string mode: ""                // Integrated | Hybrid | Smart | Manual
  property var gpus: []                   // parsed `cardwire list --json`
  property string discretePowerState: ""  // e.g. "D3cold", "D0"
  property var holders: ({})              // node -> [process names]

  // Two distinct error channels. `lastError` describes the read path and is
  // cleared whenever a read succeeds; `actionError` describes a user-initiated
  // mode change and must NOT be cleared by the refresh that follows it —
  // otherwise a failed `cardwire set` flashes for one process round-trip and
  // vanishes before it can be read.
  property string lastError: ""
  property string actionError: ""

  readonly property bool busy: actionProc.running

  readonly property var discrete: {
    for (var i = 0; i < gpus.length; i++) if (gpus[i].discrete) return gpus[i]
    return null
  }
  readonly property bool discreteBlocked: discrete ? !!discrete.blocked : false

  readonly property string modeLower: String(mode || "").toLowerCase()

  // Smart reports blocked=true because it blocks by DEFAULT, then punches
  // per-process holes through eBPF as applications are approved. So the card is
  // genuinely in use there, unlike Integrated where it is off the table
  // entirely. Anything reasoning about "is the dGPU actually usable" must key
  // off the mode, not off the blocked flag.
  readonly property bool discreteOffLimits: modeLower === "integrated"
  readonly property bool discreteOnDemand: modeLower === "smart"

  // D3cold is the parked state we want. Anything else means something has the
  // card open and it is drawing power.
  readonly property bool discreteAwake:
    discretePowerState !== "" && discretePowerState.indexOf("D3") !== 0

  // Clamped: a hand-edited shell.json can carry any number, and a 10ms cadence
  // inside the shared shell process would be pathological.
  readonly property int pollInterval: Math.max(500,
    Math.min(3600000, detailWanted ? activePollMs : fallbackPollMs))

  // Serialised JSON of the last accepted payloads. `var` assignment always
  // signals even when the value is identical, and svc.gpus feeds a Repeater —
  // reassigning every poll would destroy and rebuild every delegate on a timer,
  // forever, inside a long-lived shell process.
  property string _gpusJson: ""
  property string _holdersJson: ""

  signal refreshed()

  function setGpus(list) {
    var j = JSON.stringify(list)
    if (j === _gpusJson) return
    _gpusJson = j
    gpus = list
  }

  function setHolders(obj) {
    var j = JSON.stringify(obj)
    if (j === _holdersJson) return
    _holdersJson = j
    holders = obj
  }

  function markUnavailable() {
    available = false
    setGpus([])
    setHolders({})
    discretePowerState = ""
    refreshed()
  }

  // Build a busctl argv for a method on the discrete GPU's object. The id comes
  // from the list we already parsed — rediscovering it per call by shelling out
  // to `cardwire list` and python3 would cost three processes per poll for data
  // already in memory. The id is a busctl argument, never shell input.
  function gpuCall(method) {
    var id = svc.discrete ? svc.discrete.id : -1
    if (id < 0) return null
    return ["busctl", "--system", "--json=short", "call",
            "org.opengamingcollective.cardwire",
            "/org/opengamingcollective/cardwire/Gpu/" + id,
            "org.opengamingcollective.cardwire.Gpu", method]
  }

  // ---- reads ----------------------------------------------------------
  function refresh() {
    listProc.running = true
    // Always, not just when the panel is open: the mode decides what the BAR
    // label says (off / auto / power state), so gating this on detailWanted
    // would leave the bar stale after a mode change made from elsewhere.
    // Refreshes are signal-driven, so this is not a per-tick cost.
    modeProc.running = true
  }

  Process {
    id: listProc
    command: ["cardwire", "list", "--json"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "")
        // Empty stdout means the CLI failed (verified: with the bus
        // unreachable it prints nothing and exits 1). Defaulting that to "{}"
        // would parse cleanly into a cheerful "no GPUs, daemon fine" state.
        if (raw.trim() === "") { svc.markUnavailable(); return }
        try {
          var obj = JSON.parse(raw)
          var out = []
          // Keyed by index ("0", "1", ...) rather than an array.
          for (var k in obj) if (obj.hasOwnProperty(k)) out.push(obj[k])
          out.sort(function(a, b) { return (a.id | 0) - (b.id | 0) })
          svc.setGpus(out)
          svc.available = true
          svc.lastError = ""
          // Chained off the list because both need the discrete GPU's id, which
          // only exists once the list has been parsed.
          var pc = svc.gpuCall("PowerState")
          if (pc) { powerProc.command = pc; powerProc.running = true }
          else svc.discretePowerState = ""
          if (svc.detailWanted) {
            var lc = svc.gpuCall("Lsof")
            if (lc) { lsofProc.command = lc; lsofProc.running = true }
          }
          svc.refreshed()
        } catch (e) {
          svc.markUnavailable()
        }
      }
    }
    onExited: function(code) {
      // A completed read means nothing is hung; disarm so the watchdog is only
      // ever counting against work actually in flight.
      watchdog.stop()
      if (code !== 0) svc.markUnavailable()
    }
  }

  Process {
    id: modeProc
    command: ["cardwire", "get"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        // "Current Mode: Hybrid\nAvailable Mode: ..."
        var m = String(text || "").match(/Current Mode:\s*(\w+)/)
        if (m) svc.mode = m[1]
      }
    }
  }

  Process {
    id: powerProc
    // Method call rather than a sysfs read: when a GPU is blocked, cardwire
    // makes its whole /sys/bus/pci/devices/<addr> path return -ENOENT, so a
    // sysfs reader sees "file missing" and cannot tell blocked from broken.
    // The daemon always knows, and answering does not resume the device.
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var r = JSON.parse(String(text || "{}"))
          var v = (r.data && r.data[0]) ? String(r.data[0]) : ""
          // The daemon really does return "D3cold\n"; without trimming, every
          // state comparison below is wrong.
          // Constrained to a safe charset rather than merely trimmed: this
          // value reaches the bar through WidgetButton's internal Text, which
          // sets no textFormat and therefore defaults to AutoText. It is the
          // only external string in the plugin not rendered as PlainText.
          svc.discretePowerState = v.replace(/[^A-Za-z0-9 ._-]/g, "").trim()
          svc.refreshed()
        } catch (e) { /* keep the previous reading */ }
      }
    }
  }

  Process {
    id: lsofProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var r = JSON.parse(String(text || "{}"))
          svc.setHolders((r.data && r.data[0]) ? r.data[0] : ({}))
          svc.refreshed()
        } catch (e) { svc.setHolders({}) }
      }
    }
  }

  // ---- actions --------------------------------------------------------
  function setMode(m) {
    // Setting `running = true` on an already-running Process is a silent no-op
    // in Quickshell, so without this guard a second mode change inside one
    // round-trip would be dropped with no feedback at all.
    if (actionProc.running) return
    actionError = ""
    actionProc.command = ["cardwire", "set", String(m)]
    actionProc.running = true
  }

  Process {
    id: actionProc
    onRunningChanged: if (running) actionTimeout.restart(); else actionTimeout.stop()
    onExited: function(code) {
      // A non-zero exit with nothing on stderr would otherwise fail silently:
      // the ButtonGroup snaps back to the old mode with no explanation.
      if (code !== 0 && svc.actionError === "")
        svc.actionError = "cardwire set failed (exit " + code + ")"
      Qt.callLater(svc.refresh)
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var t = String(text || "").trim()
        if (t !== "") svc.actionError = t
      }
    }
  }

  // Without this, a hung `cardwire set` leaves busy=true forever: the mode
  // buttons stay disabled and every later setMode() returns silently, until the
  // whole shell is restarted.
  Timer {
    id: actionTimeout
    interval: 15000
    repeat: false
    onTriggered: if (actionProc.running) {
      actionProc.running = false
      svc.actionError = "cardwire set timed out"
    }
  }

  onDetailWantedChanged: if (detailWanted) refresh()

  // ---- event-driven updates -------------------------------------------
  //
  // cardwire emits PropertiesChanged (Mode, per-GPU Block) and
  // PowerStateChanged, so there is no reason to ask repeatedly. One monitor
  // process sits blocked on a socket costing nothing, and the widget reacts
  // only when something actually changes.
  //
  // This is a power decision as much as a tidiness one. A 15s poll was ~480
  // process spawns an hour, each one a fork+exec of a Rust binary plus a busctl
  // round trip, and each one logged by the daemon at INFO — measured at ~1.5 MB
  // of journal per hour, which is disk writes and journald wakeups on battery.
  // Periodic timers also keep pulling the CPU out of deep idle states; a
  // blocked read does not.
  //
  // `busctl monitor` would need BecomeMonitor (root); gdbus uses ordinary
  // match rules, which the daemon's D-Bus policy already grants to `wheel`.
  Process {
    id: monitorProc
    running: true
    command: ["gdbus", "monitor", "--system",
              "--dest", "org.opengamingcollective.cardwire"]
    stdout: SplitParser {
      onRead: function(line) {
        var l = String(line)
        // NameOwnerChanged/InterfacesAdded carry neither of the property
        // signal names, so without matching the bus name too, a daemon restart
        // left the widget showing "not responding" until the 5-minute fallback.
        if (l.indexOf("PropertiesChanged") >= 0 || l.indexOf("PowerStateChanged") >= 0
            || l.indexOf("opengamingcollective") >= 0)
          debounce.restart()
      }
    }
    // If the monitor dies (bus restart, daemon replaced), come back rather than
    // going permanently deaf and silently falling back to the 5-minute poll.
    onRunningChanged: if (running) respawnSettled.restart(); else respawnSettled.stop()
    onExited: respawn.restart()
  }

  // Backoff matters here: without it, a monitor that fails instantly (system
  // bus down, gdbus missing) respawns every 5s indefinitely — ~720 spawns an
  // hour, worse than the polling this whole design replaced. Doubles to a
  // 5-minute ceiling and resets once a monitor survives a while.
  property int _respawnMs: 5000
  Timer {
    id: respawn
    interval: svc._respawnMs
    repeat: false
    onTriggered: {
      svc._respawnMs = Math.min(300000, svc._respawnMs * 2)
      if (!monitorProc.running) monitorProc.running = true
    }
  }

  Timer {
    id: respawnSettled
    interval: 60000
    repeat: false
    onTriggered: svc._respawnMs = 5000   // it stayed up; forget the backoff
  }

  // One mode change produced nine signals in testing; coalesce the burst into a
  // single refresh instead of nine.
  Timer {
    id: debounce
    interval: 300
    repeat: false
    onTriggered: svc.refresh()
  }

  Timer {
    id: poll
    interval: svc.pollInterval
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: {
      // Arm the watchdog only when it is not already counting. Restarting it on
      // every tick pushed its deadline out ahead of a hung process forever,
      // which made it dead code — the exact trap the first-party tailscale
      // service documents at Service.qml:188.
      // every later tick sets `running = true` on a running Process, which is a
      // no-op, and the widget freezes on stale data until the shell restarts.
      // The first-party tailscale service carries the same watchdog.
      if (!watchdog.running) watchdog.start()
      svc.refresh()
    }
  }

  Timer {
    id: watchdog
    interval: Math.max(4000, svc.pollInterval * 2)
    repeat: false
    onTriggered: {
      var stuck = false
      if (listProc.running)  { listProc.running = false;  stuck = true }
      if (modeProc.running)  { modeProc.running = false;  stuck = true }
      if (powerProc.running) { powerProc.running = false; stuck = true }
      if (lsofProc.running)  { lsofProc.running = false;  stuck = true }
      if (stuck) svc.markUnavailable()
    }
  }
}
