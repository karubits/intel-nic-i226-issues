# Intel i225-V / i226-V NVM firmware updater — `flash-i226-v2.sh`

A guarded, **auto-detecting** wrapper around Intel's `nvmupdate64e` tool for updating the NVM
(firmware) on onboard **Intel i225-V / i226-V** 2.5 GbE controllers — the NICs used on ZimaBlade /
ZimaBoard-class mini-PCs that suffer the link-drop / hard-freeze issue described in the
[repo README](../README.md).

Updating to the latest NVM (**i226-V → 2.32**, **i225-V → 1.89**) fixes the firmware-side bugs
(device-not-enumerated-after-power-cycle, EEE link-flaps). It does **not** by itself fix the
ASPM-induced hang — for that you also need `pcie_aspm=off` on the kernel command line (see the repo
README).

> ## ⚠️ READ THIS FIRST — flashing firmware can permanently brick your NIC
>
> - **This is NOT supported by Intel.** The firmware images are **community-sourced** (see links
>   below), not official IceWhale/Zima or Intel releases for these boards. Intel's tooling is
>   intended for Intel/OEM reference adapters. **Use entirely at your own risk.** It may void your
>   warranty and there is no guarantee of recovery if it goes wrong.
> - **A failed or interrupted flash can permanently kill the NIC.** On a ZimaBlade the i226-V ports
>   are usually the *only* wired NICs — a brick can leave the box unreachable.
> - **Only do this with physical access and reliable power.** Never flash over the only network path
>   you have, and never let the machine lose power mid-write.
> - **No warranty. No liability.** You are responsible for what you flash to your hardware.

---

## What you need

1. **Intel NVM Update Tool (`nvmupdate64e`)** — from the *Intel Ethernet Adapter Complete Driver
   Pack* (Download Center ID 15084):
   <https://www.intel.com/content/www/us/en/download/15084/intel-ethernet-adapter-complete-driver-pack.html>
   Extract and place `nvmupdate64e` in **this `firmware/` directory** (or point `TOOL=` at it).
2. **The firmware image(s)** — from the community archive:
   <https://github.com/hunghvu/Intel-I226-V-NVM-Firmware>
   You need the `.bin` for **your chip and flash size**. The script auto-selects the correct one from
   the card's detected eTrack, so having several present is fine. Latest images:
   - **i226-V:** `FXVL_125C_V_1MB_2.32.bin` / `FXVL_125C_V_2MB_2.32.bin` (NVM 2.32)
   - **i225-V:** `FXVL_15F3_V_1MB_1.89.bin` / `FXVL_15F3_V_2MB_1.89.bin` (NVM 1.89)

   Place the `.bin`(s) in this directory, or point `IMG_SEARCH=` at wherever they live.
3. **Linux with `iomem=relaxed`** on the kernel command line. Modern kernels (6.x) block the tool's
   MMIO access and it fails with **exit code 26** otherwise. Add `iomem=relaxed`, reboot, and remove
   it again after flashing.
4. **root** (run with `sudo`).

---

## How it works

The script does all the fiddly, error-prone parts for you:

1. **Preflight** — verifies it's root, the tool exists, and `iomem=relaxed` is active.
2. **Discovers every Intel `igc` NIC** by scanning `/sys/class/net/*` for the `igc` driver and a
   supported PCI device ID (`125C` = i226-V, `15F3` = i225-V).
3. **Reads each port's current firmware** via `nvmupdate64e -i`, extracts the **eTrack ID**, and looks
   it up in a built-in table to derive the **flash size (1 MB vs 2 MB)** and current version.
   Getting 1 MB vs 2 MB wrong is the #1 cause of bricked cards — this removes the guesswork. Any port
   whose eTrack is not in the table is **refused** rather than flashed blind.
4. **Picks the target image** automatically (i226-V → 2.32, i225-V → 1.89) and **generates the
   `nvmupdate.cfg`** per device, with the correct `VENDOR/DEVICE/SUBVENDOR/SUBDEVICE`, the target
   `EEPID`, and `REPLACES` set to the card's *current* eTrack.
5. **Orders the flash safely** — link-down / non-default-route ports **first**, and the **active
   default-route port last**, so if a port goes unresponsive you still have the other one.
6. **Flashes** with `nvmupdate64e -u -b -f -m <MAC> -c <cfg>` (`-b` backs up the current NVM).
7. **Never reboots** — it prints the required manual **full power-cycle** and `--verify` steps.

Ports already at the target eTrack are reported as up-to-date and skipped.

---

## How to run

Stage the tool and image(s) in this directory (see *What you need*), then:

```bash
# 1) See exactly what it WOULD do — changes nothing. Always start here.
sudo ./flash-i226-v2.sh --dryrun

# 2) Read-only status of each port's current firmware / eTrack.
sudo ./flash-i226-v2.sh --verify

# 3) Perform the flash (interactive — asks you to type FLASH-NVM, and again
#    before touching the active NIC). Requires physical access + reliable power.
sudo ./flash-i226-v2.sh
```

**After flashing (do this by hand):**

1. **Full power-cycle:** `sudo poweroff` → **pull power ~1 minute** → power on.
   A warm reboot does *not* re-enumerate the PCI bus and can leave a NIC dead.
2. Verify: `sudo ./flash-i226-v2.sh --verify` (each port should now show the new eTrack).
3. Remove `iomem=relaxed` from your kernel command line (it relaxes `/dev/mem` hardening) and reboot.

**Environment overrides:**

| Variable | Purpose | Default |
|---|---|---|
| `TOOL=` | Path to `nvmupdate64e` | `./nvmupdate64e` |
| `IMG_SEARCH=` | Space-separated dirs to search for `.bin` images | this dir + `/mnt/data/nvm226` |

Example: `sudo TOOL=/opt/intel/nvmupdate64e IMG_SEARCH="/opt/fw" ./flash-i226-v2.sh --dryrun`

---

## Exit codes you may see (from `nvmupdate64e`)

| Code | Meaning |
|---|---|
| `0`  | success |
| `26` | inaccessible device memory — you forgot `iomem=relaxed` |
| `51` | update available (shown by inventory/dry checks) — **not** an error |
| `23` / `37` | image can't be applied over current NVM (wrong/older package) |
| `21` | unsupported NVM image — update the tool |
| `19` | device not found |

> **Note:** the tool sometimes prints *"Flash update failed"* even when the write actually
> succeeded. **Do not panic** — confirm the real result with `--verify` after the power-cycle, not by
> the on-screen message.

---

## Supported hardware

| Chip | PCI Device ID | Target NVM | Image files (1 MB / 2 MB) |
|---|---|---|---|
| Intel i226-V | `8086:125C` | 2.32 | `FXVL_125C_V_1MB_2.32.bin` / `FXVL_125C_V_2MB_2.32.bin` |
| Intel i225-V | `8086:15F3` | 1.89 | `FXVL_15F3_V_1MB_1.89.bin` / `FXVL_15F3_V_2MB_1.89.bin` |

Other variants (i226-LM/IT, i225-LM, etc.) are intentionally **not** handled — flashing the wrong
family/image (e.g. V firmware onto an LM part) can destroy the controller.

---

## Disclaimer

This script and the referenced firmware images are provided **as-is, without warranty of any kind**.
They are **not affiliated with, endorsed by, or supported by Intel or IceWhale/Zima.** Firmware
flashing is inherently risky and can permanently damage hardware. By using this you accept full
responsibility for the outcome.
