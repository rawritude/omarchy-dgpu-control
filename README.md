# dGPU Control — discrete GPU control for the Omarchy bar

Control the discrete GPU on a dual-GPU machine, see its **real PCI power state**, and — the
reason this exists — find out **which processes are keeping it awake**.

On ASUS ROG hardware it also exposes the platform profile and the firmware power envelope.

![The dGPU Control panel](preview.png)

## Is this for you?

This plugin is for machines with **two GPUs** — typically a laptop whose integrated GPU drives the
display alongside a discrete card used for offload. It is **vendor-neutral**: cardwire classifies
GPUs by generic PCI properties, so an AMD, Intel or NVIDIA discrete card all work.

It is **not** ASUS-specific. The ASUS section is an optional extra that hides itself entirely on
other hardware.

| Requirement | Why |
|---|---|
| **Two GPUs** | An integrated GPU plus a discrete one. On a single-GPU machine there is nothing to control |
| **[cardwire](https://github.com/OpenGamingCollective/cardwire)** daemon | Does the actual GPU management; this is a front-end for it |
| **Wayland** | cardwire does not support X11 |
| Kernel with `CONFIG_BPF_LSM` | cardwire blocks GPUs with eBPF LSM hooks |
| *(optional)* **asusd** from [asusctl](https://asus-linux.org) | Adds the ASUS power-profile and limits section |

The ASUS section **hides itself completely** when asusd is absent, so the plugin is useful on any
hybrid laptop — you simply get the mode switching and power-state half.

Developed and tested on an **ASUS ROG Zephyrus G14 (GA403WM, 2025)** — Radeon 890M driving the
display, RTX 5060 as offload — on Omarchy 4 / Arch.

## Installing cardwire on Arch

**The AUR `cardwire` package currently cannot build on Arch.** Not a packaging mistake on the
maintainer's part — an LLVM version mismatch:

- The eBPF crate is compiled by a pinned Rust nightly whose LLVM emits current-trunk bitcode.
- `bpf-linker` then has to lower that bitcode, and Arch's `bpf-linker` links against the distro
  `llvm-libs`, which is a release behind.
- The result is `A call to built-in function 'memset' is not supported`, or with a newer nightly,
  `LLVM ERROR: Invalid record`.

Upstream documents this in `crates/cardwire-ebpf-userspace/build.rs`: *"Distro bpf-linkers linked
against a stable llvm cannot lower trunk bitcode no matter which nightly is pinned here."*
Building `bpf-linker` yourself does not help, because `cargo install` picks up the same system
LLVM.

**Use upstream's prebuilt Arch package instead** — they publish one with every release:

```bash
gh release download --repo OpenGamingCollective/cardwire \
  --pattern 'cardwire-*-x86_64.pkg.tar.zst'
sudo pacman -U cardwire-*-x86_64.pkg.tar.zst
sudo systemctl enable --now cardwired
```

(Or download the `.pkg.tar.zst` from the [releases page](https://github.com/OpenGamingCollective/cardwire/releases) by hand.)

Worth knowing before you enable it at boot: cardwire's `AutoApplyGpuState` defaults to **true**,
which re-applies the last saved mode when the daemon starts — before you have a session to
correct it from. Consider turning it off:

```bash
busctl --system set-property org.opengamingcollective.cardwire \
  /org/opengamingcollective/cardwire \
  org.opengamingcollective.cardwire.Config AutoApplyGpuState b false
```

## Installing the plugin

```bash
omarchy plugin add https://github.com/rawritude/omarchy-dgpu-control.git --enable
omarchy bar move io.github.rawritude.dgpu-control --section right
```

Plugins land disabled unless you pass `--enable`, so you can read the code first.

## Removing it

```bash
omarchy plugin remove io.github.rawritude.dgpu-control
```

That takes the widget out of your bar and deletes the plugin. cardwire and asusd are
independent system daemons this plugin only reads and commands, so they keep running
exactly as before.

If you installed the optional tuning helper, remove its two files as well — they are
the only things this plugin puts outside its own directory:

```bash
sudo ~/.config/omarchy/plugins/io.github.rawritude.dgpu-control/contrib/install.sh --uninstall
```

That deletes `/usr/local/bin/asusd-tuning` and its polkit action. Any tuning gate you
opened in `/etc/asusd/asusd.ron` is deliberately left alone: closing it would change
how the machine runs as a side effect of removing a widget. Run `asusd-tuning disable`
first if you want it closed.

If you also want cardwire gone:

```bash
sudo systemctl disable --now cardwired
sudo pacman -R cardwire
sudo rm -rf /etc/cardwire /var/lib/cardwire   # not owned by the package
```

## Usage

**Bar:** the icon shows the discrete GPU's state in one word — `on` when the card is awake, `off`
when blocked, `auto` when it is parked in Smart mode, and nothing at all when it is parked in
Hybrid. It highlights when the card is out of a low-power state, which is the "something woke my
dGPU" signal. Click to open the panel; the exact PCI D-state is shown there, beside the card's PCI
address.

Seeing `on` for the first half-minute after login is normal — the session brings the card up as it
starts, and it drops back to `D3cold` roughly 20 seconds after the last thing lets go of it.

**Modes:**

- **Integrated** — the dGPU is blocked outright. Lowest power.
- **Hybrid** — both GPUs available; the dGPU parks itself when idle.
- **Smart** — blocked by default, with per-process exceptions. cardwire watches every `exec` and
  allows processes carrying `CARDWIRE_ALLOW=1`, `CARDWIRE_FORCE_DGPU=1`, or a `SteamAppId`.

To give a program access under Smart, set the variable wherever it launches. For a systemd user
service:

```ini
# ~/.config/systemd/user/<app>.service.d/cardwire.conf
[Service]
Environment=CARDWIRE_ALLOW=1
```

**Keys in the panel:** `i` integrated · `h` hybrid · `s` smart · `r` refresh · `esc` close.

**IPC**, for keybinds:

```bash
omarchy-shell io.github.rawritude.dgpu-control toggle
omarchy-shell io.github.rawritude.dgpu-control integrated
omarchy-shell io.github.rawritude.dgpu-control hybrid
omarchy-shell io.github.rawritude.dgpu-control smart
```

## Settings

| Key | Default | Meaning |
|---|---|---|
| `fallbackPollMs` | `300000` | Safety-net refresh; updates normally arrive by D-Bus signal |
| `activePollMs` | `3000` | Refresh while the panel is open (the process list has no signal behind it) |
| `warnWhenAwake` | `true` | Highlight the bar icon when the dGPU is not in a low-power state |

Set with `omarchy bar set io.github.rawritude.dgpu-control <key> <value> --json` (pass `--json` for booleans and numbers,
otherwise they are stored as strings).

## Notes on the ASUS section

The power limits are writable only when asusd's *tuning* gate is open — and the gate is per
**(power source × profile)**, not global. asusd keeps a separate power envelope for each of the six
cells of `ac`/`dc` × Quiet/Balanced/Performance, and consults only the one matching the moment.
With that cell shut it accepts the D-Bus write, reports success, updates its own property, and
never touches the firmware.

Verified on a GA403WM: the identical write landed under AC + Quiet and was silently dropped under
AC + Performance. So a slider that does nothing is almost never a broken asusd — it is the wrong
cell being shut.

A stock `asusd.ron` ships **every `dc_profile_tunings` group disabled**, which means nothing is
tunable on battery — exactly where lowering TGP would buy runtime.

The panel names the shut cell ("asusd is not applying power limits for Balanced on AC") and, if the
helper below is installed, offers a padlock button to open it. Opening a gate seeds its group from
the values the firmware is running *right now*, so it changes nothing by itself — worth doing,
because asusd's shipped Performance group carries a `PptPl1Spl` well under what the machine
actually runs at, and enabling it verbatim would quietly cost CPU power.

You can only open the gate for the cell you are currently in: to make the limits tunable on
battery, unplug first, then click the padlock.

### Installing the tuning helper

Opening the gate rewrites `/etc/asusd/asusd.ron` and restarts asusd, so it needs root. Everything
else — reading the gate, switching modes, switching profiles — works without it.

`omarchy plugin add` clones into `~/.config/omarchy/plugins/`, so run it from there:

```sh
cd ~/.config/omarchy/plugins/io.github.rawritude.dgpu-control
sudo ./contrib/install.sh
```

That places `asusd-tuning` in `/usr/local/bin` and a polkit action beside it, so the button prompts
for your password rather than needing a passwordless sudo rule. `asusd-tuning status` prints the
current gate as JSON; `disable` closes it again, keeping the group so it survives being reopened.

Restarting asusd makes it re-apply its configured default profile, which would otherwise move you
off the profile you were editing — the helper detects that and puts your profile back.

Two more behaviours worth knowing, both asusd's rather than this plugin's:

- If asusd is configured to switch profiles on AC/battery, a profile you pick by hand lasts only
  until the next plug or unplug. The panel says so when that is configured.
- **Reset-to-defaults also overwrites the active profile's saved group**, because asusd persists
  its tuning state back to the config file. The button says this; the tooltip spells it out.

## Design notes

**Nothing here wakes the discrete GPU.** `nvidia-smi` and `lspci` both resume a runtime-suspended
card simply by being run — so a naive monitor causes the very problem it reports. Power state comes
from cardwire's `PowerState()` D-Bus method, which the daemon answers without touching the device.

**Reads come from sysfs, not asusd's D-Bus properties.** With the gate shut, asusd's `CurrentValue`
reports what was *requested*, not what the hardware has. Measured directly: switching to
Performance moved D-Bus `PptPl1Spl` to 65 W while sysfs — and the CPU — stayed at 80 W. A panel
wired to D-Bus would have shown limits that did not exist. Every attribute is read from
`/sys/class/firmware-attributes/asus-armoury/` via `FileView`: authoritative, natively watched, and
no subprocess.

**Updates are event-driven.** cardwire and asusd both emit `PropertiesChanged`; a `gdbus monitor`
process sits blocked on a socket and the widget reacts only to real changes. An earlier polling
version cost ~480 process spawns and ~1.5 MB of journal per hour. A closed panel now does no
periodic work at all beyond a five-minute safety net.

**`blocked` does not mean unusable.** Smart mode reports `blocked=true` because it blocks *by
default* and then allows individual processes. Anything reasoning about whether the dGPU is
usable keys off the mode, never that flag.

## Credits

This plugin is a front-end. The hard parts belong to other people:

- **[cardwire](https://github.com/OpenGamingCollective/cardwire)** by the
  [Open Gaming Collective](https://github.com/OpenGamingCollective) (GPL-3.0) — the eBPF LSM GPU
  manager that does all the actual switching, blocking and per-process policy. Everything in the
  top half of this panel is a view onto their daemon.
- **[asusctl / asusd](https://asus-linux.org)** by Luke Jones and the
  [asus-linux](https://asus-linux.org) project (MPL-2.0) — the `xyz.ljones.AsusArmoury` interface
  and the platform-profile handling behind the ASUS section.
- **[Omarchy](https://github.com/basecamp/omarchy)** by Basecamp (MIT) — the shell, its plugin
  system, and the `Ui` components (`ButtonGroup`, `PanelSlider`, `PanelActionButton`,
  `KeyboardPanel`) this plugin is built from. The first-party `power` and `tailscale` panels were
  the working reference for how a bar widget should behave.
- **[Quickshell](https://git.outfoxxed.me/quickshell/quickshell)** by outfoxxed (LGPL-3.0) — the
  QML shell framework Omarchy is built on, and a separate project rather than part of it. This
  plugin is written directly against its APIs: `Process` and `StdioCollector` for every external
  call, `SplitParser` for the D-Bus monitor, `IpcHandler` for the keybind surface, and `FileView`,
  which is the reason attribute reads can come from sysfs natively instead of costing a
  subprocess per attribute.
- **[omarchy-asus-master](https://github.com/remydw/omarchy-asus-master)** by remydw (MIT) — the
  first plugin to drive asusd from Quickshell. No code is shared, and this plugin deliberately
  does not follow its I/O approach. What it gave us was knowing the `xyz.ljones.*` interface was
  drivable from a shell plugin at all, and its README's note that asusd writes can be accepted and
  silently discarded — which is what sent us looking for a cause rather than assuming the widget
  was at fault. The cause here turned out to be asusd's per-profile tuning gate rather than the
  version-specific bug that note describes; the pointer was still what found it.
- **[Nerd Fonts](https://www.nerdfonts.com/)** — the glyphs.

## License

MIT — see [LICENSE](LICENSE).
