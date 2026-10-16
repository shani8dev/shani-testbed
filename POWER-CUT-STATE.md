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
(`EFI/shanios/shanios-blue.efi`) — there is no standalone `initramfs-linux.img`.
So the image cannot test the fix until the hook is injected into the UKI,
repacked and re-signed. `powercut-inject-hook.sh` currently copies into
`/usr/lib/dracut/` and regenerates an initramfs, which does **not** affect the
UKI — it needs rewriting.

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
