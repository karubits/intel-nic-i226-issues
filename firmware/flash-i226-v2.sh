#!/usr/bin/env bash
#
# flash-i226-v2.sh — Update Intel i225-V / i226-V NVM firmware (portable / auto-detecting)
#
# A generic version of flash-i226.sh: it DISCOVERS the NICs, their MACs, current
# firmware (eTrack), and flash size (1MB/2MB) at runtime, then picks the right
# target image automatically. Safe for any ZimaBlade/ZimaBoard-class box with the
# i225/i226 hang/link-drop issue — not hard-coded to one host.
#
#   i226-V (DevID 125C)  ->  target NVM 2.32
#   i225-V (DevID 15F3)  ->  target NVM 1.89
#
# USAGE
#   sudo ./flash-i226-v2.sh --dryrun    # detect + print EXACTLY what would run; touch nothing
#   sudo ./flash-i226-v2.sh --verify    # read-only: show each port's current firmware/eTrack
#   sudo ./flash-i226-v2.sh             # perform the flash (interactive confirmation)
#
# SAFETY MODEL
#   * Requires: root; nvmupdate64e present; iomem=relaxed on the kernel cmdline.
#   * Detects every Intel igc NIC, reads its eTrack, and refuses any port whose
#     eTrack is not in the known table (can't safely choose a 1MB vs 2MB image).
#   * Flashes link-DOWN / non-default-route ports FIRST, the ACTIVE default-route
#     port LAST, so a bricked port still leaves you reachable.
#   * Backs up current NVM (-b). NEVER reboots — a FULL power-cycle (pull power
#     ~1 min) is required by hand afterward, then re-run with --verify.
#
set -uo pipefail

# ---- tunables --------------------------------------------------------------
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL="${TOOL:-$DIR/nvmupdate64e}"
CFG="$DIR/nvmupdate-auto.cfg"        # generated at runtime
INV_LOG="/tmp/_i226v2_inv.log"
# Where to look for the .bin images if not next to this script (space-separated):
IMG_SEARCH="${IMG_SEARCH:-$DIR /mnt/data/nvm226}"

# ---- knowledge tables (from BillyCurtis/Intel-i226-V-NVM-Firmware README) --
# current eTrack (UPPERCASE) -> "DEVID VERSION SIZE"
declare -A ETRACK=(
  # i226-V (125C)
  [80000290]="125C 2.14 1MB" [8000028D]="125C 2.14 2MB"
  [80000308]="125C 2.17 1MB" [80000303]="125C 2.17 2MB"
  [80000371]="125C 2.22 2MB" [8000039D]="125C 2.23 1MB"
  [800003AD]="125C 2.25 2MB"
  [80000425]="125C 2.27/2.32 1MB" [80000422]="125C 2.27/2.32 2MB"
  # i225-V (15F3)
  [80000150]="15F3 1.45 1MB" [8000014B]="15F3 1.45 2MB"
  [80000182]="15F3 1.57 1MB" [80000185]="15F3 1.57 2MB"
  [800001CE]="15F3 1.68 1MB" [800001C7]="15F3 1.68 2MB"
  [800002FC]="15F3 1.89 1MB" [800002F4]="15F3 1.89 2MB"
)
# "DEVID:SIZE" -> "TARGET_ETRACK IMAGE_FILENAME TARGET_VERSION"
declare -A TARGET=(
  [125C:1MB]="80000425 FXVL_125C_V_1MB_2.32.bin 2.32"
  [125C:2MB]="80000422 FXVL_125C_V_2MB_2.32.bin 2.32"
  [15F3:1MB]="800002FC FXVL_15F3_V_1MB_1.89.bin 1.89"
  [15F3:2MB]="800002F4 FXVL_15F3_V_2MB_1.89.bin 1.89"
)

MODE="flash"   # flash | dryrun | verify

# ---- pretty helpers --------------------------------------------------------
if [[ -t 1 ]]; then B=$(tput bold 2>/dev/null||true); R=$(tput sgr0 2>/dev/null||true)
                    RED=$(tput setaf 1 2>/dev/null||true); GRN=$(tput setaf 2 2>/dev/null||true)
                    YEL=$(tput setaf 3 2>/dev/null||true)
else B=""; R=""; RED=""; GRN=""; YEL=""; fi
log()  { echo "${B}==>${R} $*"; }
ok()   { echo "  ${GRN}OK${R}  $*"; }
warn() { echo "  ${YEL}!!${R}  $*"; }
die()  { echo "${RED}ERROR:${R} $*" >&2; exit 1; }

explain_rc() {
  case "$1" in
    0)     echo "success (all operations completed)";;
    15)    echo "another instance of the tool is already running";;
    18)    echo "an error occurred during reset";;
    19)    echo "device not found";;
    21)    echo "unsupported NVM image — upgrade the tool";;
    23|37) echo "image cannot be applied over current NVM (wrong/older package)";;
    26)    echo "inaccessible device memory — kernel needs iomem=relaxed";;
    50)    echo "perform the indicated reset action, then re-run";;
    51)    echo "update available (inventory) — expected, NOT an error";;
    *)     echo "consult Intel exit-code table / the update log";;
  esac
}
mac_colon() { sed 's/../&:/g; s/:$//' <<<"$1"; }          # 00e04c.. -> 00:e0:4c..
norm_mac()  { tr -d ':' <<<"$1" | tr 'a-f' 'A-F'; }      # -> UPPER, no colons

# ---- argument parsing ------------------------------------------------------
case "${1:-}" in
  --dryrun) MODE="dryrun";;
  --verify) MODE="verify";;
  ""|--flash) MODE="flash";;
  -h|--help) sed -n '2,33p' "$0"; exit 0;;
  *) die "unknown argument: $1  (use --dryrun, --verify, or no argument)";;
esac

# ---- discovered-device state (parallel arrays, indexed together) -----------
D_IFACE=(); D_MAC=(); D_PCI=(); D_ETRACK=(); D_DEVID=(); D_SIZE=(); D_VER=()
D_SUBVEN=(); D_SUBDEV=(); D_TGT_ET=(); D_TGT_IMG=(); D_TGT_VER=(); D_STATE=(); D_DEFRT=()

# ---- preflight -------------------------------------------------------------
preflight() {
  [[ $EUID -eq 0 ]] || die "must run as root (use sudo)."
  (( BASH_VERSINFO[0] >= 4 )) || die "bash 4+ required (associative arrays)."
  [[ -x "$TOOL" ]] || die "tool not executable: $TOOL  (override with TOOL=/path ./…)"
  grep -qw "iomem=relaxed" /proc/cmdline \
      || die "iomem=relaxed is NOT on the kernel cmdline — the tool fails with exit 26. Add it and reboot first."
  ok "root, tool, iomem=relaxed present."
}

# find a .bin by name across IMG_SEARCH; echo full path or empty
find_image() {
  local img="$1" p f
  for p in $IMG_SEARCH; do
    f=$(find "$p" -type f -name "$img" 2>/dev/null | head -1)
    [[ -n "$f" ]] && { echo "$f"; return 0; }
  done
  return 1
}

# ---- discovery -------------------------------------------------------------
discover() {
  local defrt_if; defrt_if=$(ip route show default 2>/dev/null | awk '/default/{for(i=1;i<=NF;i++)if($i=="dev")print $(i+1); exit}')

  # 1) inventory once (needs iomem=relaxed) -> MAC(upper,no colon) -> eTrack(upper)
  log "Running tool inventory (reads current firmware/eTrack)..."
  "$TOOL" -i -l "$INV_LOG" >/dev/null 2>&1 || true
  declare -gA MAC2ET=()
  # detailed per-device blocks in the log carry LAN MAC + ETrackId
  while read -r mac et; do
    [[ -n "$mac" && -n "$et" ]] && MAC2ET["$(norm_mac "$mac")"]="$(echo "$et" | tr 'a-f' 'A-F')"
  done < <(awk -F': *' '
      /LAN MAC/{mac=$2}
      /ETrackId/{ if(mac!=""){print mac, $2; mac=""} }' "$INV_LOG")

  # 2) walk sysfs for Intel igc NICs, join with inventory by MAC
  local n drv devid mac pci sv sd et info
  for n in /sys/class/net/*; do
    n=$(basename "$n")
    [[ -e "/sys/class/net/$n/device/driver" ]] || continue
    drv=$(basename "$(readlink -f "/sys/class/net/$n/device/driver")")
    [[ "$drv" == "igc" ]] || continue
    devid=$(cat "/sys/class/net/$n/device/device" 2>/dev/null | sed 's/^0x//' | tr 'a-f' 'A-F')
    [[ -n "${TARGET[${devid}:1MB]:-}${TARGET[${devid}:2MB]:-}" ]] || { warn "$n: unsupported Intel device $devid — skipping"; continue; }
    mac=$(cat "/sys/class/net/$n/address" 2>/dev/null)
    pci=$(basename "$(readlink -f "/sys/class/net/$n/device")")
    sv=$(cat "/sys/class/net/$n/device/subsystem_vendor" 2>/dev/null | sed 's/^0x//')
    sd=$(cat "/sys/class/net/$n/device/subsystem_device" 2>/dev/null | sed 's/^0x//')
    et="${MAC2ET[$(norm_mac "$mac")]:-}"
    [[ -n "$et" ]] || { warn "$n ($mac): no eTrack from inventory — skipping (iomem=relaxed? driver?)"; continue; }
    info="${ETRACK[$et]:-}"
    [[ -n "$info" ]] || die "$n: current eTrack $et is UNKNOWN — refusing (cannot safely pick 1MB vs 2MB image). Add it to the table."
    local dver dsize; read -r _ dver dsize <<<"$info"
    local tinfo="${TARGET[${devid}:${dsize}]}"; local tet timg tver; read -r tet timg tver <<<"$tinfo"

    D_IFACE+=("$n"); D_MAC+=("$mac"); D_PCI+=("$pci"); D_ETRACK+=("$et")
    D_DEVID+=("$devid"); D_SIZE+=("$dsize"); D_VER+=("$dver")
    D_SUBVEN+=("${sv:-0000}"); D_SUBDEV+=("${sd:-0000}")
    D_TGT_ET+=("$tet"); D_TGT_IMG+=("$timg"); D_TGT_VER+=("$tver")
    [[ "$(cat "/sys/class/net/$n/carrier" 2>/dev/null || echo 0)" == "1" ]] && D_STATE+=("up") || D_STATE+=("down")
    [[ "$n" == "$defrt_if" ]] && D_DEFRT+=("yes") || D_DEFRT+=("no")
  done
  [[ ${#D_IFACE[@]} -gt 0 ]] || die "no supported Intel i225/i226 igc NICs found."
}

# flash order: default-route port LAST; among the rest, link-down first.
flash_order() {
  local i order_down=() order_up=() order_active=()
  for i in "${!D_IFACE[@]}"; do
    if   [[ "${D_DEFRT[$i]}" == "yes" ]]; then order_active+=("$i")
    elif [[ "${D_STATE[$i]}" == "down" ]]; then order_down+=("$i")
    else order_up+=("$i"); fi
  done
  echo "${order_down[@]} ${order_up[@]} ${order_active[@]}"
}

print_table() {
  echo
  printf "  %-8s %-17s %-6s %-6s %-5s %-9s %-9s %-8s %s\n" IFACE MAC DEVID SIZE VER CUR-ETRK TGT-ETRK LINK ROLE
  local i
  for i in "${!D_IFACE[@]}"; do
    local role="peer"; [[ "${D_DEFRT[$i]}" == "yes" ]] && role="ACTIVE(default route)"
    local upd="update->${D_TGT_VER[$i]}"; [[ "${D_ETRACK[$i]}" == "${D_TGT_ET[$i]}" ]] && upd="up-to-date"
    printf "  %-8s %-17s %-6s %-6s %-5s %-9s %-9s %-8s %s [%s]\n" \
      "${D_IFACE[$i]}" "${D_MAC[$i]}" "${D_DEVID[$i]}" "${D_SIZE[$i]}" "${D_VER[$i]}" \
      "${D_ETRACK[$i]}" "${D_TGT_ET[$i]}" "${D_STATE[$i]}" "$role" "$upd"
  done
}

# build the cfg covering every distinct device block that NEEDS an update
gen_cfg() {
  local i seen="" key
  { echo "CURRENT FAMILY: 1.0.0"; echo "CONFIG VERSION: 1.20.0"; } > "$CFG"
  for i in "${!D_IFACE[@]}"; do
    [[ "${D_ETRACK[$i]}" == "${D_TGT_ET[$i]}" ]] && continue      # already up to date
    key="${D_DEVID[$i]}:${D_SUBVEN[$i]}:${D_SUBDEV[$i]}:${D_ETRACK[$i]}"
    [[ "$seen" == *"|$key|"* ]] && continue
    seen="$seen|$key|"
    {
      echo "BEGIN DEVICE"
      echo "DEVICENAME: Intel(R) Ethernet Controller (auto)"
      echo "VENDOR: 8086"
      echo "DEVICE: ${D_DEVID[$i]}"
      echo "SUBVENDOR: ${D_SUBVEN[$i]}"
      echo "SUBDEVICE: ${D_SUBDEV[$i]}"
      echo "NVM IMAGE: ${D_TGT_IMG[$i]}"
      echo "EEPID: ${D_TGT_ET[$i]}"
      echo "RESET TYPE: REBOOT"
      echo "REPLACES: ${D_ETRACK[$i]}"
      echo "END DEVICE"
    } >> "$CFG"
  done
}

# ensure each needed image is present next to the tool (copy from IMG_SEARCH)
stage_images() {
  local i img src missing=0
  local seen=""
  for i in "${!D_IFACE[@]}"; do
    [[ "${D_ETRACK[$i]}" == "${D_TGT_ET[$i]}" ]] && continue
    img="${D_TGT_IMG[$i]}"; [[ "$seen" == *"|$img|"* ]] && continue; seen="$seen|$img|"
    if [[ -f "$DIR/$img" ]]; then ok "image present: $img"; continue; fi
    if src=$(find_image "$img"); then
      if [[ "$MODE" == "dryrun" ]]; then echo "    [dryrun] would copy $src -> $DIR/";
      else cp -n "$src" "$DIR/" && ok "staged $img (from $src)"; fi
    else warn "image NOT found anywhere in: $IMG_SEARCH  ->  $img"; missing=1; fi
  done
  return $missing
}

flash_one() {
  local i="$1" name="${D_IFACE[$i]}" mac; mac=$(norm_mac "${D_MAC[$i]}")
  local logf="$DIR/update_${name}.log"
  local cmd=( "$TOOL" -u -b -f -m "$mac" -c "$CFG" -l "$logf" )
  echo
  log "Flash ${B}${name}${R} (MAC ${D_MAC[$i]}, ${D_SIZE[$i]} ${D_DEVID[$i]}, ${D_ETRACK[$i]} -> ${D_TGT_ET[$i]})"
  echo "    \$ ${cmd[*]}"
  if [[ "$MODE" == "dryrun" ]]; then echo "    ${YEL}[dryrun]${R} command NOT executed"; return 0; fi
  ( cd "$DIR" && "${cmd[@]}" ); local rc=$?
  echo "    exit $rc — $(explain_rc "$rc")"
  [[ $rc -ne 0 ]] && { warn "non-zero exit — often a FALSE NEGATIVE; confirm with --verify after power-cycle."; }
  return $rc
}

post_steps() {
  cat <<EOF

${B}AFTER FLASHING — do this by hand:${R}
  1) FULL power-cycle:  sudo poweroff  ->  pull power ~1 min  ->  power on.
     (A warm reboot does NOT re-enumerate the PCI bus and can leave a NIC dead.)
  2) Verify:            sudo $DIR/$(basename "$0") --verify
  3) If you added iomem=relaxed only for this, remove it afterward.
EOF
}

# ---- main ------------------------------------------------------------------
echo "${B}Intel i225/i226-V NVM update (auto-detect) — mode: ${MODE}${R}"
preflight
discover
print_table

# how many actually need updating?
NEED=()
for i in "${!D_IFACE[@]}"; do [[ "${D_ETRACK[$i]}" != "${D_TGT_ET[$i]}" ]] && NEED+=("$i"); done

case "$MODE" in
  verify)
    echo; if [[ ${#NEED[@]} -eq 0 ]]; then ok "all ports already at target eTrack — nothing to do."
    else warn "${#NEED[@]} port(s) NOT at target yet (see table above)."; fi
    exit 0;;
esac

if [[ ${#NEED[@]} -eq 0 ]]; then ok "all ports already up to date — nothing to flash."; exit 0; fi

order=$(flash_order)
echo; log "Flash order (unused/link-down first, ACTIVE default-route last): $(for i in $order; do printf '%s ' "${D_IFACE[$i]}"; done)"
gen_cfg
echo; log "Generated cfg: $CFG"; sed 's/^/    /' "$CFG"
stage_images || { [[ "$MODE" != "dryrun" ]] && die "one or more images missing — place them under: $IMG_SEARCH"; }

if [[ "$MODE" == "dryrun" ]]; then
  echo; log "DRY RUN — the following would run (nothing executed):"
  for i in $order; do [[ "${D_ETRACK[$i]}" != "${D_TGT_ET[$i]}" ]] && flash_one "$i"; done
  post_steps; echo; ok "dry run complete — no changes made."; exit 0
fi

# real flash
echo
warn "This will WRITE firmware to ${#NEED[@]} NIC(s). It can brick a port if interrupted."
warn "Ensure physical access + reliable power."
read -r -p "  Type ${B}FLASH-NVM${R} to continue (anything else aborts): " ans
[[ "$ans" == "FLASH-NVM" ]] || die "aborted by user."
first=1
for i in $order; do
  [[ "${D_ETRACK[$i]}" == "${D_TGT_ET[$i]}" ]] && continue
  if [[ "${D_DEFRT[$i]}" == "yes" && $first -eq 0 ]]; then
    echo; read -r -p "  Next is the ACTIVE default-route NIC ${D_IFACE[$i]}. Type YES to flash it: " a2
    [[ "$a2" == "YES" ]] || { warn "stopped before active NIC by user."; post_steps; exit 0; }
  fi
  flash_one "$i" || true
  first=0
done
post_steps
