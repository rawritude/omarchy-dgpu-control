import QtQuick
import Quickshell.Io

// One asus-armoury firmware attribute, read from sysfs.
//
// Deliberately NOT read over D-Bus. asusd gates PPT/power writes behind
// per-profile "tunings" that ship disabled; with them off it accepts the D-Bus
// call, updates its own CurrentValue property, logs
// "Tuning is disabled: skipping setting value to PPT property", and never
// touches the firmware. The D-Bus property therefore reports what was
// *requested*, not what the hardware has — verified live, where D-Bus claimed
// 70 W while sysfs (and the GPU) were still at 85 W.
//
// sysfs is the truth, it is world-readable, and FileView reads it natively —
// so this costs no subprocess at all, where the D-Bus route cost one busctl
// spawn per attribute per refresh.
Item {
  id: attr

  property string name: ""
  readonly property string base: "/sys/class/firmware-attributes/asus-armoury/attributes/" + name

  property int current: -1
  property int min: -1
  property int max: -1
  property int def: -1
  property int step: 1

  // Usable as a slider only when the range is real. asusd uses -1 for
  // "not applicable", and read-only attributes have no min/max at all.
  readonly property bool valid: current >= 0 && min >= 0 && max > min

  signal changed()

  function toInt(t, fallback) {
    var n = parseInt(String(t || "").trim(), 10)
    return isFinite(n) ? n : fallback
  }

  // current_value is the one that moves, so it is the only one watched.
  FileView {
    path: attr.base + "/current_value"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: { attr.current = attr.toInt(text(), -1); attr.changed() }
    onLoadFailed: attr.current = -1
  }

  FileView {
    path: attr.base + "/min_value"
    printErrors: false
    onLoaded: attr.min = attr.toInt(text(), -1)
    onLoadFailed: attr.min = -1
  }

  FileView {
    path: attr.base + "/max_value"
    printErrors: false
    onLoaded: attr.max = attr.toInt(text(), -1)
    onLoadFailed: attr.max = -1
  }

  FileView {
    path: attr.base + "/default_value"
    printErrors: false
    onLoaded: attr.def = attr.toInt(text(), -1)
    onLoadFailed: attr.def = -1
  }

  FileView {
    path: attr.base + "/scalar_increment"
    printErrors: false
    onLoaded: attr.step = Math.max(1, attr.toInt(text(), 1))
    onLoadFailed: attr.step = 1
  }
}
