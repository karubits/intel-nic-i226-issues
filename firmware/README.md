# `flash-i225-i226-nvm.sh` — Intel i225-V / i226-V NVM firmware updater

A guarded, **auto-detecting** wrapper around Intel's `nvmupdate64e` tool for updating the NVM
(firmware) on onboard **Intel i225-V / i226-V** 2.5 GbE controllers — the NICs used on
ZimaBlade / ZimaBoard-class mini-PCs that suffer the link-drop / hard-freeze issue described in the
[main issue report](../README.md).

Updating to the latest NVM (**i226-V → 2.32**, **i225-V → 1.89**) fixes the firmware-side bugs
(device-not-enumerated-after-power-cycle, EEE link-flaps). It does **not**, on its own, fix the
ASPM-induced hang — for that you also need `pcie_aspm=off` on the kernel command line (see the
[main issue report](../README.md)).

> ### ⚠️ Read this first — flashing firmware can permanently brick your NIC
>
> - **Not supported by Intel.** The firmware images are **community-sourced** (see [Requirements](#requirements)),
>   not official Intel or IceWhale/Zima releases for these boards. Use **entirely at your own risk** —
>   it may void your warranty, with no guarantee of recovery.
> - **A failed or interrupted flash can permanently kill the NIC.** On a ZimaBlade the i226-V ports
>   are usually the *only* wired NICs, so a brick can leave the box unreachable.
> - **Physical access + reliable power only.** Never flash over your only network path, and never let
>   the machine lose power mid-write.
> - **No warranty, no liability.** You are responsible for what you flash to your hardware.

---

## Contents

- [Quick start](#quick-start)
- [Requirements](#requirements)
- [How it works](#how-it-works)
- [Usage](#usage)
- [After flashing](#after-flashing)
- [Environment overrides](#environment-overrides)
- [Exit codes](#exit-codes)
- [Supported hardware](#supported-hardware)
- [Disclaimer](#disclaimer)

---

## Quick start

```bash
# 0) stage nvmupdate64e + the .bin image(s) in this directory (see Requirements)
sudo ./flash-i225-i226-nvm.sh --dryrun    # show exactly what would run — changes nothing
sudo ./flash-i225-i226-nvm.sh --verify    # read-only: current firmware/eTrack per port
sudo ./flash-i225-i226-nvm.sh             # perform the flash (interactive confirmation)
# then: full power-cycle → --verify → remove iomem=relaxed
```

---

## Requirements

| # | Requirement | Where to get it |
|---|-------------|-----------------|
| 1 | **`nvmupdate64e`** (Intel NVM Update Tool) | [Intel Ethernet Adapter Complete Driver Pack (Download 15084)][intel-pack] — extract and drop `nvmupdate64e` into this `firmware/` directory (or point `TOOL=` at it) |
| 2 | **Firmware image(s)** for your chip | [hunghvu/Intel-I226-V-NVM-Firmware][fw-repo] — see the table below; place `.bin`(s) here or set `IMG_SEARCH=` |
| 3 | **`iomem=relaxed`** on the kernel command line | Modern kernels (6.x) block the tool's MMIO access → **exit code 26** without it. Add it, reboot, and remove it again after flashing. |
| 4 | **root** | run with `sudo` |

**Latest images** (the script auto-selects the right one from the card's detected eTrack, so it's
fine to have several present):

| Chip | 1 MB image | 2 MB image |
|------|-----------|-----------|
| **i226-V** (2.32) | [`FXVL_125C_V_1MB_2.32.bin`][fw-repo] | [`FXVL_125C_V_2MB_2.32.bin`][fw-repo] |
| **i225-V** (1.89) | [`FXVL_15F3_V_1MB_1.89.bin`][fw-repo] | [`FXVL_15F3_V_2MB_1.89.bin`][fw-repo] |

---

## How it works

The script handles the fiddly, error-prone parts for you:

1. **Preflight** — verifies root, that the tool exists, and that `iomem=relaxed` is active.
2. **Discovers every Intel `igc` NIC** by scanning `/sys/class/net/*` for the `igc` driver and a
   supported PCI device ID (`125C` = i226-V, `15F3` = i225-V).
3. **Reads each port's firmware** via `nvmupdate64e -i`, extracts the **eTrack ID**, and looks it up
   in a built-in table to derive the **flash size (1 MB vs 2 MB)** and version. Getting 1 MB vs 2 MB
   wrong is the #1 cause of bricked cards — this removes the guesswork. Any port whose eTrack isn't in
   the table is **refused** rather than flashed blind.
4. **Picks the target image** automatically (i226-V → 2.32, i225-V → 1.89) and **generates
   `nvmupdate.cfg`** per device, with the correct `VENDOR`/`DEVICE`/`SUBVENDOR`/`SUBDEVICE`, the target
   `EEPID`, and `REPLACES` set to the card's *current* eTrack.
5. **Orders the flash safely** — link-down / non-default-route ports **first**, the **active
   default-route port last**, so if a port goes unresponsive you still have the other one.
6. **Flashes** with `nvmupdate64e -u -b -f -m <MAC> -c <cfg>` (`-b` backs up the current NVM).
7. **Never reboots** — it prints the required manual full power-cycle and `--verify` steps.

Ports already at the target eTrack are reported as up-to-date and skipped.

---

## Usage

Stage the tool and image(s) in this directory (see [Requirements](#requirements)), then:

| Command | What it does |
|---------|--------------|
| `sudo ./flash-i225-i226-nvm.sh --dryrun` | Prints exactly what would run — **changes nothing**. Always start here. |
| `sudo ./flash-i225-i226-nvm.sh --verify` | Read-only status of each port's current firmware / eTrack. |
| `sudo ./flash-i225-i226-nvm.sh` | Performs the flash. Interactive — prompts for `FLASH-NVM`, and again before the active NIC. Needs physical access + reliable power. |

---

## After flashing

Do these **by hand** — the script never reboots:

1. **Full power-cycle:** `sudo poweroff` → **pull power ~1 minute** → power on.
   A warm reboot does *not* re-enumerate the PCI bus and can leave a NIC dead.
2. **Verify:** `sudo ./flash-i225-i226-nvm.sh --verify` — each port should now show the new eTrack.
3. **Remove `iomem=relaxed`** from your kernel command line (it relaxes `/dev/mem` hardening) and reboot.

---

## Environment overrides

| Variable | Purpose | Default |
|----------|---------|---------|
| `TOOL=` | Path to `nvmupdate64e` | `./nvmupdate64e` |
| `IMG_SEARCH=` | Space-separated dirs to search for `.bin` images | this dir + `/mnt/data/nvm226` |

```bash
sudo TOOL=/opt/intel/nvmupdate64e IMG_SEARCH="/opt/fw" ./flash-i225-i226-nvm.sh --dryrun
```

---

## Exit codes

From `nvmupdate64e`:

| Code | Meaning |
|:----:|---------|
| `0` | success |
| `26` | inaccessible device memory — you forgot `iomem=relaxed` |
| `51` | update available (shown by inventory / dry checks) — **not** an error |
| `23` / `37` | image can't be applied over current NVM (wrong/older package) |
| `21` | unsupported NVM image — update the tool |
| `19` | device not found |

> **Heads-up:** the tool sometimes prints *"Flash update failed"* even when the write actually
> succeeded. Don't panic — confirm the real result with `--verify` **after** the power-cycle, not by
> the on-screen message.

---

## Supported hardware

| Chip | PCI ID | Target NVM | Image files (1 MB / 2 MB) |
|------|--------|:----------:|---------------------------|
| Intel i226-V | `8086:125C` | 2.32 | `FXVL_125C_V_1MB_2.32.bin` / `FXVL_125C_V_2MB_2.32.bin` |
| Intel i225-V | `8086:15F3` | 1.89 | `FXVL_15F3_V_1MB_1.89.bin` / `FXVL_15F3_V_2MB_1.89.bin` |

Other variants (i226-LM/IT, i225-LM, etc.) are intentionally **not** handled — flashing the wrong
family/image (e.g. V firmware onto an LM part) can destroy the controller.

---

## Disclaimer

This script and the referenced firmware images are provided **as-is, without warranty of any kind**.
They are **not affiliated with, endorsed by, or supported by Intel or IceWhale/Zima**. Firmware
flashing is inherently risky and can permanently damage hardware. By using this, you accept full
responsibility for the outcome.

[intel-pack]: https://www.intel.com/content/www/us/en/download/15084/intel-ethernet-adapter-complete-driver-pack.html
[fw-repo]: https://github.com/hunghvu/Intel-I226-V-NVM-Firmware
