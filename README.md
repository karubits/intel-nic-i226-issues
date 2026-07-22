# Intel i226-V / i225-V — silent hard-freeze & link-drops under load (ASPM)

Documentation, diagnosis, and fixes for the well-known **Intel i226-V** (`8086:125C`) and
**i225-V** (`8086:15F3`) 2.5 GbE controllers that **drop their link or hard-freeze the whole system
under sustained network load**. This affects a wide range of Intel N-series mini-PCs (N100 / N150 /
N305 / N355 and similar) from many vendors — it is **not** specific to any one product.

Two independent problems are at play, and you likely need **both** fixes:

1. **PCIe ASPM** causes link stalls / full-system hard-freezes → fixed by **disabling ASPM**
   (kernel `pcie_aspm=off`, or a BIOS ASPM/L1-substate toggle).
2. **Old NIC firmware (NVM)** causes device-not-enumerated-after-power-cycle and EEE link-flaps →
   fixed by **updating the NVM** (i226-V → **2.32**, i225-V → **1.89**).

> A community firmware-update helper (`nvmupdate64e` wrapper, auto-detecting) lives in
> [`firmware/`](firmware/) — see [`firmware/README.md`](firmware/README.md).

---

## Contents

- [Symptom](#symptom)
- [Affected hardware](#affected-hardware)
- [Diagnosis — what it is and isn't](#diagnosis--what-it-is-and-isnt)
- [Root cause](#root-cause)
- [Reproduction](#reproduction)
- [Fix 1 — disable ASPM (stops the freezes)](#fix-1--disable-aspm-stops-the-freezes)
- [Fix 2 — update the NIC firmware](#fix-2--update-the-nic-firmware)
- [What to ask your hardware vendor](#what-to-ask-your-hardware-vendor)
- [Personal findings — ZimaBlade 2 (IceWhale)](#personal-findings--zimablade-2-icewhale)

---

## Symptom

- The **entire system hard-freezes** under sustained network load — unresponsive to network and
  console. **No kernel panic, no oops, no thermal/MCE messages**: the system journal simply **stops
  mid-line**, with no shutdown sequence. That is the signature of a hard PCIe/system lock, not a
  software crash.
- Recovery requires a **physical power-cycle** (a warm reboot isn't possible — the OS is fully hung).
- A milder variant of the same fault: the **NIC link drops briefly** (services blip offline for
  ~1 minute, then recover) while the host stays up — the lighter-weight signal of the same ASPM
  instability that, under heavier load, escalates to the full lockup.

**Impact:** complete loss of service until someone physically power-cycles the box. For a headless,
always-on device (NAS, home server, router) this is a severe availability defect.

---

## Affected hardware

Any board carrying an onboard **Intel i226-V (`8086:125C`)** or **i225-V (`8086:15F3`)**, driven by
the Linux `igc` driver. These are extremely common on Intel N-series mini-PCs — ZimaBlade/ZimaBoard,
Protectli, Odroid H4, Minisforum, Topton/CWWK, Beelink and many others — as well as add-in 2.5 GbE
cards. The tell-tale that you're affected is this line on **every boot**:

```
igc 0000:0X:00.0: can't disable ASPM; OS doesn't have ASPM control
```

It means the BIOS enabled ASPM but did not hand control to the OS, so the driver cannot turn it off.

---

## Diagnosis — what it is and isn't

The freeze is easy to misattribute. Rule out the usual suspects first — in the reported cases they
are **not** the cause:

| Checked | Typical finding |
|---------|-----------------|
| Temperature | Not thermal — SoC sits far below its throttle/crit limit |
| Memory | Not OOM — plenty of RAM free, swap unused at freeze time |
| Storage | Not disk — filesystems healthy, no I/O errors |
| Kernel errors | No panic, oops, hung-task, soft-lockup, or MCE in the logs |
| RAM / EDAC | A boot-time `EDAC igen6 … IBECC MEMORY ERROR ADDR 0x7fffffffe0` is a **known benign false positive** of the `igen6_edac` probe on Alder Lake-N — not a real fault |

**What points at the NIC:** the per-boot `can't disable ASPM; OS doesn't have ASPM control` warning,
the tight correlation with sustained network throughput, and — decisively — the fact that
**disabling ASPM eliminates the freeze entirely**.

---

## Root cause

**PCIe ASPM (Active State Power Management) on the i225/i226.** The BIOS enables ASPM but does not
grant the OS control, so the `igc` driver cannot disable it. Under load the NIC's link
power-management state machine (L1 / L1-substates) wedges — dropping the link or hard-locking the
PCIe path and the whole system. This is a widely documented failure mode across the i225/i226 family.

---

## Reproduction

1. Run the affected board on a modern Linux (e.g. kernel 6.x, `igc` driver) with stock NIC firmware
   and default BIOS (ASPM enabled, OS not granted control).
2. Drive **sustained traffic** through the i226-V/i225-V port — a multi-GB transfer, backup ingest,
   or an `iperf3` soak. High, *sustained* throughput is the trigger; light traffic won't reproduce it
   quickly.
3. Within hours-to-days of load (sooner under a heavy transfer) the system **hard-freezes** and needs
   a power-cycle. The journal shows an abrupt end-of-log with no shutdown; prior boots show the same
   unclean pattern.

The intermittent **link-drop** variant reproduces more often and is a lighter signal of the same
underlying instability.

---

## Fix 1 — disable ASPM (stops the freezes)

The freeze is the ASPM axis. Disable ASPM and it stops. Two ways:

- **Kernel command line (works everywhere):**
  ```
  pcie_aspm=off intel_idle.max_cstate=1
  ```
  - `pcie_aspm=off` — disables PCIe ASPM globally (the direct fix). Afterwards the `can't disable
    ASPM` warning is gone and the link reports ASPM disabled.
  - `intel_idle.max_cstate=1` — caps deep CPU C-states; belt-and-suspenders against N-series
    idle-related hangs.
- **BIOS (cleaner, if exposed):** disable **ASPM** and **L1 Substates** for the PCIe root ports, or
  set *DMI/PEG ASPM* to Disabled. This avoids the small system-wide idle-power cost of
  `pcie_aspm=off`.

Notes:
- Energy-Efficient Ethernet (EEE) is disabled by the `igc` driver by default, so EEE is not the
  freeze trigger (old NVM has a *separate* EEE link-flap bug — see Fix 2).
- A targeted upstream `igc` fix that disables only ASPM **L1.2** landed in newer kernels (~6.18); on
  older kernels the blanket `pcie_aspm=off` is the reliable stand-in.

---

## Fix 2 — update the NIC firmware

Stock units often ship an **old NVM** (e.g. i226-V **2.17**, from 2023). Updating fixes real
firmware bugs — but understand what it does and doesn't cover:

| Latest public NVM | i226-V → **2.32** · i225-V → **1.89** |
|---|---|

**What a firmware update DOES fix**

- **"Device not enumerated during power-cycle / after warm reset"** (i226-V NVM 2.22–2.23) — the NIC
  sometimes fails to come back after a reboot/power-cycle.
- **"Link flaps with Energy-Efficient Ethernet enabled"** (i226-V NVM 2.22–2.25).
- Community reports confirm updating (e.g. 2.17 → 2.32) resolves load-related link drops / enumeration
  issues on N100/N150 boxes.

**What a firmware update does NOT fix**

- The **ASPM-induced hang / throughput collapse.** Even on the latest NVM, ASPM must *still* be
  disabled (BIOS or kernel) or the link stalls/hangs. **Firmware and ASPM are two separate axes** —
  do Fix 1 regardless.

**Updating:** there is usually **no vendor-published NVM or sanctioned update path** for these
onboard NICs, so people use community firmware images + Intel's `nvmupdate64e` at their own risk. This
repo includes an auto-detecting helper that reduces the footguns (correct 1 MB-vs-2 MB image
selection, `iomem=relaxed`, safe flash order): see **[`firmware/README.md`](firmware/README.md)**.

> ⚠️ Flashing NIC firmware can permanently brick the controller. Read the firmware README's warnings
> first, and only flash with physical access and reliable power.

---

## What to ask your hardware vendor

The kernel workaround shouldn't be necessary. Reasonable asks for any vendor shipping these NICs:

1. **A BIOS option to disable PCIe ASPM / L1 Substates** (or to grant the OS ASPM control) for the
   i225/i226 root ports. This is the proper fix.
2. **Ship the latest NVM on new units, and publish a sanctioned firmware + update procedure** for
   existing owners (with the correct image for the board's flash size).
3. **Document the recommended interim Linux settings** so users don't have to reverse-engineer them.

---

## Personal findings — ZimaBlade 2 (IceWhale)

My affected unit and the concrete evidence behind the general write-up above. Reported to IceWhale /
Zima; the ASPM mitigation has kept it **stable with zero further hard-freezes**.

| | |
|---|---|
| Device | **ZimaBlade 2** |
| SoC | Intel **N150** (Alder Lake-N / Twin Lake), 4 cores |
| RAM | 16 GB |
| NIC | 2× **Intel i226-V**, `8086:125C` **rev 04**, driver `igc` |
| NIC NVM | **2.17** — ethtool `2017:888d`; eTrack `80000303`; PHY FW `4C07_888D`; EFI OROM `0.1.4`; PBA `G23456-000`; **2 MB** flash |
| OS | Debian 13 (Trixie), kernel **6.12.90** |
| Trigger | sustained inbound network + disk I/O (unit used as a backup / file-server target) |

**Timeline / result:** the box hard-froze every ~1–2 days under backup-ingest load, each time needing
a physical power-cycle. After adding `pcie_aspm=off intel_idle.max_cstate=1` to the kernel command
line, it has run the *same* workload with **zero freezes and no further power-offs**.

**What I asked IceWhale / Zima:** a BIOS toggle to disable ASPM / L1 Substates (or grant OS ASPM
control), and a sanctioned i226-V **2.32** NVM + update path for existing ZimaBlade 2 owners.

### Evidence

**Per-boot ASPM warning (both ports, every boot):**
```
igc 0000:01:00.0: can't disable ASPM; OS doesn't have ASPM control
igc 0000:02:00.0: can't disable ASPM; OS doesn't have ASPM control
```

**Link capability — ASPM L1 + L1 Substates advertised, but OS lacks control:**
```
LnkCap:   Speed 5GT/s, Width x1, ASPM L1, Exit Latency L1 <4us
L1SubCap: PCI-PM_L1.2+ PCI-PM_L1.1+ ASPM_L1.2+ ASPM_L1.1+ L1_PM_Substates+
```

**NIC firmware inventory (`nvmupdate64e -i`):**
```
Device: 125C   Subvendor: 8086   Subdevice: 0000   Revision: 4
ETrackId: 80000303   NVM Version: 2.23(2.17)   PBA: G23456-000
EFI: 0.1.4   checksum: Valid
```

**Freeze signature:** the system journal ends abruptly mid-line (on a routine log entry) with no
`Reached target Shutdown`, no `reboot:`, and no panic — repeated across multiple boots — i.e. a hard
lock, not a clean reboot or software crash.

**`lspci`:**
```
01:00.0 Ethernet controller: Intel Corporation Ethernet Controller I226-V [8086:125c] (rev 04)
02:00.0 Ethernet controller: Intel Corporation Ethernet Controller I226-V [8086:125c] (rev 04)
```
