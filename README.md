# upgrade-to-kali

A single self-contained Bash script that converts a Debian 12+ (bookworm or newer) system into Kali Linux in place. It checks your disk space before touching anything and digs itself out when the EFI partition runs full or a mirror goes down mid-upgrade. Interrupted runs resume where they left off.

> **Important**: This performs an effectively irreversible base-system rebase onto `kali-rolling`. Take a VM snapshot or backup first. It only works on Debian, not Ubuntu. From Debian 12 (bookworm) it's a larger jump than from 13, because the rebase skips a Debian release.

<!-- START doctoc generated TOC please keep comment here to allow auto update -->
<!-- DON'T EDIT THIS SECTION, INSTEAD RE-RUN doctoc TO UPDATE -->

- [Why this script](#why-this-script)
- [Requirements](#requirements)
- [Quick start](#quick-start)
- [Usage](#usage)
- [What it does](#what-it-does)
- [Disk-space preflight and ESP handling](#disk-space-preflight-and-esp-handling)
- [Mirror and network failures](#mirror-and-network-failures)
- [Resume after interruption](#resume-after-interruption)
- [Environment overrides](#environment-overrides)
- [Troubleshooting](#troubleshooting)
- [License](#license)
- [Acknowledgments](#acknowledgments)

<!-- END doctoc generated TOC please keep comment here to allow auto update -->

## Why this script

Guides that flip `/etc/apt/sources.list` to `kali-rolling` and run a full upgrade are easy to find. The interesting part is everything around that happy path, and that's what this script is for:

- It disables the Debian repositories rather than mixing them with Kali's, since repo mixing is explicitly unsupported by Kali and a common cause of broken conversions. The originals go to a backup directory instead of being deleted.
- The apt setup follows current Kali practice: a deb822 `kali.sources` file whose `Signed-By` points at the archive keyring, instead of the deprecated `apt-key`.
- It checks disk space before touching anything. On systemd-boot systems the kernel and full initrd land on the EFI System Partition, and Kali's initrds are several times larger than Debian's, so small cloud ESPs overflow mid-upgrade. The preflight detects that layout and makes room first.
- If the kernel copy still runs out of space mid-upgrade, the script recovers on its own: it cleans the ESP, frees only as much space as needed, repairs dpkg, and retries once.
- A failed step is diagnosed before it's retried. Out-of-space failures take the ESP ladder; mirror and network failures get delayed retries with a package-list refresh instead, so a dead mirror isn't mistaken for a full disk.
- Interrupted runs are resumable. The state marker survives the failure, so re-running repairs dpkg and continues with the same settings instead of starting over.
- It picks the metapackage to match the system (`kali-linux-default` with a desktop, `kali-linux-headless` without) and supports unattended use with `--yes`, which still never auto-answers the one genuinely dangerous question: whether to remove boot files that may belong to another OS.

## Requirements

- Debian 12 (bookworm) or newer, including testing/sid. Debian derivatives reporting `ID_LIKE=debian` pass the check; Ubuntu and its derivatives are rejected (Kali requires a Debian base).
- Root privileges (the script self-elevates with `sudo` when needed)
- Internet access (Kali keyring, `kali-rolling` repository)
- Roughly 6 GiB free on `/` recommended (checked, warn-only)

## Quick start

```bash
git clone https://github.com/c0ffee0wl/debian-upgrade-to-kali.git
cd debian-upgrade-to-kali
chmod +x upgrade-to-kali.sh
sudo ./upgrade-to-kali.sh          # asks for confirmation before the rebase
```

Or grab just the script (it has no other files as dependencies):

```bash
wget https://raw.githubusercontent.com/c0ffee0wl/debian-upgrade-to-kali/main/upgrade-to-kali.sh
chmod +x upgrade-to-kali.sh
sudo ./upgrade-to-kali.sh
```

Optionally install it as a command first:

```bash
sudo install -m 0755 upgrade-to-kali.sh /usr/local/bin/upgrade-to-kali
sudo upgrade-to-kali
```

## Usage

```bash
sudo ./upgrade-to-kali.sh              # interactive: type YES to proceed
sudo ./upgrade-to-kali.sh --yes        # non-interactive (required when stdin is not a terminal)
sudo ./upgrade-to-kali.sh --skip-preflight
./upgrade-to-kali.sh --help            # show help (works unprivileged)
```

| Option | Effect |
|---|---|
| `-y`, `--yes`, `--force` | Skip the confirmation prompt and auto-answer the remediation prompts with yes. Risky removals (boot files that may belong to another OS) are never auto-answered. |
| `--skip-preflight` | Skip the free-space checks on `/` and the EFI System Partition. |
| `-h`, `--help` | Show help and exit. |

## What it does

1. Runs a disk-space preflight (see below). On a hopelessly small EFI System Partition it aborts before anything irreversible happens.
2. Downloads the Kali archive keyring and adds the `kali-rolling` repository as a deb822 file (`/etc/apt/sources.list.d/kali.sources`, `Signed-By` the keyring).
3. **Disables** the existing Debian repositories, since Kali doesn't support mixing Debian and Kali repos. Backups go to `/etc/apt/upgrade-to-kali-backup/`.
4. Runs `apt-get full-upgrade` against `kali-rolling`, which rebases the base system onto Kali (this flips `/etc/os-release` to Kali).
5. Installs a Kali metapackage: `kali-linux-default` if a desktop is detected, otherwise `kali-linux-headless` (override with the `KALI_METAPACKAGE` environment variable).
6. Removes no-longer-needed packages (`autoremove --purge`) and cleans the apt cache.

After it finishes, reboot.

## Disk-space preflight and ESP handling

On systemd-boot systems the kernel and the full initrd get copied onto the EFI System Partition, and Kali's default (`MODULES=most`) initrds (~200 MB) are far larger than Debian's. A DigitalOcean droplet's ESP is about 105 MiB, so an unchecked upgrade would die midway through with `No space left on device` and leave dpkg half-configured.

Before the confirmation prompt, the preflight detects that layout and, when space is short, offers to make room (each step prompted individually; auto-yes under `--yes`):

- Delete stale boot files: orphan kernel directories, truncated copies from an earlier ENOSPC, and duplicates stranded under an old machine id (cloud images regenerate the machine id on first boot). Directories that may belong to *another* OS sharing the ESP get a separate default-No prompt that `--yes` never auto-answers.
- Purge kernels that are neither running nor newest.
- On VMs: write a persistent `MODULES=dep` + `COMPRESS=xz` initramfs config and regenerate, which shrinks the initrds to a fraction of their size. Revert instructions are inside the written file (`/etc/initramfs-tools/conf.d/upgrade-to-kali-modules.conf`).

If the ESP is too small even for that, the script aborts with manual instructions before any conversion step (`--skip-preflight` overrides).

If the kernel copy still hits `No space left on device` mid-upgrade despite all this, the script recovers by itself. It walks the same remediation ladder starting with the least destructive step, re-checking after each one whether the kernel now fits. As a last resort it evicts the non-newest kernels' boot files from the ESP (their sources in `/boot` stay). Then it repairs dpkg and retries the failed step once.

On an ESP too small to ever hold two kernel+initrd pairs, the script finishes with a warning: once the new kernel has survived a reboot, purge the old one, and purge the previous kernel before every future kernel upgrade too. Otherwise the next kernel update runs into the same out-of-space error.

## Mirror and network failures

A `full-upgrade` onto `kali-rolling` fetches hundreds of packages, and the `http.kali.org` redirector can hand out a mirror that is unreachable or mid-sync. Both apt and the keyring download therefore retry transient failures on their own, and each conversion step's output is captured and classified when it fails, so the recovery matches the cause:

- **Out of space** takes the ESP ladder above (checked first: a failure that is both needs space, not patience).
- **Fetch, DNS, and mid-sync errors** (unreachable mirror, timeouts, `Hash Sum mismatch`, `File has unexpected size`) get delayed retries with a growing backoff, refreshing the package lists in between so the redirector can pick a healthier mirror. Already-downloaded packages stay cached, so a retry only fetches what is still missing. There is deliberately no `--fix-missing`: a distro rebase must not proceed with packages it couldn't get.
- **Broken IPv6 routing** — apt failing over an IPv6 address with `Network is unreachable` — switches the rest of the run to IPv4.
- **A mirror that keeps failing** is swapped for Kali's `kali.download` CDN on the last retry. It stays in your sources afterwards (both are official Kali mirrors). This is skipped entirely if you pinned `KALI_MIRROR` yourself.

Anything the script can't classify keeps the previous behaviour: run the ESP ladder, retry once.

## Resume after interruption

If the conversion fails midway (network down for good, Ctrl-C), the script prints recovery commands matched to what actually went wrong — a mirror or network failure gets "re-run to resume, apt only fetches what's still missing, pin a mirror with `KALI_MIRROR`" rather than ESP advice — along with the path to the failed step's captured output, and leaves a marker at `/var/lib/upgrade-to-kali/state`. Just re-run it: it repairs dpkg (`dpkg --configure -a`, `apt-get -f install`) and resumes where it left off, keeping the originally chosen metapackage. A conversion that was finished out-of-band is detected and the marker cleaned up.

## Environment overrides

The interesting knobs (set as environment variables before invoking):

| Variable | Default | Purpose |
|---|---|---|
| `KALI_METAPACKAGE` | auto | Force the metapackage (`kali-linux-headless`, `kali-linux-default`, ...) instead of desktop auto-detection. |
| `KALI_MIRROR` | `http://http.kali.org/kali` | Use a different Kali mirror. Setting it also disables the automatic CDN failover. |
| `KALI_FALLBACK_MIRROR` | `https://kali.download/kali` | Mirror to fail over to when the configured one keeps failing. |
| `NET_RETRIES` | `2` | Delayed retries per step for mirror/network failures. |
| `NET_RETRY_DELAY` | `20` | Seconds before the first retry; doubled for each further one. |
| `KEYRING_URL` | `https://archive.kali.org/archive-keyring.gpg` | Where the archive keyring is downloaded from. |
| `ESP_PATH` | auto | Pin the EFI System Partition mountpoint when auto-detection misfires. |
| `ROOT_MIN_FREE_KIB` | `6291456` (6 GiB) | Free-space floor on `/` (warn-only). |

Every other path and threshold in the script (`OS_RELEASE_FILE`, `APT_DIR`, `BACKUP_DIR`, `STATE_FILE`, `BOOT_DIR`, the ESP size floors, ...) is env-overridable too, mainly so the guards and preflight logic can be exercised in tests without root or a VM.

## Troubleshooting

If a conversion failed and you prefer to finish it manually instead of re-running the script:

```bash
sudo dpkg --configure -a
sudo apt-get -f install
sudo apt-get update && sudo apt-get -y full-upgrade
sudo apt-get install -y kali-archive-keyring kali-linux-headless   # or your chosen metapackage
sudo apt-get -y autoremove --purge
```

The `MODULES=dep` config written on VMs persists after conversion; to revert it, delete `/etc/initramfs-tools/conf.d/upgrade-to-kali-modules.conf` and run `sudo update-initramfs -u -k all`.

## License

Licensed under the [Apache License 2.0](LICENSE).

## Acknowledgments

- Follows the official [Kali apt-sources guidance](https://www.kali.org/docs/general-use/kali-apt-sources/) (no Debian/Kali repo mixing).
- This tool originated as part of a larger personal Linux setup script and was extracted into its own project.
