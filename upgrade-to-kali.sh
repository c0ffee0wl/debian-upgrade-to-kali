#!/bin/bash
# upgrade-to-kali - Convert a Debian 12+ (bookworm or newer) system into Kali Linux.
# Run: sudo ./upgrade-to-kali.sh
# Optionally install as a command: sudo install -m 0755 upgrade-to-kali.sh /usr/local/bin/upgrade-to-kali
#
# WARNING: performs an effectively irreversible base-system rebase onto
# kali-rolling. Snapshot / back up first.
#   https://www.kali.org/docs/general-use/kali-apt-sources/
set -eo pipefail

# Deterministic English command output regardless of host locale (os-release /
# apt strings are parsed). C.UTF-8 is built into glibc (no locale-gen needed).
export LC_ALL=C.UTF-8
export LANG=C.UTF-8

VERSION="1.6.0"

# Overridable paths/thresholds: production defaults; overridden by tests, or by
# an operator to steer detection (e.g. ESP_PATH when auto-detection misfires).
OS_RELEASE_FILE="${OS_RELEASE_FILE:-/etc/os-release}"
APT_DIR="${APT_DIR:-/etc/apt}"
BACKUP_DIR="${BACKUP_DIR:-$APT_DIR/upgrade-to-kali-backup}"
KEYRING_PATH="${KEYRING_PATH:-/usr/share/keyrings/kali-archive-keyring.gpg}"
KEYRING_URL="${KEYRING_URL:-https://archive.kali.org/archive-keyring.gpg}"
# An explicitly pinned mirror must never be overridden by the automatic
# CDN failover in run_step_with_recovery - record the pin before defaulting.
KALI_MIRROR_PINNED=false
[ -n "${KALI_MIRROR:-}" ] && KALI_MIRROR_PINNED=true
KALI_MIRROR="${KALI_MIRROR:-http://http.kali.org/kali}"
# Failover target when the configured mirror keeps failing: Kali's official
# Cloudflare-backed CDN mirror, the Kali devs' documented fallback advice.
KALI_FALLBACK_MIRROR="${KALI_FALLBACK_MIRROR:-https://kali.download/kali}"
NET_RETRIES="${NET_RETRIES:-2}"           # delayed retries per mirror/network failure
NET_RETRY_DELAY="${NET_RETRY_DELAY:-20}"  # seconds before the first retry (then doubled)
BOOT_DIR="${BOOT_DIR:-/boot}"
ESP_PATH="${ESP_PATH:-}"
MACHINE_ID_FILE="${MACHINE_ID_FILE:-/etc/machine-id}"
ENTRY_TOKEN_FILE="${ENTRY_TOKEN_FILE:-/etc/kernel/entry-token}"
INITRAMFS_CONF_DIR="${INITRAMFS_CONF_DIR:-/etc/initramfs-tools/conf.d}"
MODULES_CONF="${MODULES_CONF:-$INITRAMFS_CONF_DIR/upgrade-to-kali-modules.conf}"
STATE_FILE="${STATE_FILE:-/var/lib/upgrade-to-kali/state}"
ROOT_MIN_FREE_KIB="${ROOT_MIN_FREE_KIB:-6291456}"    # 6 GiB, warn-only
ESP_FLOOR_MOST_KIB="${ESP_FLOOR_MOST_KIB:-307200}"   # 300 MiB (Debian trixie guidance)
ESP_FLOOR_DEP_KIB="${ESP_FLOOR_DEP_KIB:-65536}"      # 64 MiB: below = hopeless, abort
ESP_HEADROOM_PCT="${ESP_HEADROOM_PCT:-25}"           # margin on a measured kernel pair
# First-run guess for the incoming Kali generic-kernel pair on the ESP under
# MODULES=dep + xz (~16-20 MiB vmlinuz + ~35-55 MiB initrd, plus slack). Used
# only until the conversion's own kernel exists and can be measured.
ESP_KALI_PAIR_DEP_KIB="${ESP_KALI_PAIR_DEP_KIB:-81920}"   # 80 MiB
# ESPs below this total cannot hold two Kali kernel pairs, so routine kernel
# upgrades would hit ENOSPC - the post-conversion advisory explains the fix.
ESP_SMALL_TOTAL_KIB="${ESP_SMALL_TOTAL_KIB:-163840}"      # 160 MiB (2x pair)
# Empty means auto-select at conversion time: kali-linux-default when a desktop
# is present, else kali-linux-headless. Set the env var to force a choice.
KALI_METAPACKAGE="${KALI_METAPACKAGE:-}"
ASSUME_YES=false
RESUME=false
SKIP_PREFLIGHT=false
RECOVERY_KIND=""   # cause of the final wrapped-step failure: ""/esp/network/unknown
STEP_LOG=""        # captured output of the last failed step (path printed by on_exit)
FORCE_IPV4=false   # set when a failure log shows IPv6 'Network is unreachable'
MIRROR_FAILED_OVER=false  # sources switched to KALI_FALLBACK_MIRROR mid-run

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_RED='\033[0;31m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[1;33m'
    C_BLUE='\033[0;34m'; C_NC='\033[0m'
else
    C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_NC=''
fi
log()  { printf '%b\n' "${C_BLUE}[*]${C_NC} $*"; }
ok()   { printf '%b\n' "${C_GREEN}[+]${C_NC} $*"; }
warn() { printf '%b\n' "${C_YELLOW}[!]${C_NC} $*" >&2; }
err()  { printf '%b\n' "${C_RED}[x]${C_NC} $*" >&2; exit 1; }

usage() {
    cat << USAGE
upgrade-to-kali v${VERSION}
Convert a Debian 12+ (bookworm or newer) system into Kali Linux.

Usage: sudo upgrade-to-kali [OPTIONS]

Options:
  -y, --yes, --force   Skip the confirmation prompt (non-interactive).
  --skip-preflight     Skip the disk-space preflight checks.
  -h, --help           Show this help and exit.

This adds the Kali repository, DISABLES the Debian sources, runs a full
system upgrade against kali-rolling, and installs a Kali metapackage
(kali-linux-default when a desktop is present, else kali-linux-headless).
The base-system rebase is effectively irreversible - snapshot/back up first.

Before converting, a preflight checks free disk space. On systemd-boot
systems the kernel and full initrd are copied onto the EFI System Partition,
and Kali initrds are much larger than Debian's - a hopelessly small ESP
aborts the run. To make room the tool offers to remove stale or duplicate
boot files and surplus old kernels (never the running or the newest one),
and on virtual machines to write a persistent MODULES=dep + xz initramfs
config (revert instructions inside the written file) so the initrds shrink
enough to fit. If the kernel copy still hits ENOSPC mid-upgrade, the tool
cleans the ESP, then frees only as much space as needed (surplus kernels
first, smaller initrds second) and retries once on its own.

A failure that instead looks like a mirror/network problem (unreachable or
half-synced mirror, broken IPv6 routing) gets delayed retries: the package
lists are refreshed in between, IPv4 is forced when IPv6 is the culprit,
and the last retry switches to the kali.download CDN mirror (unless
KALI_MIRROR is set). Cached packages are kept, so retries and re-runs only
fetch what is still missing.

If a conversion is interrupted anyway, a marker is left at ${STATE_FILE} and
re-running 'sudo upgrade-to-kali' repairs dpkg and resumes the conversion.
Without a terminal on stdin, --yes is required.
USAGE
}

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            -y|--yes|--force) ASSUME_YES=true ;;
            --skip-preflight) SKIP_PREFLIGHT=true ;;
            -h|--help) usage; exit 0 ;;
            *) usage; err "Unknown option: $1" ;;
        esac
        shift
    done
}

# Read key $2 from key=value file $1 (empty when absent/unreadable).
kv_get() {
    [ -r "$1" ] || return 0
    grep -E "^$2=" "$1" 2>/dev/null | head -1 | cut -d= -f2- || true
}

# Read KEY from an os-release-format file: kv_get plus quote-stripping.
osr() {
    local l
    l=$(kv_get "$OS_RELEASE_FILE" "$1")
    l="${l%\"}"; l="${l#\"}"
    printf '%s' "$l"
}

# True when dpkg has no half-installed/unconfigured packages (apt is usable).
dpkg_consistent() { [ -z "$(dpkg --audit 2>/dev/null)" ]; }

check_already_kali() {
    if [ "$(osr ID || true)" = "kali" ]; then
        ok "System already reports as Kali Linux ($(osr PRETTY_NAME || true)). Nothing to do."
        exit 0
    fi
}

check_supported_distro() {
    local id id_like ver major
    id="$(osr ID || true)"
    id_like="$(osr ID_LIKE || true)"
    ver="$(osr VERSION_ID || true)"
    if [ "$id" != "debian" ] && ! printf '%s' "$id_like" | grep -qw debian; then
        err "This tool only supports Debian (detected ID='$id' ID_LIKE='$id_like')."
    fi
    if [ "$id" = "ubuntu" ] || printf '%s' "$id_like" | grep -qw ubuntu; then
        err "Ubuntu is not supported. Kali requires a Debian base."
    fi
    major="${ver%%.*}"
    if [[ "$major" =~ ^[0-9]+$ ]]; then
        if [ "$major" -lt 12 ]; then
            err "Debian $ver detected; this tool requires Debian 12 (bookworm) or newer."
        elif [ "$major" -eq 12 ]; then
            warn "Debian 12 (bookworm) detected: rebasing to kali-rolling skips a Debian"
            warn "release, so it is a larger jump than from 13. Back up first and expect a longer run."
        fi
    fi
}

confirm() {
    $ASSUME_YES && return 0
    if $RESUME; then
        warn "This will RESUME the interrupted conversion to Kali (marker: $STATE_FILE)."
    else
        warn "This will REBASE this system onto Kali Linux (kali-rolling)."
    fi
    warn "It disables the Debian repositories and upgrades every base package."
    warn "This is effectively IRREVERSIBLE. Make a snapshot/backup first."
    printf 'Type YES to proceed: '
    local r
    read -r r || err "No input available (non-interactive?). Re-run with --yes."
    [ "$r" = "YES" ] || err "Aborted by user."
}

# Small yes/no prompt for individual remediation steps; auto-yes under --yes.
ask_yn() {
    if $ASSUME_YES; then log "$1 -> yes (--yes)"; return 0; fi
    local r
    printf '%s [Y/n] ' "$1"
    read -r r || return 1   # EOF = no
    [ -z "$r" ] || [ "$r" = "y" ] || [ "$r" = "Y" ]
}

# Default-No variant for risky removals; deliberately NOT auto-answered by
# --yes (a wrong yes could delete another OS's boot files).
ask_yn_no() {
    local r
    printf '%s [y/N] ' "$1"
    read -r r || return 1
    [ "$r" = "y" ] || [ "$r" = "Y" ]
}

# Non-interactive apt-get: lock-wait + safe conffile handling + bounded
# download retries (a full-upgrade fetches hundreds of packages - one
# transient mirror hiccup must not abort the conversion).
apt_ni() {
    local extra=()
    $FORCE_IPV4 && extra=(-o Acquire::ForceIPv4=true)
    DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get \
        -o DPkg::Lock::Timeout=300 -o Acquire::Retries=3 \
        -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold \
        "${extra[@]}" "$@"
}

# Timestamped copies go to $BACKUP_DIR - outside sources.list.d, so apt does
# not print "N: Ignoring file ..." notices about them.
backup_file() {
    local f="$1"
    [ -f "$f" ] || return 0
    mkdir -p "$BACKUP_DIR"
    cp -a "$f" "$BACKUP_DIR/$(basename "$f").backup.$(date +'%Y-%m-%d_%H-%M-%S')"
}

# Move backup/disabled artifacts a v1.0.x run left inside sources.list.d into
# $BACKUP_DIR - they make apt print "N: Ignoring file ..." notices on every
# apt invocation. Called from main so already-converted systems (where the
# litter actually lives) get cleaned too.
sweep_legacy_backups() {
    local litter
    litter=$(find "$APT_DIR/sources.list.d" -maxdepth 1 -type f \
        \( -name '*.backup.*' -o -name '*.disabled-by-upgrade-to-kali' \) 2>/dev/null || true)
    [ -n "$litter" ] || return 0
    mkdir -p "$BACKUP_DIR"
    printf '%s\n' "$litter" | xargs -d '\n' mv -t "$BACKUP_DIR"
    log "Moved old upgrade-to-kali backup files to $BACKUP_DIR (silences apt notices)"
}

# --- Disk-space preflight ---------------------------------------------------
# On systemd-boot systems kernel-install copies the kernel AND the full initrd
# onto the EFI System Partition, and Kali's MODULES=most initrds (~200 MB) are
# far larger than Debian's - on the small ESPs of cloud images (e.g.
# DigitalOcean) the copy fails mid-upgrade and leaves dpkg half-configured.
# Detect that layout, make room (stale-copy cleanup, MODULES=dep on VMs), or
# abort with guidance BEFORE anything irreversible happens.

# A missing systemd-detect-virt (rc 127) counts as "not a VM" - conservative,
# since the MODULES=dep remediation is only safe when hardware cannot change.
is_vm() {
    systemd-detect-virt --vm --quiet 2>/dev/null
}

# kernel-install entry token: explicit token file first (doubles as the test
# override), then kernel-install's own resolution - the authoritative source,
# covering install.conf ENTRY_TOKEN= and os-release IMAGE_ID/ID modes
# (systemd 251+, so present on Debian 12) - then the machine id. Same
# tool-first layering as find_esp's bootctl call. Memoized in _ENTRY_TOKEN:
# several callers (including per-item removal loops) need it, it cannot change
# mid-run, and the kernel-install exec is the expensive step.
entry_token() {
    if [ -z "${_ENTRY_TOKEN+x}" ]; then
        if [ -s "$ENTRY_TOKEN_FILE" ]; then
            _ENTRY_TOKEN=$(cat "$ENTRY_TOKEN_FILE")
        else
            _ENTRY_TOKEN=$(kernel-install --print-entry-token 2>/dev/null) || _ENTRY_TOKEN=""
            if [ -z "$_ENTRY_TOKEN" ] && [ -s "$MACHINE_ID_FILE" ]; then
                _ENTRY_TOKEN=$(cat "$MACHINE_ID_FILE")
            fi
        fi
    fi
    printf '%s' "$_ENTRY_TOKEN"
}

# Print the ESP mountpoint, or nothing when there is none (BIOS boot).
# Fallback order mirrors kernel-install's $BOOT search; autofs is accepted
# because newer Debian automounts the ESP (the later path accesses in
# kernels_on_esp/clean_stale_esp_copies trigger the mount before df runs).
find_esp() {
    if [ -n "$ESP_PATH" ]; then printf '%s' "$ESP_PATH"; return 0; fi
    local p d t
    p=$(bootctl --print-esp-path 2>/dev/null || true)   # absent bootctl -> empty
    if [ -z "$p" ]; then
        for d in /efi /boot /boot/efi; do
            t=$(findmnt -n -o FSTYPE "$d" 2>/dev/null || true)
            case "$t" in vfat|autofs) p="$d"; break ;; esac
        done
    fi
    printf '%s' "$p"
}

# True when kernel-install copies kernels+initrds onto the ESP ($1).
# Version dirs hold `linux`/`initrd` (upstream kernel-install naming) or
# `vmlinuz-<ver>`/`initrd.img-<ver>` (Debian's systemd-boot hook naming) -
# keep the naming variants in sync across all four sites that encode them:
# kernels_on_esp, esp_token_dirs, esp_copy_intact, clean_stale_esp_copies.
kernels_on_esp() {
    local esp="$1" token
    token=$(entry_token)
    if [ -n "$token" ]; then
        if compgen -G "$esp/$token/*/linux" > /dev/null || \
           compgen -G "$esp/$token/*/vmlinuz-*" > /dev/null; then return 0; fi
    fi
    if compgen -G "$esp/loader/entries/*.conf" > /dev/null; then return 0; fi
    # Debian's systemd-boot package hooks: the exact mechanism that copies
    # kernels/initrds during dpkg configure, even while the ESP is still empty.
    [ -e /etc/kernel/postinst.d/zz-systemd-boot ] && return 0
    [ -e /etc/initramfs/post-update.d/systemd-boot ] && return 0
    return 1
}

# Top-level ESP dirs holding BLS kernel copies (the current entry token,
# former machine-ids, other installs sharing the ESP), one per line. Detected
# by content - version subdirs with a kernel (`linux`/`vmlinuz-*`) or an
# initrd (a mid-copy ENOSPC can leave a version dir holding only a truncated
# initrd) - so EFI/ and loader/ are naturally excluded. Naming variants
# shared with kernels_on_esp (all four sites listed there - keep in sync).
esp_token_dirs() {
    local esp="$1" d
    for d in "$esp"/*/; do
        [ -d "$d" ] || continue
        if compgen -G "${d}*/linux" > /dev/null || \
           compgen -G "${d}*/vmlinuz-*" > /dev/null || \
           compgen -G "${d}*/initrd*" > /dev/null; then
            printf '%s\n' "${d%/}"
        fi
    done
}

# True when any candidate file ($2..) exists with the same size as $1.
any_size_match() {
    local src="$1" want f
    shift
    [ -f "$src" ] || return 1
    want=$(stat -c %s "$src")
    for f in "$@"; do
        if [ -f "$f" ] && [ "$(stat -c %s "$f")" = "$want" ]; then return 0; fi
    done
    return 1
}

# True when $esp/$2/$3 holds a complete copy of local kernel version $3:
# kernel and initrd both present (either naming variant) and sizes matching
# the /boot sources. Naming variants shared with kernels_on_esp (all four
# sites listed there - keep in sync).
esp_copy_intact() {
    local d="$1/$2/$3"
    any_size_match "$BOOT_DIR/vmlinuz-$3" "$d/linux" "$d/vmlinuz-$3" && \
        any_size_match "$BOOT_DIR/initrd.img-$3" "$d"/initrd*
}

free_kib() {
    df -Pk "$1" | awk 'NR==2 {print $4}'
}

total_kib() {
    df -Pk "$1" | awk 'NR==2 {print $2}'
}

# Largest du -k of the given files; 0 when none exist.
max_file_kib() {
    local m=0 f s
    for f in "$@"; do
        [ -f "$f" ] || continue
        s=$(du -k "$f" | cut -f1)
        if [ "$s" -gt "$m" ]; then m=$s; fi
    done
    printf '%s' "$m"
}

# All kernel versions present in /boot, one per line.
boot_kernel_versions() {
    local f
    for f in "$BOOT_DIR"/vmlinuz-*; do
        [ -f "$f" ] || continue
        printf '%s\n' "${f##*/vmlinuz-}"
    done
}

newest_boot_kernel() {
    local newest="" v
    while IFS= read -r v; do
        if [ -z "$newest" ] || dpkg --compare-versions "$v" gt "$newest"; then newest="$v"; fi
    done < <(boot_kernel_versions)
    printf '%s' "$newest"
}

# All /boot kernel versions except the newest, one per line.
nonnewest_boot_kernels() {
    local newest v
    newest=$(newest_boot_kernel)
    while IFS= read -r v; do
        if [ "$v" != "$newest" ]; then printf '%s\n' "$v"; fi
    done < <(boot_kernel_versions)
}

# The conversion-installed kernel: any /boot version newer than the baseline
# recorded in the state marker (empty before the marker exists or before the
# upgrade installs one). Vendor naming is deliberately not used - Kali kernel
# ABIs lacked a "kali" substring for the whole 6.6 era.
conversion_kernel() {
    local baseline newest
    baseline=$(kv_get "$STATE_FILE" baseline_kernel)
    newest=$(newest_boot_kernel)
    [ -n "$baseline" ] && [ -n "$newest" ] || return 0
    if dpkg --compare-versions "$newest" gt "$baseline"; then printf '%s' "$newest"; fi
    return 0
}

# KiB of one kernel version's ($1) /boot pair: vmlinuz plus (largest) initrd.
pair_kib() {
    printf '%s' $(( $(max_file_kib "$BOOT_DIR/vmlinuz-$1") + $(max_file_kib "$BOOT_DIR/initrd.img-$1"*) ))
}

# Estimated KiB the incoming Kali kernel+initrd needs on the ESP ($2).
# $1 = most|dep (the initramfs MODULES policy the estimate is for).
# Once the conversion has installed its kernel (conversion_kernel), measure:
# staged intact under the current token means nothing is left to copy (need
# 0); else its pair plus ESP_HEADROOM_PCT - ESP copies overwrite in place,
# so free space only has to absorb roughly one extra pair (a newer version
# arriving mid-upgrade). Before that there is nothing to measure, so guess
# the incoming pair itself: the local pair predicts nothing (a Debian cloud
# kernel's ~30 MB initrd vs. Kali's ~200 MB one), so the dep guess is
# ESP_KALI_PAIR_DEP_KIB and the most guess keeps 2x-the-local-pair with the
# Debian trixie release notes' "at least 300 MB free" floor. Either guess
# grows by the newest local pair when that kernel has no intact copy under
# the CURRENT entry token yet: the next hook run then ADDS a copy alongside
# the former-token one instead of overwriting in place (see
# clean_stale_esp_copies).
esp_required_kib() {
    local policy="$1" esp="$2" newest need
    newest=$(conversion_kernel)
    if [ -n "$newest" ]; then
        if esp_copy_intact "$esp" "$(entry_token)" "$newest"; then
            need=0
        else
            need=$(( $(pair_kib "$newest") * (100 + ESP_HEADROOM_PCT) / 100 ))
        fi
    else
        case "$policy" in
            dep) need="$ESP_KALI_PAIR_DEP_KIB" ;;
            *)   need=$(( ( $(max_file_kib "$BOOT_DIR"/vmlinuz-*) + $(max_file_kib "$BOOT_DIR"/initrd.img-*) ) * 2 ))
                 if [ "$need" -lt "$ESP_FLOOR_MOST_KIB" ]; then need="$ESP_FLOOR_MOST_KIB"; fi ;;
        esac
        newest=$(newest_boot_kernel)
        if [ -n "$newest" ] && ! esp_copy_intact "$esp" "$(entry_token)" "$newest"; then
            need=$(( need + $(pair_kib "$newest") ))
        fi
    fi
    printf '%s' "$need"
}

# Logs the ESP's ($1) free space vs. the measured/estimated need for
# MODULES=$2; true when it fits.
esp_fits() {
    local esp="$1" policy="$2" need free mode
    need=$(esp_required_kib "$policy" "$esp")
    free=$(free_kib "$esp")
    mode="estimated"
    if [ -n "$(conversion_kernel)" ]; then mode="measured"; fi
    log "ESP free: $((free / 1024)) MiB; $mode need (MODULES=$policy): $((need / 1024)) MiB"
    [ "$free" -ge "$need" ]
}

# The MODULES policy in effect for newly generated initrds.
effective_policy() {
    if [ -f "$MODULES_CONF" ]; then printf 'dep'; else printf 'most'; fi
}

# True when both files exist but their sizes differ (a mid-copy ENOSPC leftover).
size_mismatch() {
    [ -f "$1" ] && [ -f "$2" ] && [ "$(stat -c %s "$1")" != "$(stat -c %s "$2")" ]
}

# Remove provably-stale boot files from the ESP (prompted): version dirs for
# kernels that no longer exist locally, truncated/partial copies whose size
# differs from the /boot source (what a mid-copy ENOSPC leaves behind), and
# former-token duplicates. All token dirs are scanned, not just the current
# one: cloud images regenerate the machine id on first boot, so image-build
# copies live under a former token, invisible to a current-token-only scan
# and duplicated (not overwritten) by the first kernel-install run. A foreign
# dir is a removable duplicate only when its version already has an intact
# current-token copy - before the first regen it is the only bootable entry.
# Foreign dirs for versions unknown to this OS may belong to ANOTHER install
# sharing the ESP: separate default-No prompt, never auto-answered by --yes.
# Safe because the source of truth stays in $BOOT_DIR - dpkg configure and the
# initramfs post-update hook re-copy fresh files. Must run before measuring
# free space AND before any resume repair: dpkg --configure -a re-triggers
# the same ENOSPC otherwise. Always returns 0 (callers run bare under set -e).
clean_stale_esp_copies() {
    local esp="$1" cur tdir token verdir ver f it
    local stale=() foreign=()
    cur=$(entry_token)
    while IFS= read -r tdir; do
        token=$(basename "$tdir")
        for verdir in "$tdir"/*/; do
            [ -d "$verdir" ] || continue
            ver=$(basename "$verdir")
            if [ ! -e "$BOOT_DIR/vmlinuz-$ver" ] && [ ! -d "/lib/modules/$ver" ]; then
                # Version unknown to this OS: our orphan under the current
                # token, possibly another OS's kernel under a foreign one.
                if [ "$token" = "$cur" ]; then stale+=("$verdir"); else foreign+=("$verdir"); fi
                continue
            fi
            if [ "$token" != "$cur" ] && [ -n "$cur" ] && esp_copy_intact "$esp" "$cur" "$ver"; then
                stale+=("$verdir")   # former-token duplicate; the current-token copy wins
                continue
            fi
            for f in "$verdir"initrd*; do
                if size_mismatch "$f" "$BOOT_DIR/initrd.img-$ver"; then stale+=("$f"); fi
            done
            # Kernel copy: `linux` (upstream naming) or `vmlinuz-<ver>` (Debian
            # hook) - keep the naming variants in sync with kernels_on_esp
            # (which lists all four sites that encode them).
            for f in "$verdir"linux "$verdir"vmlinuz-*; do
                if size_mismatch "$f" "$BOOT_DIR/vmlinuz-$ver"; then stale+=("$f"); fi
            done
        done
    done < <(esp_token_dirs "$esp")
    if [ "${#stale[@]}" -gt 0 ]; then
        warn "Stale/incomplete/duplicate boot files on the ESP (safe to remove; re-copied from $BOOT_DIR):"
        printf '      %s\n' "${stale[@]}" >&2
        if ask_yn "Remove them to free ESP space?"; then
            for it in "${stale[@]}"; do
                case "$it" in
                    */) remove_esp_verdir "$it" ;;
                    *)  rm -f "$it" ;;
                esac
            done
            ok "Removed ${#stale[@]} stale ESP item(s)"
        fi
    fi
    if [ "${#foreign[@]}" -gt 0 ]; then
        if $ASSUME_YES; then
            log "Left untouched (kernels unknown to this OS, never auto-removed): ${foreign[*]}"
        else
            warn "ESP dirs whose kernels are unknown to this OS (they may belong to ANOTHER install sharing this ESP):"
            printf '      %s\n' "${foreign[@]}" >&2
            if ask_yn_no "Remove them? Only say yes if no other OS boots from this disk"; then
                for it in "${foreign[@]}"; do
                    remove_esp_verdir "$it"
                done
                ok "Removed ${#foreign[@]} foreign ESP dir(s)"
            fi
        fi
    fi
    return 0
}

# Kernel versions that are safe to drop: installed in /boot but neither the
# running kernel nor the newest one (bootctl's own eviction rule: never the
# booted entry, never the last remaining).
surplus_kernel_versions() {
    local running v
    running=$(uname -r)
    while IFS= read -r v; do
        if [ "$v" != "$running" ]; then printf '%s\n' "$v"; fi
    done < <(nonnewest_boot_kernels)
}

# Remove one version's ($3) files under one token dir ($2), plus only THAT
# token's loader entries (kernel-install names them <token>-<ver>[+tries].conf).
# Token-scoped on purpose: duplicate cleanup must not delete the current
# token's kept entry.
remove_esp_token_version() {
    local esp="$1" token="$2" ver="$3"
    rm -rf "${esp:?}/$token/$ver"
    rm -f "$esp/loader/entries/$token-$ver"*.conf
}

# remove_esp_token_version for a full version-dir path ($ESP/<token>/<ver>[/]).
remove_esp_verdir() {
    local d="${1%/}"
    remove_esp_token_version "$(dirname "$(dirname "$d")")" \
        "$(basename "$(dirname "$d")")" "$(basename "$d")"
}

# Remove a kernel version's ($2) boot files from the ESP ($1) everywhere:
# its version dir under every token dir plus any loader entry referencing it
# - mirroring what apt purge / kernel-install remove would have achieved.
remove_esp_version() {
    local esp="$1" ver="$2" tdir
    while IFS= read -r tdir; do
        remove_esp_token_version "$esp" "$(basename "$tdir")" "$ver"
    done < <(esp_token_dirs "$esp")
    rm -f "$esp"/loader/entries/*"$ver"*.conf
}

# Free a whole kernel+initrd pair per surplus kernel (prompted). With a
# healthy dpkg one batched apt purge does it cleanly (the kernel hooks remove
# the ESP copies and loader entries); mid-resume dpkg is broken and apt would
# refuse, so use the standalone canonical primitives instead:
# update-initramfs -d deregisters the version and deletes its initrd (so the
# initramfs triggers cannot re-copy it), kernel-install remove drops the ESP
# version dir and loader entry - and apt's autoremove finishes the package
# purge after the repair. Returns 0 only when kernels were actually removed,
# so callers can skip the re-measure otherwise.
remove_surplus_kernels() {
    local esp="$1" v
    local candidates=()
    mapfile -t candidates < <(surplus_kernel_versions)
    [ "${#candidates[@]}" -gt 0 ] || return 1
    warn "Kernels that are neither running nor newest are taking ESP space: ${candidates[*]}"
    ask_yn "Remove them to free ESP space (the running and the newest kernel are kept)?" || return 1
    if dpkg_consistent; then
        apt_ni purge -y "${candidates[@]/#/linux-image-}"
    else
        for v in "${candidates[@]}"; do
            update-initramfs -d -k "$v" 2>/dev/null || true
            if ! BOOT_ROOT="$esp" kernel-install remove "$v" 2>/dev/null; then
                remove_esp_version "$esp" "$v"
            fi
        done
    fi
    ok "Removed ${#candidates[@]} surplus kernel(s)"
}

# Persistent initramfs shrink policy: MODULES=dep (only this hardware's
# modules - offered on VMs only, where hardware does not change) plus
# COMPRESS=xz when available (smallest initrds; guarded because initramfs-
# tools aborts on a configured-but-missing compressor). Rewritten in full so
# older dep-only versions of the file pick up the compression on re-runs.
write_shrink_conf() {
    log "Writing $MODULES_CONF (MODULES=dep + xz compression)"
    mkdir -p "$INITRAMFS_CONF_DIR"
    cat > "$MODULES_CONF" << 'CONF'
# Written by upgrade-to-kali: MODULES=dep keeps initrds small enough for this
# system's small EFI System Partition (systemd-boot copies kernel+initrd there);
# COMPRESS=xz (when present) packs them hardest - slightly slower builds/boots.
# Safe on VMs, where the (virtual) hardware does not change.
# Revert: delete this file, then run: sudo update-initramfs -u -k all
MODULES=dep
CONF
    if command -v xz > /dev/null 2>&1; then
        printf 'COMPRESS=xz\n' >> "$MODULES_CONF"
    else
        warn "xz not found - initrds will use the default compressor (larger)"
    fi
}

# VM-only shrink remediation: prompt, write the conf, regenerate all initrds,
# then re-clean the ESP - the regen creates current-token copies, turning any
# pre-baked former-token pairs into reclaimable duplicates. $2=fatal aborts on
# a failed regen (preflight: pre-confirm, nothing converted yet); $2=tolerant
# warns and continues (recovery ladder: the retry is the verdict). True when
# the shrink was applied.
offer_shrink() {
    local esp="$1" policy="$2"
    is_vm || return 1
    warn "The ESP is too small for Kali's default (MODULES=most) initrds."
    ask_yn "Write MODULES=dep + xz to $MODULES_CONF and regenerate initrds now (VM-safe, persistent)?" || return 1
    write_shrink_conf
    log "Regenerating all initrds with the shrink policy"
    if ! update-initramfs -u -k all; then
        if [ "$policy" = fatal ]; then
            warn "update-initramfs failed - the ESP is likely still too full."
            warn "Free ESP space manually (purge old kernels, remove stale files), then re-run."
            err "Could not regenerate a smaller initrd."
        fi
        warn "update-initramfs failed (likely still ENOSPC) - continuing recovery"
    fi
    clean_stale_esp_copies "$esp"
    return 0
}

# Compact per-token-dir usage breakdown - makes failed-run logs diagnosable.
# Always returns 0 (purely informational).
log_esp_inventory() {
    local esp="$1"
    local total free
    log "ESP inventory ($esp):"
    du -sk "$esp"/*/ 2>/dev/null | awk '{printf "      %5d MiB  %s\n", $1/1024, $2}' >&2 || true
    total=$(total_kib "$esp" 2>/dev/null) || total=0
    free=$(free_kib "$esp" 2>/dev/null) || free=0
    log "      total $((${total:-0} / 1024)) MiB, free $((${free:-0} / 1024)) MiB"
    return 0
}

preflight() {
    if $SKIP_PREFLIGHT; then
        warn "Preflight checks skipped (--skip-preflight)"
        return 0
    fi
    # Root filesystem: warn only - the rebase downloads ~2 GB of archives and
    # installs several GB on top.
    local rootfree
    rootfree=$(free_kib /)
    if [ "$rootfree" -lt "$ROOT_MIN_FREE_KIB" ]; then
        warn "Low free space on /: $((rootfree / 1024)) MiB (recommended: >= $((ROOT_MIN_FREE_KIB / 1024)) MiB)."
    fi
    # ESP: fatal when kernels are copied there and room cannot be made.
    # Remediation rung order (clean -> surplus kernels -> shrink) mirrors
    # esp_recovery_ladder - keep the two in sync.
    local esp
    esp=$(find_esp)
    if [ -z "$esp" ]; then
        log "No EFI System Partition detected (BIOS boot) - ESP check skipped."
        return 0
    fi
    if ! kernels_on_esp "$esp"; then
        log "Kernels are not copied to the ESP (GRUB layout) - ESP check skipped."
        return 0
    fi
    log "systemd-boot layout detected: kernels and initrds are copied to $esp"
    log_esp_inventory "$esp"
    clean_stale_esp_copies "$esp"
    if esp_fits "$esp" most; then
        ok "ESP has enough free space."
        return 0
    fi
    if remove_surplus_kernels "$esp" && esp_fits "$esp" most; then
        ok "ESP has enough free space."
        return 0
    fi
    local free
    offer_shrink "$esp" fatal || true
    # Verdict under the dep policy when it is in effect - from this run's
    # shrink or a previous one (the conf persists across resumes, so the
    # verdict must not depend on re-answering the prompt). Tight-but-
    # plausible proceeds: the dep need is a guess about a kernel that does
    # not exist yet, and a mid-upgrade ENOSPC now recovers and retries
    # in-run - do not block a conversion that empirically succeeds on
    # ~105 MiB cloud ESPs. Below the hard floor is hopeless and aborts.
    if [ "$(effective_policy)" = dep ]; then
        if esp_fits "$esp" dep; then
            ok "ESP has enough free space with MODULES=dep."
            return 0
        fi
        free=$(free_kib "$esp")
        if [ "$free" -ge "$ESP_FLOOR_DEP_KIB" ]; then
            warn "ESP space is tight ($((free / 1024)) MiB free). Continuing anyway - if the kernel"
            warn "copy still hits ENOSPC mid-upgrade, the tool cleans up, shrinks and retries."
            return 0
        fi
    fi
    warn "The ESP ($esp) does not have enough free space for the Kali kernel+initrd."
    warn "Fix manually, then re-run one of:"
    warn "  - echo MODULES=dep > $MODULES_CONF && update-initramfs -u -k all"
    warn "    (VM-safe; on changing hardware prefer COMPRESS=xz in /etc/initramfs-tools/initramfs.conf)"
    warn "  - purge old kernels: dpkg -l 'linux-image-*', then apt-get purge <old versions>"
    warn "  - remove leftover version dirs under $esp/<machine-id>/ ('bootctl cleanup' on systemd >= 253)"
    warn "  - grow the ESP (needs repartitioning)"
    err "Aborting before any conversion step (nothing was converted)."
}

# --- Conversion state & failure guidance ------------------------------------

# Printed on any nonzero exit after the conversion has started (set -e death,
# err(), or Ctrl-C - bash runs EXIT traps on fatal signals too).
on_exit() {
    local rc=$?
    [ "$rc" -eq 0 ] && return 0
    warn "Conversion did NOT complete (exit code $rc). The system may be part-Debian, part-Kali."
    if [ -n "$STEP_LOG" ] && [ -s "$STEP_LOG" ]; then
        warn "Output of the failed step was kept at $STEP_LOG for inspection."
    fi
    case "$RECOVERY_KIND" in
        network)
            warn "The failure looked like a mirror/network problem, not a disk-space one,"
            warn "and the automatic delayed retries did not get through - check DNS,"
            warn "firewall/proxy, and general connectivity."
            $MIRROR_FAILED_OVER && warn "(The $KALI_FALLBACK_MIRROR CDN fallback was tried too.)"
            warn "Downloaded packages are cached, so re-running 'sudo upgrade-to-kali'"
            warn "resumes and only fetches what is still missing; to pin a mirror:"
            warn "    sudo KALI_MIRROR=$KALI_FALLBACK_MIRROR upgrade-to-kali"
            ;;
        esp|unknown)
            warn "An automatic ESP cleanup and retry already ran and did not suffice; if a"
            warn "re-run fails the same way, free ESP space manually first (see below)."
            ;;
    esac
    warn "Recover manually:"
    warn "  1. sudo dpkg --configure -a"
    warn "  2. sudo apt-get -f install"
    warn "  3. sudo apt-get update && sudo apt-get -y full-upgrade"
    warn "  4. sudo apt-get install -y kali-archive-keyring ${KALI_METAPACKAGE:-kali-linux-headless}"
    warn "  5. sudo apt-get -y autoremove --purge"
    warn "Or simply re-run 'sudo upgrade-to-kali': the state marker ($STATE_FILE) was kept,"
    warn "so it will repair dpkg and resume. If this failure was 'No space left on device'"
    warn "on the EFI partition, the re-run's preflight offers cleanup and a smaller initrd."
}

mark_conversion_started() {
    mkdir -p "$(dirname "$STATE_FILE")"
    {
        printf 'version=%s\n' "$VERSION"
        printf 'started=%s\n' "$(date -Is)"
        printf 'metapackage=%s\n' "$KALI_METAPACKAGE"
        # Any /boot kernel newer than this was installed by the conversion -
        # esp_required_kib measures it instead of guessing.
        printf 'baseline_kernel=%s\n' "$(newest_boot_kernel)"
    } > "$STATE_FILE"
    trap on_exit EXIT
}

finish_conversion() {
    rm -f "$STATE_FILE"
    rmdir "$(dirname "$STATE_FILE")" 2>/dev/null || true
    trap - EXIT
}

# True when no conversion work remains: the system identifies as Kali, dpkg
# is consistent, and the recorded metapackage is installed. Used on resume to
# recognize a marker whose conversion was finished out-of-band (manually, or
# by a crash after the last real step) - without this, the preflight could
# block the tool from ever converging and cleaning its own marker.
conversion_complete() {
    [ "$(osr ID || true)" = "kali" ] || return 1
    dpkg_consistent || return 1
    local mp
    mp=$(kv_get "$STATE_FILE" metapackage)
    [ -z "$mp" ] || dpkg -s "$mp" 2>/dev/null | grep -q '^Status: install ok installed'
}

# Resume: put dpkg/apt back into a consistent state before re-running the
# (idempotent) conversion steps. The explicit || return 1 keeps a dpkg
# failure fatal even when the caller runs this errexit-suppressed (the
# retry wrapper does), instead of masking it behind a passing apt -f.
repair_packages() {
    log "Repairing any half-configured packages first"
    dpkg --configure -a || return 1
    apt_ni -y -f install
}

# --- In-run ENOSPC recovery --------------------------------------------------
# A mid-upgrade "No space left on device" on the ESP wedges dpkg; previously
# the tool exited with guidance and required a manual resume run. The ladder
# below automates that field-proven recovery between two attempts of the
# failed step, so a single invocation converges even on the ~105 MiB ESPs of
# fresh cloud droplets.

# Last resort: drop every non-newest kernel's ESP copies and loader entries
# from ALL token dirs - after the ladder's surplus purge that is normally
# just the RUNNING kernel. ESP copies only, deliberately not a package
# purge: removing the running kernel's /lib/modules would make every module
# load fail (firewall, filesystems) for the rest of the conversion. The
# /boot sources stay, and the newest kernel's files land via the retried
# dpkg configure - but between eviction and that copy a crash would leave no
# bootable entry, hence the explicit warning. Only our own /boot versions
# are targeted; another OS's dirs hold different versions.
evict_nonnewest_esp_copies() {
    local esp="$1" v
    local victims=()
    mapfile -t victims < <(nonnewest_boot_kernels)
    [ "${#victims[@]}" -gt 0 ] || return 0
    warn "Last resort: remove the ESP boot files of non-newest kernel(s), usually"
    warn "including the running one: ${victims[*]}"
    warn "Their /boot sources stay and the newest kernel is copied right after - but if"
    warn "this machine crashes before that copy finishes, it cannot boot on its own."
    ask_yn "Evict them from the ESP to make room for the newest kernel?" || return 0
    for v in "${victims[@]}"; do
        remove_esp_version "$esp" "$v"
    done
    ok "Evicted ${#victims[@]} kernel version(s) from the ESP"
    return 0
}

# Best-effort remediation between the two attempts of a failed step: clean ->
# remove surplus kernels -> shrink -> evict -> repair, mirroring the manual
# recovery that resume mode is built on, cheapest and safest space first.
# The clean/surplus/shrink rung order mirrors preflight's ESP remediation -
# keep the two in sync (evict + repair are recovery-only tail rungs).
# Cleaning MUST precede the dpkg repair - configure re-triggers the ESP copy,
# and the truncated leftover otherwise re-breaks it. A fit check gates every
# mutating rung, so remediation stops as soon as there is room (need is 0
# once the newest pair landed intact, and a non-ESP failure like a mirror
# hiccup mutates nothing): the dep shrink is only offered when kernel
# removal did not suffice, and the running kernel's ESP copies stay the last
# resort. The policy is re-resolved before each check - offer_shrink may
# have just written the conf. Every rung is idempotent, prompted where it
# mutates, and guarded: the ladder never aborts the run itself; the retry
# after it is the real verdict.
esp_recovery_ladder() {
    local esp
    esp=$(find_esp)
    if [ -n "$esp" ] && kernels_on_esp "$esp"; then
        log_esp_inventory "$esp"
        clean_stale_esp_copies "$esp"
        if ! esp_fits "$esp" "$(effective_policy)"; then
            remove_surplus_kernels "$esp" || true
            if ! esp_fits "$esp" "$(effective_policy)"; then
                offer_shrink "$esp" tolerant || true
                if ! esp_fits "$esp" "$(effective_policy)"; then
                    evict_nonnewest_esp_copies "$esp"
                fi
            fi
        fi
    fi
    # Generic dpkg/apt repair - also what makes non-ESP failures retryable.
    repair_packages || true
    return 0
}

# Classify a failed step from its captured output: esp | network | unknown.
# Pure (reads only the file) so it is unit-testable via sourcing. ENOSPC is
# checked FIRST - a mixed failure (dead mirror AND full ESP) needs space,
# not patience. The network list covers dead/unreachable mirrors, DNS blips,
# and mid-sync mirrors (hash/size mismatch - the fix is the same: refresh
# lists and retry); pool-file 404s match via "Failed to fetch".
classify_step_failure() {
    if grep -qi 'No space left on device' "$1" 2>/dev/null; then
        printf 'esp\n'
    elif grep -qiE 'Unable to fetch|Failed to fetch|Cannot initiate the connection|Network is unreachable|Temporary failure resolving|Connection timed out|Connection refused|Connection reset by peer|Could not connect|Could not resolve|Error reading from server|Hash Sum mismatch|File has unexpected size|Mirror sync in progress' "$1" 2>/dev/null; then
        printf 'network\n'
    else
        printf 'unknown\n'
    fi
}

# apt tried an IPv6 address (the parenthesized address contains a colon) and
# the kernel said the network is unreachable: broken v6 routing, common on
# VMs/VPNs. Standard remedy is ForceIPv4 - safe, because an IPv6-only host
# was already failing over v4 anyway.
log_shows_broken_ipv6() {
    grep -qE 'connection to [^ ]* ?\([0-9a-fA-F:]*:[0-9a-fA-F:]*\)[^(]*\(101: Network is unreachable\)' "$1" 2>/dev/null
}

# Run a conversion step, teeing its output (still streamed) to a temp log so
# a failure can be classified and the matching recovery chosen: the ESP
# ladder for ENOSPC, delayed retries for mirror/network fetch errors (apt's
# cache means a retry only fetches what is still missing - deliberately no
# --fix-missing, a distro rebase must not proceed with missing packages),
# and the ladder + one retry for anything else (previous behavior). The
# failure is re-classified after every attempt (a network failure's retry
# can hit ENOSPC next), with hard budgets - the ladder runs at most once,
# network retries at most NET_RETRIES times. Each network retry refreshes
# the lists so the http.kali.org redirector can hand out a healthier
# mirror, forces IPv4 once broken v6 routing is seen, and the last one
# fails over to the kali.download CDN (never overriding a user-pinned
# KALI_MIRROR). When the budgets are spent the last rc is
# returned and dies under set -e at the call site; RECOVERY_KIND (set only
# then, so a recovered step never poisons a later failure's message) and
# STEP_LOG steer on_exit's guidance.
# NOTE: the step runs on the left of a pipeline, i.e. in a subshell -
# wrapped steps must not mutate globals (apt_ni/repair_packages do not).
# The wrapper body itself runs in the main shell, which is why its
# FORCE_IPV4/KALI_MIRROR mutations stick.
run_step_with_recovery() {
    local rc kind logf ladder_ran=false net_left="$NET_RETRIES" delay="$NET_RETRY_DELAY"
    logf=$(mktemp) || logf=/dev/null   # degrades to kind=unknown
    STEP_LOG="$logf"
    while :; do
        rc=0
        "$@" 2>&1 | tee "$logf" || rc=${PIPESTATUS[0]}
        if [ "$rc" -eq 0 ]; then
            [ "$logf" = /dev/null ] || rm -f "$logf"
            STEP_LOG=""
            return 0
        fi
        kind=$(classify_step_failure "$logf")
        case "$kind" in
            network)
                if [ "$net_left" -gt 0 ]; then
                    net_left=$((net_left - 1))
                    warn "Step failed (exit $rc): $* - looks like a mirror/network failure,"
                    warn "not a disk-space one. Retrying in ${delay}s (cached .debs are kept)."
                    if ! $FORCE_IPV4 && log_shows_broken_ipv6 "$logf"; then
                        FORCE_IPV4=true
                        warn "IPv6 routing looks broken - forcing IPv4 for all further apt calls"
                    fi
                    # MIRROR_FAILED_OVER is global: net_left resets per wrapped
                    # step, so a later step's failure must not redo the failover.
                    if [ "$net_left" -eq 0 ] && ! $KALI_MIRROR_PINNED && ! $MIRROR_FAILED_OVER; then
                        MIRROR_FAILED_OVER=true
                        KALI_MIRROR="$KALI_FALLBACK_MIRROR"
                        warn "Failing over to the CDN mirror $KALI_MIRROR for the last retry"
                        warn "(it stays in your sources afterwards - both are official Kali mirrors)"
                        write_kali_sources
                    fi
                    sleep "$delay"; delay=$((delay * 2))
                    apt_ni update || true
                    log "Retrying: $*"
                    continue
                fi
                ;;
            esp|unknown)
                if ! $ladder_ran; then
                    ladder_ran=true
                    warn "Step failed (exit $rc): $* - attempting ESP recovery, then one retry"
                    esp_recovery_ladder || true
                    log "Retrying: $*"
                    continue
                fi
                ;;
        esac
        RECOVERY_KIND="$kind"
        return "$rc"
    done
}

# env var > state file > desktop detection. Resolved before the marker is
# written (so the marker only pre-exists on resume) and persisted in it, so a
# resumed run converges on the same choice.
resolve_metapackage() {
    if [ -z "$KALI_METAPACKAGE" ]; then
        KALI_METAPACKAGE=$(kv_get "$STATE_FILE" metapackage)
    fi
    if [ -z "$KALI_METAPACKAGE" ]; then
        if has_desktop; then KALI_METAPACKAGE=kali-linux-default; else KALI_METAPACKAGE=kali-linux-headless; fi
    fi
    log "Target Kali metapackage: $KALI_METAPACKAGE"
}

install_keyring() {
    log "Installing Kali archive keyring -> $KEYRING_PATH"
    local tmp; tmp=$(mktemp)
    # Bounded retries (default is 20 tries): same transient-failure policy as
    # apt_ni's Acquire::Retries - one network blip must not abort the conversion.
    if ! wget -q --tries=3 --waitretry=2 --retry-connrefused -O "$tmp" "$KEYRING_URL"; then
        rm -f "$tmp"; err "Failed to download Kali keyring from $KEYRING_URL"
    fi
    install -o root -g root -m 644 "$tmp" "$KEYRING_PATH"
    rm -f "$tmp"
}

write_kali_sources() {
    local dest="$APT_DIR/sources.list.d/kali.sources"
    mkdir -p "$APT_DIR/sources.list.d"
    cat > "$dest" << SRC
# Kali Linux repository (added by upgrade-to-kali)
# https://www.kali.org/docs/general-use/kali-apt-sources/
Types: deb
URIs: ${KALI_MIRROR}
Suites: kali-rolling
Components: main contrib non-free non-free-firmware
Signed-By: ${KEYRING_PATH}
SRC
    log "Wrote Kali repository -> $dest"
}

disable_debian_sources() {
    local deb822="$APT_DIR/sources.list.d/debian.sources"
    if [ -f "$deb822" ]; then
        # The mv itself preserves the unmodified file in $BACKUP_DIR, so no
        # separate backup copy is needed (unlike sources.list below, which
        # sed mutates in place).
        mkdir -p "$BACKUP_DIR"
        mv "$deb822" "$BACKUP_DIR/debian.sources.disabled-by-upgrade-to-kali"
        log "Disabled $deb822 (moved to $BACKUP_DIR)"
    fi
    local legacy="$APT_DIR/sources.list"
    if [ -f "$legacy" ] && grep -qE '^[[:space:]]*deb(-src)?[[:space:]]' "$legacy"; then
        backup_file "$legacy"
        sed -ri 's/^([[:space:]]*)(deb(-src)?[[:space:]])/\1#\2/' "$legacy"
        log "Commented out Debian entries in $legacy"
    fi
    local other
    other=$(find "$APT_DIR/sources.list.d" -maxdepth 1 -type f \
        \( -name '*.list' -o -name '*.sources' \) ! -name 'kali.sources' 2>/dev/null || true)
    if [ -n "$other" ]; then
        warn "Other repository files remain enabled (left untouched):"
        printf '%s\n' "$other" | sed 's/^/      /' >&2
        warn "Remove/disable them if apt later reports version conflicts."
    fi
}

# True when a graphical desktop is present (mirror of linux-setup's
# has_desktop_environment - keep the package lists in sync); picks
# kali-linux-default over -headless.
has_desktop() {
    if [ -d /usr/share/xsessions ] && [ -n "$(ls -A /usr/share/xsessions 2>/dev/null)" ]; then return 0; fi
    if [ -d /usr/share/wayland-sessions ] && [ -n "$(ls -A /usr/share/wayland-sessions 2>/dev/null)" ]; then return 0; fi
    if [ -s /etc/X11/default-display-manager ]; then return 0; fi
    if dpkg -l 2>/dev/null | grep -qE '^ii[[:space:]]+(xfce4|gnome-shell|kde-plasma-desktop|plasma-desktop|lxde-core|mate-desktop-environment|cinnamon)'; then return 0; fi
    return 1
}

# Success advisory for small ESPs: two kernel pairs never fit on them, so
# the NEXT kernel ABI upgrade would hit the same mid-upgrade ENOSPC while old
# and new coexist. Guidance only - the old kernel is the only known-good
# fallback until the new one has survived a reboot. Runs after the EXIT trap
# is gone, so every command is guarded: a cosmetic failure here must not turn
# a completed conversion into a nonzero exit.
post_conversion_esp_advice() {
    local esp total v old_pkgs=""
    esp=$(find_esp)
    [ -n "$esp" ] || return 0
    kernels_on_esp "$esp" || return 0
    total=$(total_kib "$esp" 2>/dev/null) || return 0
    [ -n "$total" ] && [ "$total" -lt "$ESP_SMALL_TOTAL_KIB" ] || return 0
    while IFS= read -r v; do
        old_pkgs="$old_pkgs linux-image-$v"
    done < <(nonnewest_boot_kernels)
    warn "This ESP ($esp, $((total / 1024)) MiB) is too small to hold two kernel+initrd"
    warn "pairs, so a FUTURE kernel upgrade can hit 'No space left on device' again"
    warn "while the old and the new version coexist."
    if [ -n "$old_pkgs" ]; then
        warn "After verifying the new kernel boots (sudo reboot, then uname -r), free the"
        warn "ESP by purging the old one(s):"
        warn "    sudo apt purge -y$old_pkgs"
    fi
    warn "Before each future kernel upgrade, purge the previous kernel first"
    warn "(dpkg -l 'linux-image-*', then: sudo apt purge <old versions>)."
    return 0
}

do_conversion() {
    # The keyring download needs only wget and the CA bundle, both present on
    # any normal install - skip refreshing the soon-to-be-disabled Debian
    # indexes unless something is actually missing.
    if ! command -v wget > /dev/null 2>&1 || [ ! -s /etc/ssl/certs/ca-certificates.crt ]; then
        log "Installing prerequisites (wget, ca-certificates)"
        apt_ni update
        apt_ni install -y wget ca-certificates
    fi
    install_keyring
    write_kali_sources
    disable_debian_sources
    log "Updating package lists from Kali"
    run_step_with_recovery apt_ni update
    log "Rebasing base system onto kali-rolling (this can take a while)..."
    run_step_with_recovery apt_ni -y full-upgrade
    log "Installing kali-archive-keyring and ${KALI_METAPACKAGE}"
    run_step_with_recovery apt_ni install -y kali-archive-keyring "$KALI_METAPACKAGE"
    log "Removing packages that are no longer required"
    apt_ni -y autoremove --purge
    # Drop the multi-GB .deb cache the rebase left behind. Best-effort: the
    # EXIT trap is still armed, and hygiene must not report a failed conversion.
    apt_ni clean || true
    finish_conversion
    ok "Conversion complete. New system identity:"
    grep -E '^(PRETTY_NAME|ID|VERSION)=' "$OS_RELEASE_FILE" | sed 's/^/    /'
    post_conversion_esp_advice
    warn "A reboot is recommended: sudo reboot"
}

main() {
    parse_args "$@"
    # Elevate before the checks so they, and the confirmation, run exactly once.
    if [ "$(id -u)" -ne 0 ]; then
        log "Elevating privileges with sudo..."
        exec sudo bash "$0" "$@"
    fi
    sweep_legacy_backups
    # A marker from an interrupted conversion switches to resume mode (checked
    # as root - the marker is root-owned); os-release may already report Kali
    # mid-conversion, so the already-Kali and distro checks are skipped.
    if [ -f "$STATE_FILE" ]; then
        RESUME=true
        if conversion_complete; then
            finish_conversion
            ok "Previous conversion is already complete - removed the leftover resume marker."
            exit 0
        fi
        warn "Interrupted conversion detected ($STATE_FILE) - resuming."
    else
        check_already_kali
        check_supported_distro
    fi
    # Prompts (remediations, the YES confirmation) need a terminal; without
    # one, reads would hang or mis-answer. Placed after the zero-work exits
    # so probing an already-converted box without --yes stays a friendly
    # exit 0, and before preflight so no remediation can mutate the system
    # on a run that could never be confirmed.
    if ! $ASSUME_YES && [ ! -t 0 ]; then
        err "stdin is not a terminal; re-run with --yes for unattended use."
    fi
    preflight
    resolve_metapackage
    confirm
    mark_conversion_started
    if $RESUME; then run_step_with_recovery repair_packages; fi
    do_conversion
}

# Run main only when executed, not when sourced (enables unit testing).
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
