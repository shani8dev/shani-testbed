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

## BOOT 2: the branch was never REACHED, so no diagnostic appeared

    [13.17] dracut-pre-mount[309]: shanios-hook: boot_hard_failure written for slot '@unknown'
    [15.30] dracut-pre-pivot[380]: shanios-hook: boot_hard_failure cleared - root mount succeeded

**Not one "prior failure but ..." line.** The failover guard is
`[ -s "$DATA_MNT/boot_hard_failure" ]`, and it evaluated FALSE — while
`boot_hard_failure` was verifiably on `@data` from the host between the two
boots (checked: `boot_hard_failure on disk: blue`).

So adding a warning to every failure path bought nothing, because the block was
skipped before any of them. **The marker the whole mechanism depends on is not
visible to the pre-mount hook where it writes it.** That is the actual defect,
and it is upstream of everything else here: the hook, the tests, the ESP
handling and the `+3-0` question are all downstream of it.

Most likely: the hook mounts `@data` by subvolume at pre-mount, but the marker
is written to /data inside the running system, where `data.mount` is a bind of
a different path. Two locations, one name. Worth checking first:

    # in a booted slot, with the initramfs's view known:
    findmnt /data; ls -la /data/boot_hard_failure
    # and what the hook actually mounts:
    #   mount -t btrfs -o subvol=@data,rw "$DATA_DEV" /run/shanios-data-tmp
    ls -la /run/shanios-data-tmp/boot_hard_failure

Boot 1's own log says it CLEARED the marker at pre-pivot and then boot 1 was
found to have it still on disk — which is the same discrepancy seen from the
other side. Both point at two different locations, not at a broken hook.

**Next step, in order:**
1. Find the two paths. One command in a booted slot settles it.
2. Only then re-test the failover. The unit tests cannot catch this class —
   they write the marker where the hook reads it, by construction.
3. Scenario C still needs the UKI `.cmdline` pointed at a missing subvolume;
   editing the entry's `options` does nothing, as boot 1 showed.

## THE PATH QUESTION, ANSWERED — and it is one command

    /data/boot_hard_failure   -rw-r--r-- 1 root root 5 Oct 16 16:12
    data.mount:  What=LABEL=shani_root   Where=/data
    /run/shanios-data-tmp     does not exist in the running system

Two facts that change the picture:

1. **The marker boot 1 wrote IS visible afterwards, at `/data`, with boot 1's
   timestamp (16:12 UTC = 21:42 IST).** So the write is not lost.
2. **`data.mount` mounts `LABEL=shani_root` with no `subvol=`** — that mounts
   whatever the filesystem's DEFAULT subvolume is. The hook mounts
   `-o subvol=@data` explicitly.

**So the whole question is one line: is `@data` the default subvolume?**

    btrfs subvolume get-default /

If it prints `@data`, the two paths are the same and the guard's false result
has a different cause (most likely: boot 2 started from an ESP whose marker
state had changed, or the boot order meant the clear ran before the read).
If it prints subvolid 5 or anything else, **the hook has been writing to a
different subvolume than the one `/data` is**, and the marker the recovery
system reads is not the marker the hook writes — which is a real bug, and it
would mean `shani-auto-rollback` has never once seen a marker the hook wrote.

Check that first. Everything else here is downstream of it.

Note also: `/run/shanios-data-tmp` does not survive pivot, which is why the
running system cannot be inspected for the hook's own view — the mountpoint is
gone. Only the initramfs, at pre-mount, ever sees that path.

## ANSWERED: `/data` IS the `@data` subvolume — my hypothesis was wrong

    findmnt /data   ->   /dev/loop33p2[/@data]

**Same subvolume.** The hook's `-o subvol=@data` and the system's `/data` are
one location, so the "two different places sharing one name" theory I was
building toward is wrong, and is retracted here rather than left standing in the
file above.

(`btrfs subvolume get-default /` fails on a non-boot nspawn session with "not a
btrfs filesystem" — `findmnt` is the instrument that answers it here.)

So the marker plumbing is sound, and the remaining puzzle is narrow:

- the marker is present at `/data` with value `blue`
- the hook writes it at pre-mount via `@data`
- **and yet boot 2's guard `[ -s "$DATA_MNT/boot_hard_failure" ]` read false**

Given the paths are identical, the candidates are now few:

1. **The initramfs's own `@data` mount failed at pre-mount**, so the hook's
   `$DATA_MNT` was empty and it read nothing. Note the hook writes
   `boot_hard_failure` *after* the guard, so a failed mount would ALSO explain
   boot 1 writing it while boot 2 could not read it — if the two boots mounted
   differently. The hook now warns on that path, so **boot 3 will say so**.
2. Boot 1's pre-pivot "cleared the marker" wrote to `$NEWROOT/data`, which is
   NOT yet the `@data` mount at that stage — /data is mounted by systemd
   *after* pivot. So the clear went into a directory that was then shadowed, and
   the marker survived. That is consistent with everything observed, and it
   means **the clear has probably never worked either.**
3. The ordering of my own scenario steps wiped it between the check and the
   boot.

**(2) is the more interesting one and is now the stronger hypothesis.** It
would mean the hook's clear and its failover disagree about where `/data` is at
the same stage of boot — one writes through a subvolume mount, the other writes
into a soon-to-be-shadowed directory.

**Next step:** run boot 3 with the current diagnostic hook. It now warns on
every path, so if (1) is right the console says so directly.

## THREE BOOTS, SAME RESULT — the finding is now firm

Boot 3, with the diagnostic hook in place:

    [12.60] dracut-pre-mount[309]: shanios-hook: boot_hard_failure written for slot '@unknown'
    [15.25] dracut-pre-pivot[379]:  shanios-hook: boot_hard_failure cleared - root mount succeeded

**No `prior failure but ...` line.** The diagnostics are in the hook (committed
`57994ad`, re-injected) and none of them fired, so the guard

    [ -s "$DATA_MNT/boot_hard_failure" ]

evaluated FALSE. Reproduced on boots 2 and 3.

## That is contradictory, and the contradiction is the finding

Verified from the host between boots, mounting the same subvolume the hook does:

    findmnt /data            -> /dev/loop33p2[/@data]
    /data/boot_hard_failure  -> "blue"   (scenario C wrote it; boot 1's
                                            pre-pivot "clear" did NOT remove it)

And the same hook, in the same function, **writes** that file successfully at
pre-mount on every boot.

So across three boots: the marker exists on `@data`, the hook writes to
`@data`, and the hook does not read it. The only way both hold is that the
hook's read is not looking at the content the rest of the world sees.

## Prime suspect, and it is checkable

The hook resolves its device itself:

    DATA_DEV=$(blkid -L "$ROOT_LABEL")          # ROOT_LABEL=shani_root
    mount -t btrfs -o subvol=@data,rw "$DATA_DEV" "$DATA_MNT"

If the initramfs sees **more than one** device labelled `shani_root` — a real
possibility with two slots, two loops, and by-label symlinks that the hooks'
own comment says can dangle — `blkid -L` may be resolving a different one than
the one the running system uses, and the hook has been writing the marker to a
subvolume nobody reads.

**Check, in the initramfs during any boot:**

    dracut-pre-mount$ blkid -L shani_root
    dracut-pre-mount$ ls -la /run/shanios-data-tmp/boot_hard_failure

If the `ls` says "No such file" while `/data/boot_hard_failure` exists from
the host, that is it, and the fix is to resolve the device the way the rest of
the system does rather than by label inside a minimal initramfs.

## The three false starts, so they are not repeated

1. `lsinitramfs` reporting zero `99shanios` — the module dir is not shipped,
   only the hooks `inst_hook` bakes in.
2. `grep 99shanios` on the decompressed image — same reason.
3. **This one**: assuming the hook and the system agree about `/data`.
   `findmnt` says they do at the subvolume level, and yet behaviour says
   otherwise. Both were settled by measurement, not by reading.

Also still true and still unfixed: the pre-pivot clear writes to
`$NEWROOT/data`, which is not the `@data` mount at that stage, so
`boot_hard_failure cleared` has never actually removed anything — boot 1 left
it in place. **The clear and the failover disagree about where `/data` is at the
same moment of boot**, which is the same class of bug as the read above.

## `objcopy --update-section` SHRINKS a UKI and corrupts it — boots 2-4 were invalid

Found while verifying the diagnostic injection, not by booting:

    objcopy: shanios-blue.efi[.initrd]: file truncated

**`objcopy --update-section .initrd=<smaller file>` rewrites the PE with the
new, shorter data while the section header still describes the original
length.** The UKI ends up with its own section table pointing past its end of
file. The UKI shrank 53,823,024 -> 51,507,080 bytes and its `.initrd` claimed
36,010,760 bytes it no longer contained.

They still booted — the initramfs content was intact enough for the hooks to
run — which is exactly why it was not noticed. **Boots 2, 3 and 4 were running
an image I had malformed, so their results are not trustworthy** and anything
concluded from them needs re-testing against a well-formed image.

### The correct way, and why

**Rebuild the initrd to exactly the original byte length so the PE layout is
never disturbed.** The recompressed initramfs is smaller than the original, so
pad:

    cat stub.cpio new.cpio.zst > new_initrd.bin
    PAD=$(( ORIG - $(stat -c %s new_initrd.bin) ))
    dd if=/dev/zero bs=1 count="$PAD" status=none >> new_initrd.bin
    objcopy --update-section .initrd=new_initrd.bin   # same size: no re-layout

**Always verify by extracting it back out**, do not trust the write:

    objcopy -O binary --only-section=.initrd patched.efi check.bin
    [ "$(stat -c %s check.bin)" = "$ORIG" ] || echo STILL TRUNCATED

Trailing zeros after a zstd frame are ignored by the decompressor, so padding
is harmless — this was confirmed by the round-trip check passing and the hook
then being found with its fix and diagnostics intact.

**This is the general trap:** the natural instinct when patching a UKI is "just
swap the section", and that is exactly wrong. Anyone doing this needs to know
it, which is why it is written down rather than left as a thing that happened
to me.

Note the UKI's initrd now begins the zstd stream at **113528** rather than
113664 — the stub and the initramfs are concatenated with no padding between
them, since `stub.cpio` is exactly 113528 bytes.

## THE ACTUAL CAUSE OF BOOTS 2-5: I patched blue and booted green

Every boot since the injection ran **`shanios-green.efi`**, which I never
touched. The injection only ever modified `shanios-blue.efi`.

Why: scenario C sets `default` to a copy of the **green** entry (green is the
only non-tries entry, so it is the fallback), and that entry's `efi` line is
`/EFI/shanios/shanios-green.efi`.

So boots 2, 3, 4 and 5 ran the **original, pre-fix** green UKI:

- `boot_hard_failure written for slot '@unknown'` — the ORIGINAL hook's line
- **no failover block at all**, so the guard was never evaluated and the false
  guard was an artefact
- **no DIAG lines** — they were only ever injected into blue
- the corrupted-UKI problem was blue's, which green was not subject to

**Every conclusion drawn from boots 2-4 is void.** The "hook writes the marker
but cannot read it" finding was never observed — what was observed was the
pre-fix hook doing exactly what the pre-fix hook does.

**How it went unnoticed for four boots:** the console line I kept checking for
(`boot_hard_failure written for slot ...`) is present in BOTH the old and the
new hook, so it read as "the hook ran" — the one signal that could not
distinguish the two builds. The DIAG lines could have, and they were absent for
the same reason, which I attributed to a read failure instead of to the build
not being the one under test.

## Lesson

**Verify that the thing you patched is the thing that runs.** A green console
line from a hook is not evidence the *new* hook ran when the old hook emits the
same line. Cheapest check, and it should have come first:

    # what the default entry actually loads
    cat $ESP/loader/entries/<default-entry>.conf | grep ^efi

**Next step:** inject into `shanios-green.efi` as well (or point the default at
blue), then re-run scenario C from scratch. Nothing about the failover has been
tested yet, so treat every claim about it so far as untested.
