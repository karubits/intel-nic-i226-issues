# ZimaBlade 2 — Intel i226-V NIC causes recurring full-system hard-freeze under sustained network load

**Issue report for IceWhale / Zima support**
**Date:** 2026-07-22
**Product:** ZimaBlade 2 (Intel N150), dual onboard Intel i226-V 2.5 GbE

---

## Summary (TL;DR)

The ZimaBlade 2's onboard **Intel i226-V (PCI `8086:125C`, rev 04)** NICs trigger a **silent,
full-system hard-freeze** under sustained network load. The machine locks up completely (no panic,
no logs, no network, no console) and only recovers with a **physical power-cycle**.

The kernel reports on every boot that it **cannot control ASPM** on these NICs:

```
igc 0000:01:00.0: can't disable ASPM; OS doesn't have ASPM control
igc 0000:02:00.0: can't disable ASPM; OS doesn't have ASPM control
```

Disabling ASPM from the OS (`pcie_aspm=off` on the kernel command line) **completely stopped the
freezes** — the unit has been stable ever since, with zero lockups under the same workload that
previously froze it within a day or two.

**We are asking Zima for a proper fix so end users don't need a kernel workaround:** (1) a BIOS
option to disable PCIe ASPM / L1 Substates (or grant the OS ASPM control), and (2) an updated /
user-flashable i226-V NVM firmware (current units ship **NVM 2.17**, from 2023; latest is **2.32**).

---

## Affected hardware & environment

| | |
|---|---|
| Device | ZimaBlade 2 |
| SoC | Intel N150 (Alder Lake-N / Twin Lake), 4 cores |
| RAM | 16 GB |
| NIC | 2× **Intel i226-V**, PCI ID **`8086:125C`, revision 04**, driver `igc` |
| NIC NVM (firmware) | **2.17** — ethtool `firmware-version: 2017:888d`; eTrack `80000303`; PHY FW `4C07_888D`; EFI OROM `0.1.4`; PBA `G23456-000`; **2 MB** flash |
| OS | Debian 13 (Trixie), kernel **6.12.90** |
| Trigger workload | sustained inbound network + disk I/O (unit used as a backup / file server target) |

`lspci` (both ports identical):

```
01:00.0 Ethernet controller: Intel Corporation Ethernet Controller I226-V [8086:125c] (rev 04)
02:00.0 Ethernet controller: Intel Corporation Ethernet Controller I226-V [8086:125c] (rev 04)
```

---

## Symptom

- The entire system **hard-freezes** — unresponsive to network and (per repeated experience) console.
- **No kernel panic, no oops, no thermal/MCE messages** — the system journal simply **stops
  mid-line** at the moment of the freeze, with no shutdown sequence. This is the signature of a hard
  PCIe/system lock, not a software crash or a clean reboot.
- Recovery requires a **physical power-cycle**. A warm reboot is not possible because the OS is fully
  hung.
- A milder form of the same fault also occurs: the **NIC link drops briefly** (network services blip
  offline for ~1 minute, then recover) while the host stays up — consistent with an i226-V link/ASPM
  glitch that, under heavier load, escalates to the full lockup.

## Impact

- Complete loss of service until someone is physically present to power-cycle the unit.
- For a headless / always-on device (NAS, home-server, router), this is a severe availability defect.

---

## Diagnosis — what it is, and what it is **not**

We investigated thoroughly and **ruled out** the usual suspects:

| Checked | Result |
|---|---|
| Temperature | **Not thermal** — 37 °C idle, throttle/crit limit 105 °C; the SoC is nowhere near limits |
| Memory | **Not OOM** — 16 GB RAM, ample free, swap unused at freeze time |
| Storage | **Not disk** — root and data volumes far from full; ZFS pool healthy, no I/O errors |
| Kernel errors | **No** panic, oops, hung-task, soft-lockup, or MCE anywhere in the logs |
| RAM/EDAC | The one boot-time `EDAC igen6 … IBECC MEMORY ERROR ADDR 0x7fffffffe0` is a **known benign false positive** from the `igen6_edac` probe on Alder Lake-N — not a real memory fault |

**What points squarely at the NIC:** every boot logs that the OS is **denied ASPM control** of both
i226-V ports (`can't disable ASPM; OS doesn't have ASPM control`). The Intel i225/i226 family +
active-state power management (ASPM, particularly L1/L1-substates) is a **widely documented** cause
of NIC link drops and full-system hangs on Intel N-series mini-PCs. The failure correlates tightly
with sustained network load, and — decisively — **disabling ASPM eliminates it** (see Mitigation).

---

## Reproduction

**Before mitigation**, the freeze was reliably reproducible on our unit:

1. Run the ZimaBlade 2 on Debian 13 / kernel 6.12 with the stock i226-V NVM (2.17) and default BIOS
   (ASPM enabled, OS not granted ASPM control).
2. Drive **sustained traffic** through an onboard i226-V port (e.g. a multi-GB backup ingest, large
   file transfer, or `iperf3` soak). High, sustained throughput is the trigger; light traffic does
   not reproduce it quickly.
3. Within roughly a day or two of normal load (or sooner under a heavy transfer), the system
   **hard-freezes** and requires a power-cycle. The journal shows an abrupt end-of-log with no
   shutdown, and the preceding boots show the same unclean pattern.

The intermittent **link-drop** variant reproduces more often and is a lighter-weight signal of the
same underlying ASPM instability.

---

## Root cause (best assessment)

PCIe **ASPM** on the i226-V. The BIOS enables ASPM but does **not** hand ASPM control to the OS, so
the OS driver cannot turn it off (`can't disable ASPM; OS doesn't have ASPM control`). Under load the
i226-V's link power-management state machine wedges, dropping the link or hard-locking the PCIe
path / system. This matches the broad body of i225/i226 reports and is confirmed on our unit by the
fact that disabling ASPM removes the symptom entirely.

---

## Mitigation that works (Linux, no hardware change) — **currently stable**

Adding the following to the Linux kernel command line and rebooting **stopped the freezes**:

```
pcie_aspm=off intel_idle.max_cstate=1
```

- `pcie_aspm=off` — disables PCIe ASPM globally (the direct fix for the i226-V hang). After this,
  the `can't disable ASPM` warning no longer appears and the link reports ASPM disabled.
- `intel_idle.max_cstate=1` — caps deep CPU C-states; added as a belt-and-suspenders measure against
  N-series idle-related hangs.

**Result:** since applying this, the unit has run the *same* workload that used to freeze it, with
**zero hard-freezes and no further power-cycles required.** This strongly confirms ASPM as the cause.

Note this is a **workaround end users should not have to discover.** `pcie_aspm=off` also disables
ASPM system-wide (a small idle-power cost), which is heavier-handed than necessary — a targeted BIOS
option would be the correct fix.

Other observations for completeness:
- Energy-Efficient Ethernet (EEE) is already **disabled** by the `igc` driver by default, so EEE is
  not the trigger here (though old NVM has a separate EEE link-flap bug — see below).
- A targeted upstream `igc` fix that disables ASPM **L1.2** specifically (rather than all ASPM) has
  landed in newer Linux kernels (~6.18); it is not in 6.12, which is why the blanket `pcie_aspm=off`
  is currently required.

---

## Firmware (NVM) — current revision, and what an update does / does not fix

**Shipped firmware on our unit: NVM 2.17** (eTrack `80000303`, PHY FW `4C07_888D`) — released 2023.
The latest publicly available i226-V NVM is **2.32**. Relevant fixes between 2.17 and 2.32:

| NVM | Relevant fix |
|---|---|
| 2.22 / 2.23 | **"Device not enumerated during power cycle (restart, power-on, etc.)"** and "LAN device not enumerated after warm-reset cycle" |
| 2.22 / 2.25 | **"Link flaps with Energy-Efficient Ethernet enabled"** |
| 2.27 | PHY FW update, QV loopback fix |
| 2.32 | MDI lane-swap polarity fix (latest public) |

**What updating to 2.32 DOES fix:** the *enumeration* problems (device sometimes not coming back
after a power-cycle — which matches our experience of occasionally needing more than one power-cycle
to recover) and the *EEE link-flap* bug. Community reports (e.g. the long OPNsense i225/i226 thread)
confirm 2.17→2.32 resolves load-related link drops / enumeration issues on N100/N150 boxes.

**What updating to 2.32 does NOT fix:** the **ASPM-induced hang / throughput collapse**. Multiple
users report that even on 2.32, ASPM must *still* be disabled (BIOS or kernel) or the link stalls /
hangs. In other words, **firmware and ASPM are two separate axes** — the freeze we hit is the ASPM
axis, so a firmware update alone would not have fixed it; disabling ASPM did.

**Practical problem for ZimaBlade owners:** there is currently **no IceWhale-published i226-V NVM
image or sanctioned update path** for the ZimaBlade. Users are left to source community images and
run Intel's `nvmupdate` tool at their own risk (which also requires `iomem=relaxed` on modern kernels
to access the device, and correct 1 MB-vs-2 MB image selection — easy to get wrong and brick a NIC).

---

## What we're asking Zima / IceWhale

In priority order:

1. **BIOS fix — the important one.** Provide a BIOS option to **disable PCIe ASPM / L1 Substates**
   for the i226-V root ports, **or** grant the OS ASPM control so the `igc` driver can manage it.
   This is the proper fix and removes the need for any kernel workaround.
2. **Ship updated NVM (2.32) on new units, and publish a sanctioned i226-V firmware + update
   procedure** for existing ZimaBlade 2 owners (with clear guidance on the correct 2 MB image for the
   Blade). This addresses the enumeration and EEE-link-flap bugs.
3. **Confirm / document** the recommended Linux settings for ZimaBlade 2 in the interim, so users
   aren't left to reverse-engineer `pcie_aspm=off`.

We're happy to provide any further logs, `lspci -vvv` dumps, `nvmupdate64e -i` inventory, or to test
a candidate BIOS.

---

## Appendix — key evidence

**Per-boot ASPM warning (every boot):**
```
igc 0000:01:00.0: can't disable ASPM; OS doesn't have ASPM control
igc 0000:02:00.0: can't disable ASPM; OS doesn't have ASPM control
```

**Link capability (ASPM L1 + L1 Substates advertised; OS lacks control):**
```
LnkCap:  Speed 5GT/s, Width x1, ASPM L1, Exit Latency L1 <4us
L1SubCap: PCI-PM_L1.2+ PCI-PM_L1.1+ ASPM_L1.2+ ASPM_L1.1+ L1_PM_Substates+
```

**NIC firmware inventory (`nvmupdate64e -i`):**
```
Device: 125C   Subvendor: 8086   Subdevice: 0000   Revision: 4
ETrackId: 80000303   NVM Version: 2.23(2.17)   PBA: G23456-000
EFI: 0.1.4   checksum: Valid
```

**Freeze signature:** system journal ends abruptly mid-line (routine log entry) with no
`Reached target Shutdown`, no `reboot:`, and no panic — repeated across multiple boots — i.e. a hard
lock, not a clean reboot or software crash.
