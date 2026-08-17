import QtQuick
import Quickshell.Io
import Quickshell.Services.UPower

// ASUS platform profile + firmware power envelope.
//
// Two layers, deliberately distinct because they behave differently:
//
//  * The platform profile (Quiet / Balanced / Performance) works today. It is
//    the same knob as /sys/firmware/acpi/platform_profile, which
//    power-profiles-daemon also drives, and asusd already switches it
//    automatically — Performance on AC, Quiet on battery.
//
//  * The individual power limits are gated behind asusd's "tunings". With the
//    gate shut asusd accepts the write, updates its own D-Bus property, and
//    never touches the firmware.
//
//    The gate is per (power source, profile), NOT global: asusd keeps a
//    separate group for each cell of ac/dc × Quiet/Balanced/Performance and
//    consults only the one matching the moment. Verified on a GA403WM, where
//    the identical write landed under AC+Quiet and was dropped under
//    AC+Performance. A stock config ships every dc_ group disabled, so on
//    battery nothing is tunable at all — which is where lowering TGP would
//    actually buy runtime.
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

  // ---- the tuning gate --------------------------------------------------
  //
  // asusd.ron is world-readable, so the gate is read directly rather than
  // shelled out for. This replaced `grep -c 'enabled: true' asusd.ron`, which
  // asked a global question about a per-cell setting: one enabled group
  // anywhere in the file reported every profile as writable, so the sliders
  // rendered live on profiles that would silently discard the write.
  property string configText: ""

  FileView {
    path: "/etc/asusd/asusd.ron"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: svc.configText = String(text() || "")
    onLoadFailed: svc.configText = ""
  }

  // asusd forces a profile per power source, so which cell applies changes
  // under you when you plug in. UPower reports that without a poll.
  readonly property bool onAc: !UPower.onBattery
  readonly property string tuningSection: onAc ? "ac_profile_tunings" : "dc_profile_tunings"
  readonly property string prettyProfile:
    profile === "" ? "" : profile.charAt(0).toUpperCase() + profile.slice(1)

  // Indentation-keyed, not brace-matched: each profile block holds a nested
  // `group: { ... }` whose closing brace makes a brace-counting walk leave the
  // section one line early and read the wrong cell.
  function gateFor(section, prettyName) {
    if (configText === "" || prettyName === "") return null
    var lines = configText.split("\n")
    var inSec = false, secIndent = -1, inProf = false, profIndent = -1

    for (var i = 0; i < lines.length; i++) {
      var line = lines[i], stripped = line.trim()
      if (stripped === "") continue
      var indent = line.length - line.replace(/^\s+/, "").length

      if (!inSec) {
        if (stripped.indexOf(section + ":") === 0) { inSec = true; secIndent = indent }
        continue
      }
      if (!inProf) {
        if (indent <= secIndent && stripped.charAt(0) !== "(" && stripped.charAt(0) !== "{") {
          inSec = false; continue          // section ended without this profile
        }
        if (stripped.indexOf(prettyName + ":") === 0) { inProf = true; profIndent = indent }
        continue
      }
      if (indent <= profIndent) return null // profile block held no enabled key
      var m = stripped.match(/^enabled\s*:\s*(true|false)/)
      if (m) return m[1] === "true"
    }
    return null
  }

  // null means the cell is absent from the config, which asusd treats as off.
  readonly property bool tuningEnabled: gateFor(tuningSection, prettyProfile) === true
  readonly property bool limitsWritable: tuningEnabled && !writesIgnored

  // ---- opening the gate -------------------------------------------------
  //
  // Needs root, so it goes through a helper rather than being attempted here.
  // The helper seeds the group from the values the firmware is running right
  // now, so opening the gate does not itself change the machine — asusd's
  // shipped Performance group carries a PptPl1Spl well under what the hardware
  // actually runs at, and applying it verbatim would quietly cost power.
  property bool helperPresent: false
  readonly property bool enablingTuning: enableProc.running

  FileView {
    path: "/usr/local/bin/asusd-tuning"
    printErrors: false
    onLoaded: svc.helperPresent = true
    onLoadFailed: svc.helperPresent = false
  }

  function enableTuning() {
    if (enableProc.running || !helperPresent) return
    lastError = ""
    enableProc.command = ["pkexec", "/usr/local/bin/asusd-tuning", "enable"]
    enableProc.running = true
  }

  Process {
    id: enableProc
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var t = String(text || "").trim()
        if (t !== "") svc.lastError = t
      }
    }
    onExited: function(code) {
      // 126 is polkit's "dismissed or not authorised", which is a choice
      // rather than a fault and should not be reported as an error.
      if (code === 126) svc.lastError = ""
      else if (code !== 0 && svc.lastError === "") svc.lastError = "could not enable tuning"
      // asusd is restarted by the helper, so a write refused a moment ago may
      // now land; let the next attempt decide rather than staying latched.
      svc.writesIgnored = false
    }
  }
}
