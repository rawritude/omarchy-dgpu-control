import QtQuick
import Quickshell.Io

// ASUS platform profile + firmware power envelope.
//
// Two layers, deliberately distinct because they behave differently:
//
//  * The platform profile (Quiet / Balanced / Performance) works today. It is
//    the same knob as /sys/firmware/acpi/platform_profile, which
//    power-profiles-daemon also drives, and asusd already switches it
//    automatically — Performance on AC, Quiet on battery.
//
//  * The individual power limits are gated behind asusd's per-profile
//    "tunings", which ship disabled. With them off asusd accepts the write,
//    updates its own D-Bus property, and never touches the firmware.
//
// Everything is READ from sysfs via FileView: native, watchable, no subprocess,
// and — unlike asusd's D-Bus properties — actually true. Writes go through
// asusctl/asusd because they need privilege we do not have.
Item {
  id: svc

  property bool detailWanted: false
  property string lastError: ""

  readonly property var attrNames: [
    "nv_tgp", "nv_dynamic_boost", "nv_temp_target", "ppt_pl1_spl", "ppt_pl2_sppt"
  ]

  readonly property var labels: ({
    "nv_tgp":           "GPU power (TGP)",
    "nv_dynamic_boost": "Dynamic boost",
    "nv_temp_target":   "GPU temp target",
    "ppt_pl1_spl":      "CPU sustained",
    "ppt_pl2_sppt":     "CPU burst"
  })

  readonly property var units: ({ "nv_temp_target": "°C" })

  // Which limits describe the discrete GPU rather than the CPU. When cardwire
  // blocks the dGPU these stay readable and keep their values — they live under
  // /sys/class/firmware-attributes, not the PCI device that gets hidden — but
  // they govern nothing until the card comes back.
  readonly property var gpuAttrs: ["nv_tgp", "nv_dynamic_boost", "nv_temp_target"]
  function isGpuAttr(n) { return gpuAttrs.indexOf(n) >= 0 }

  function unitFor(n) { return units[n] !== undefined ? units[n] : " W" }
  function labelFor(n) { return labels[n] !== undefined ? labels[n] : n }

  // ---- attributes (sysfs-backed) --------------------------------------
  property var attrItems: ({})

  ArmouryAttr { id: aTgp;    name: "nv_tgp" }
  ArmouryAttr { id: aBoost;  name: "nv_dynamic_boost" }
  ArmouryAttr { id: aTemp;   name: "nv_temp_target" }
  ArmouryAttr { id: aPl1;    name: "ppt_pl1_spl" }
  ArmouryAttr { id: aPl2;    name: "ppt_pl2_sppt" }

  Component.onCompleted: attrItems = {
    "nv_tgp": aTgp, "nv_dynamic_boost": aBoost, "nv_temp_target": aTemp,
    "ppt_pl1_spl": aPl1, "ppt_pl2_sppt": aPl2
  }

  function attrFor(name) { return attrItems[name] || null }

  readonly property bool available:
    aTgp.valid || aBoost.valid || aTemp.valid || aPl1.valid || aPl2.valid

  // "Custom" must mean *you* moved a slider, not merely that the current values
  // differ from firmware defaults — a profile's own tuning group legitimately
  // sets non-default values, so comparing against defaults would label a stock
  // Quiet profile as Custom. Tracked explicitly instead, and cleared whenever a
  // profile is selected, since that re-applies the profile's group.
  property bool userAdjusted: false

  // Kept for display: shows which individual limits are off their default.
  readonly property bool deviates:
    (aTgp.valid   && aTgp.current   !== aTgp.def) ||
    (aBoost.valid && aBoost.current !== aBoost.def) ||
    (aTemp.valid  && aTemp.current  !== aTemp.def) ||
    (aPl1.valid   && aPl1.current   !== aPl1.def) ||
    (aPl2.valid   && aPl2.current   !== aPl2.def)

  // ---- platform profile ------------------------------------------------
  property string profile: ""
  readonly property var profileNames: ["quiet", "balanced", "performance"]

  FileView {
    path: "/sys/firmware/acpi/platform_profile"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: svc.profile = String(text() || "").trim().toLowerCase()
    onLoadFailed: svc.profile = ""
  }

  // asusd can be configured to force a profile on AC and another on battery.
  // When it is, a profile chosen here survives only until the next plug or
  // unplug — worth saying, rather than letting the buttons appear to forget.
  property bool autoSwitches: false
  Process {
    id: autoSwitchProc
    running: true
    command: ["sh", "-c",
      "grep -c 'change_platform_profile_on_\\(ac\\|battery\\): true' /etc/asusd/asusd.ron 2>/dev/null || echo 0"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: svc.autoSwitches = (parseInt(String(text || "0").trim(), 10) || 0) > 0
    }
  }

  function setProfile(p) {
    if (profileProc.running) return
    var name = String(p)
    // asusctl expects the capitalised form.
    var pretty = name.charAt(0).toUpperCase() + name.slice(1)
    userAdjusted = false
    profileProc.command = ["asusctl", "profile", "set", pretty]
    profileProc.running = true
  }

  Process {
    id: profileProc
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var t = String(text || "").trim()
        if (t !== "") svc.lastError = t
      }
    }
  }

  // ---- power-limit writes ---------------------------------------------
  //
  // asusd reports success whether or not it applied the value, so the only
  // honest check is to look at sysfs afterwards and see whether it moved.
  //
  // Writes go through a queue rather than firing directly. `running = true` on
  // a busy Process is a silent no-op in Quickshell, so the previous design —
  // a fixed 250ms timer chain calling restoreDefault() — dropped any attribute
  // whose busctl round trip ran long, advancing the index anyway, with no retry
  // and no feedback. The queue is pumped by the process's own exit instead, so
  // it cannot outrun the daemon regardless of how slow a firmware write is.
  property bool writesIgnored: false
  property var _queue: []      // [{name, value, isRestore}]
  property var _expect: []     // same shape; checked once the queue drains

  readonly property bool writing: writeProc.running || _queue.length > 0

  function _enqueue(item) {
    var q = _queue.slice()
    q.push(item)
    _queue = q
    _pump()
  }

  function _pump() {
    if (writeProc.running || _queue.length === 0) return
    var q = _queue.slice()
    var item = q.shift()
    _queue = q

    var e = _expect.slice(); e.push(item); _expect = e

    if (item.isRestore) {
      writeProc.command = ["busctl", "--system", "call", "xyz.ljones.Asusd",
                           "/xyz/ljones/asus_armoury/" + item.name,
                           "xyz.ljones.AsusArmoury", "RestoreDefault"]
    } else {
      writeProc.command = ["busctl", "--system", "set-property", "xyz.ljones.Asusd",
                           "/xyz/ljones/asus_armoury/" + item.name,
                           "xyz.ljones.AsusArmoury", "CurrentValue", "i", String(item.value)]
    }
    writeProc.running = true
  }

  function setValue(name, value) {
    var a = attrFor(name)
    if (!a || !a.valid) return
    _enqueue({ name: name,
               value: Math.round(Math.max(a.min, Math.min(a.max, value))),
               isRestore: false })
  }

  function restoreDefault(name) {
    var a = attrFor(name)
    if (!a || !a.valid) return
    _enqueue({ name: name, value: a.def, isRestore: true })
  }

  // Every attribute in one batch; the queue serialises them properly, so no
  // spacing timer is needed and nothing is dropped.
  function restoreAllDefaults() {
    for (var i = 0; i < attrNames.length; i++) restoreDefault(attrNames[i])
  }

  Process {
    id: writeProc
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var t = String(text || "").trim()
        if (t !== "") svc.lastError = t
      }
    }
    onExited: function(code) {
      if (code !== 0) svc.lastError = "busctl exited " + code
      if (svc._queue.length > 0) { Qt.callLater(svc._pump); return }
      // Whole batch issued; give the firmware a moment, then check all of it.
      verify.restart()
    }
  }

  Timer {
    id: verify
    interval: 1200
    repeat: false
    onTriggered: {
      var anyIgnored = false, anyAdjusted = false
      for (var i = 0; i < svc._expect.length; i++) {
        var it = svc._expect[i]
        var a = svc.attrFor(it.name)
        if (!a || !a.valid) continue
        if (a.current !== it.value) anyIgnored = true
        else if (!it.isRestore) anyAdjusted = true
      }
      // Not sticky: a write that lands clears the flag, so enabling tunings
      // later un-greys the sliders without needing a shell reload.
      if (svc._expect.length > 0) svc.writesIgnored = anyIgnored
      if (anyAdjusted) svc.userAdjusted = true
      svc._expect = []
    }
  }

  // asusd.ron is world-readable, so the gate can be reported before the user
  // discovers it by dragging a slider that springs back.
  property bool tuningEnabled: true
  function checkTuning() { if (!cfgProc.running) cfgProc.running = true }
  Process {
    id: cfgProc
    running: true
    command: ["sh", "-c", "grep -c 'enabled: true' /etc/asusd/asusd.ron 2>/dev/null || echo 0"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: svc.tuningEnabled = (parseInt(String(text || "0").trim(), 10) || 0) > 0
    }
  }

  readonly property bool limitsWritable: tuningEnabled && !writesIgnored

  // Re-read the gate whenever the panel opens: enabling a profile tuning in
  // asusd.ron is a config edit made outside this process, and a one-shot check
  // at shell start would keep reporting read-only until the next reload.
  onDetailWantedChanged: if (detailWanted) checkTuning()
}
