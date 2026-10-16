# Power-cut recovery: session state, findings, and what is left

Written mid-session so a fresh session can continue without archaeology.
Everything below was measured on this host; nothing here is a source reading.

## The failure being fixed

A field machine dropped to dracut emergency mode after a power cut during an
update: `Failed to mount /sysroot` three times, four minutes apart, then a
shell. An operator recovered by running `shani-deploy` from the good partition.

**It is not a TPM2/seal problem** (that was the first, wrong guess — the empty
`blkid | grep crypto LUKS` is simply what an unencrypted install shows).

## Root cause

Two coupled gaps:

1. `boot_hard_failure` is written by the dracut **pre-mount** hook, before the
   root mount — so a candidate that cannot mount *does* leave evidence. But
   `shani-auto-rollback` acts on it from a systemd timer inside a boot that
   **succeeds**. The failing boot cannot act on its own marker.

2. The `+3-0` tries entry that should have covered this **does not decrement on
   this systemd**, so nothing falls back automatically.

Measured, after a real boot of this image:

    "id":"shanios-blue.conf","path":".../shanios-blue+3-0.conf",
    "triesLeft":3,"triesDone":0,"isDefault":true

`triesDone: 0` after a real boot. The fallback is not a safety net here.

## The fix

`image_profiles/{shared,server}/overlay/rootfs/usr/lib/dracut/modules.d/99shanios/shanios-boot-failure-hook.sh`
— at **pre-mount**, where the failing boot still has a say: if a pre-existing
`boot_hard_failure` exists, mount the ESP by label (`blkid -L shani_boot`) and
rewrite the single `default` line to the first entry **without** a tries suffix.
The next boot lands on the known-good slot, unattended.

Narrow and fails open: only on a pre-existing marker; only from a tries-counted
default; only rewrites `default`; never deletes an entry; self-limiting because
the switched-to default no longer matches.

**It ships on the next image build**, not by being committed: the hook lives in
the initramfs. `build-base-image.sh`'s cache key hashes both overlay dirs, so
the rebuild is forced — precedent cited in that code is the 2026-10-08
dracut.conf fix that made USB-SSD installs boot.

## Do NOT "fix" this

`finalize_boot_entries()` sets `default shanios-blue.conf` while the file on
disk is `shanios-blue+3-0.conf`. That looks broken and is **correct**:
`bootctl list` reports the entry id as `shanios-blue.conf`, `isDefault: true`.
The comment in the code rejecting the glob alternative is right. An earlier
commit (`f8adca4`) claimed a bug here; retracted in `794da2c`.

## Host facts (all measured, all non-obvious)

- **The loop device is NOT the blocker.** All 36 kernel loops are attached, but
  **two are already attached to `install.img`**. Create the missing device
  nodes from sysfs and use one; detach nothing.
  ```
  L=loop33
  for d in /sys/block/$L/${L}p*; do n=$(basename $d); mm=$(cat $d/dev)
    [ -e /dev/$n ] || mknod /dev/$n b ${mm%%:*} ${mm##*:}; done
  ```
  Gives `loop33p1` = `shani_boot` (vfat), `loop33p2` = `shani_root` (btrfs).
- **Real UEFI boots work here with no `/dev/kvm`.** `vmspawn` boots
  `install.img` end to end under OVMF.
- **`--tpm=no` is REQUIRED** — the TPM path dies with
  `swtpm: Error: Could not send response: Permission denied`.
- `vmspawn` is **host-only**: run `./test-env/test.sh vmspawn ...`, NOT through
  `run_in_container.sh`.
- Inside a slot, this repo is at `/mnt/repo`, the testbed at `/mnt/testbed`.
- **`lsinitramfs` is unreliable for custom dracut modules** — reported zero
  `99shanios` entries on a slot where the module demonstrably ran (`/etc` is
  mounted as `overlay`, and only `shanios-overlay-etc.sh` mounts it). Ask
  something that can only be true if the hook ran.
- `/run` is not writable unprivileged and `unshare` is denied, so anything
  touching `/run` needs a container.

## Why the scenario tests are blocked

The hook lives in the **initramfs**, which is embedded in the **UKI** on the ESP
(`EFI/shanios/shanios-blue.efi`, 53,823,024 bytes) — there is no standalone
`initramfs-linux.img`. `powercut-inject-hook.sh` currently copies into
`/usr/lib/dracut/` and regenerates an initramfs, which does **not** affect the
UKI.

UKI structure, measured:

    .sdmagic .osrel .cmdline .splash .sbat .linux .initrd   (no .pcrs, no .pcrsig)
    .initrd  = 36,010,760 bytes
    .cmdline = "quiet splash systemd.volatile=state ro lsm=... rootfstype=btrfs
                rootflags=subvol=@blue,ro,... root=UUID=3d8f7025-... "

Two things settled here:

- **`root=UUID=` with no `rd.luks.*` — this install is unencrypted.** That
  definitively rules out the TPM2/seal theory, and is why `--tpm=no` is the
  right vmspawn flag for it.
- **The `.initrd` is a chain of 140 concatenated SVR4 cpio archives**
  (`070701` magic at offsets 0, 112, 240, 360, …), not a single one.
  `bsdtar -tf` stops at the first and reports 6 entries; `unmkinitramfs` and
  `lsinitrd` are **not installed in the builder image**, only `cpio`, `bsdtar`
  and `objcopy`. So extracting the real dracut initramfs means walking that
  chain rather than unpacking one archive.

Available tools in the builder for the remaining surgery: `objcopy`, `sbsign`,
`cpio`, `bsdtar`, `zstd`. Missing: `ukify`, `lsinitrd`, `unmkinitramfs`.
`objcopy -O binary --only-section=.initrd` is the reliable way to get it out.

### The initramfs layout, solved

The `.initrd` is NOT one archive and not 140 either. It is:

    offset      0 .. 113528   SVR4 cpio stub — early_cpio + kernel/x86/microcode
    offset 113528 .. 113664   zero padding (136 bytes)
    offset 113664 .. EOF      zstd-compressed cpio — the REAL dracut initramfs
                               (78,413,312 B uncompressed, 1338 entries)

`28 b5 2f fd` at 113664 is the zstd magic. Getting there needs the trailer
followed by a forward scan past the zero padding — 512-alignment is wrong.

**Two false negatives from this, both mine, recorded so they are not repeated.**
Grepping the initramfs for `99shanios` finds nothing, twice: the module
directory is not shipped, only the hooks `inst_hook` bakes into it. What
matters is:

    var/lib/dracut/hooks/pre-mount/90-shanios-boot-failure-hook.sh
    var/lib/dracut/hooks/pre-pivot/50-shanios-overlay-etc.sh
    var/lib/dracut/hooks/pre-pivot/90-shanios-boot-success-clear.sh

So `lsinitramfs` reporting zero AND `grep 99shanios` reporting zero both look
like "the module was never included" and are both wrong. Three instruments,
two false negatives; the one that answered correctly was asking something that
can only be true if the hook ran.

### The swap, done and verified

    # 1. pull the initrd out, walk to 113664, decompress
    objcopy -O binary --only-section=.initrd <UKI> initrd.bin
    # 2. skip the stub + padding; the real one starts at the zstd magic
    zstd -dc tail2.bin > real.cpio
    # 3. extract ALL of it, replace the hook, repack, recompress
    (cd x && cpio -id --quiet < ../real.cpio)
    cp <new-hook> x/var/lib/dracut/hooks/pre-mount/90-shanios-boot-failure-hook.sh
    (cd x && find . -print0 | cpio --null -o --format=newc --quiet) > new.cpio
    zstd -19 -q -f new.cpio -o new.cpio.zst

Verified: hook went from 0 to 1 occurrence of the failover, 1338 entries in and
out. **Trap:** a partial extract-then-repack silently yields a 7 KB initramfs
instead of 78 MB — extract everything.

**Remaining:** splice `new.cpio.zst` back into the stub as a new `.initrd`,
`objcopy` it into the UKI, and `sbsign`. The signing step needs the MOK private
key — find where that lives before starting, and note that the repo's own notes
say a real MOK private key is still present in the base image (a known,
unfixed Critical issue).

## Committed so far

| repo | commit | what |
|---|---|---|
| shani-install-media | `07e5747` | the failover hook + reasoning |
| shani-install-media | `a80526f` | real-hook suite (7/7, mutants fail) |
| shani-install-media | `5ab0323` | server copy sync + drift guard |
| shani-install-media | `540290b` | delivery-constraint record |
| shani-testbed | `e746f5b` | power-cut harness (A/B/C) |
| shani-deploy | `794da2c` | retraction + the `triesDone` measurement |

## Remaining work

1. Inject the hook into the UKI on the ESP (`EFI/shanios/shanios-blue.efi`),
   repack, re-sign with the MOK. Verify the initramfs inside now carries it.
2. Run the matrix, via `./test-env/test.sh vmspawn --tpm=no` each time:
   - **A** cut pre-flip → boots old slot, nothing moves
   - **B** cut post-flip, candidate HEALTHY → boots candidate, **hook must not fire**
   - **C** cut post-flip, candidate cannot mount + prior marker → hook rewrites
     `default`, next boot lands on the good slot
3. **B is the control that makes C mean anything.** Without it a hook that
   rewrote `default` unconditionally would also pass C.

## BOOT 1 OF SCENARIO C RAN ON REAL FIRMWARE — the failover did NOT fire

The UKI injection worked and the hook demonstrably ran:

    [12.09] dracut-pre-mount[303]: shanios-hook: boot_hard_failure written for slot '@unknown'
    [14.64] dracut-pre-pivot[379]: shanios-hook: boot_hard_failure cleared — root mount succeeded

But on the ESP afterwards:

    default now : shanios-green-broken+3-0.conf      <- UNCHANGED
    shanios-bak : (none - no backup was written)
    boot_hard_failure on disk: blue                  <- still there, so the
                                                         prior-marker test passed

So the hook entered with a pre-existing marker and **did not switch the
default**. It fails open and silently, which is the designed behaviour and is
exactly why this had to be booted to find. Most likely: the ESP is not
readable — or not mountable — at **pre-mount**, so `blkid -L shani_boot` or the
`mount -t vfat` returns nothing and every branch is skipped without a word.

**Next thing to do, in order:**

1. Make the hook say why it did nothing. It currently has one `warn()` on
   success and total silence on every failure path — which is how a
   not-running branch looks identical to a working one. Log each of: no
   ESP device, mkdir failed, mount failed, no loader.conf, no tries entry, no
   fallback entry.
2. Re-run boot 1. The console will then say which step failed.
3. **Two more findings from this run, both independent of the fix:**
   - Attempted-slot detection returned **`@unknown`**, not `blue`. `getarg
     rootflags` did not parse on this boot, so `boot_hard_failure` records a
     slot that `shani-auto-rollback` will refuse to act on.
   - **Scenario C did not make the candidate unbootable.** The entry's
     `options` line was pointed at `@no-such-slot` and the mount still
     succeeded — because the UKI carries its own `.cmdline`
     (`rootflags=subvol=@blue`) and that is what booted. An entry's `options`
     does not override an embedded UKI cmdline. **Any scenario that needs a
     genuinely unbootable slot must edit the UKI's `.cmdline`, not the
     entry's options.**
