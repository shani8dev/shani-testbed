# Mid-upgrade power-cut matrix

A power cut is not reproducible; the **end state it leaves behind** is.
Each scenario reproduces one of those states on `install.img` so the recovery
can be booted for real.

| id | cut point | end state | must hold |
|----|-----------|-----------|-----------|
| A | during extract, **before** the boot flip | default still the old proven slot | boots normally; nothing moves |
| B | after the flip, candidate **healthy** | default is `<slot>+3-0`, candidate mounts | boots the candidate — **the hook must NOT fire** |
| C | after the flip, candidate **cannot mount**, and that boot already failed once | default is a tries entry, `boot_hard_failure` present | hook rewrites `default` to the good slot; **next** boot lands on it |

**B is the control that makes C meaningful.** Without it, a hook that always
rewrote `loader.conf` would also pass C.

C is the field failure: dracut emergency mode, `Failed to mount /sysroot`
three times four minutes apart, recovered by hand from the other partition.

## The mid-flip window — analysed, NOT covered by a scenario

The three scenarios above are all **end states of the extract phase or after the
flip has completed**. None of them is a cut *during* the flip, and this harness
structurally cannot produce one: `powercut-scenario.sh` reproduces the state a
cut leaves, so a state that only exists mid-write has no representation.

That matters, because the flip is several writes and they are not one atomic
step. The order in `finalize_boot_entries()` is:

1. stage + `rename` the `<slot>+3-0.conf` entry
2. stage + `rename` `loader.conf` with the new `default`
3. `chattr -i` + unlink `LoaderEntry{SysFail,OneShot,Preferred,Default}`
4. `bootctl set-preferred`, then `bootctl set-default`

A cut between any two of these leaves a state that is neither endpoint. Checked
one at a time against systemd-boot v262's precedence (`config_select_default_entry`
returns on the first match: SysFail → OneShot → Preferred → saved → **Default**
→ loader.conf → first entry):

| cut after | state | what boots | verdict |
|---|---|---|---|
| 1 | stale `+3-0` entry on disk, `loader.conf` still old | old proven slot | safe; the deploy did not take |
| 2 | `loader.conf` = candidate, `LoaderEntryDefault` = old | **old proven slot** — Default outranks loader.conf | safe; the deploy did not take |
| 3 | variables cleared, `loader.conf` = candidate | candidate | safe; that is the deploy's intent |
| 4 | complete | candidate | the endpoint |

So no mid-flip cut point is worse than either endpoint: every one of them lands
on either the old proven slot or the new candidate, and both boot. The dangerous
combination — old `loader.conf` with a variable pointing at an **unproven**
candidate — is not reachable, because the variable writes are last and a cut
before them leaves the variables naming the *previous* deploy's slot, which was
proven at the time.

**The row that mattered has since been MEASURED - see SCENARIO D below.

## Two writes in that sequence were NOT crash-safe, and are now

Reading the flip for the above turned up two real defects, both fixed
2026-10-18 and neither found by a test:

- **`shani-deploy.sh`: `grep -v "^default " ... > "${loader_conf}.tmp" || true`
  followed by `mv` over the live file.** The `|| true` is the defect — it does
  not merely swallow a failure, the next line *commits* that file over a working
  `loader.conf`. A cut between the truncate and the write leaves byte-for-byte
  the state this produces.
- **`configure.sh`: `printf ... > /boot/efi/loader/loader.conf`.** A truncating
  redirect, on a machine that can lose power during installation, with no prior
  `loader.conf` and no deploy to fall back on.

Both now stage into a temp in the same directory and rename. `rename(2)` within
one directory is atomic, so the file on the ESP is either absent or complete.

**The rest of the flip was already sound**, which is worth recording because it
is the answer to "is the EFI creation at the end safe": both boot entries are
staged in the entries directory and renamed, and `gen-efi.sh` builds the UKI to
`${uki_path}.tmp`, renames it, signs to `.tmp_signed`, and renames again. A cut
during UKI creation leaves the previous UKI in place — which is why scenario A
("before the flip") is genuinely safe rather than merely hopeful.

## Order

```sh
powercut-inject-hook.sh                    # once, after ANY hook change
powercut-scenario.sh C
test-env/test.sh vmspawn --tpm=no          # boot 1 — mount fails, loader.conf rewritten
# inspect the ESP's default entry
test-env/test.sh vmspawn --tpm=no          # boot 2 — lands on the good slot
```

## Two host facts, both learned the hard way

- `--tpm=no` is **required**. The TPM path fails with
  `swtpm: Error: Could not send response: Permission denied`. Fine for an
  unencrypted image; do not assume the documented `--tpm=yes` invocation works.
- **A real UEFI boot IS possible without `/dev/kvm`** — `vmspawn` boots
  `install.img` end to end here. The earlier claim that firmware boots were
  unavailable on this host was wrong.

---
## SCENARIO D — the mid-flip cut, MEASURED (2026-10-18)

This is the one state the matrix could not previously express, because it exists
only mid-flip: `loader.conf` has been rewritten to the candidate, but the EFI
variable write that follows it has not happened, so `LoaderEntryDefault` still
names the **previous** deploy's slot.

The obstacle was seeding an EFI variable offline, which is impossible — there is
no efivarfs outside a booted guest. But `lib/isoinstall.sh:428` only resets the
guest's NVRAM on `--reset-firmware` or when `install.img` has been re-created, so
**NVRAM persists across `iso-install --boot-only` runs** and the state can be
built in two steps instead of invented.

```sh
# 1. seed the stale variable from a real guest (this is the write the cut missed)
iso-install -p gnome --boot-only --iso=iso-latest --boot-timeout=900 \
  --console-exec="bootctl --esp-path=/boot/efi set-default shanios-blue.conf"

# 2. offline: the rest of the flip - loader.conf now names the candidate
sed -i 's|^default .*|default shanios-green.conf|' <ESP>/loader/loader.conf

# 3. boot it and read which slot actually took
iso-install -p gnome --boot-only --iso=iso-latest --boot-timeout=900 \
  --console-exec="cat /proc/cmdline; cat /data/current-slot"
```

State under test: `loader.conf` = `shanios-green.conf`, `LoaderEntryDefault` =
`shanios-blue.conf`.

```
CMDLINE=... rootflags=subvol=@blue ...
SLOTFILE=blue
```

**The machine boots the OLD proven slot.** `LoaderEntryDefault` is fifth in
`config_select_default_entry()`'s precedence and `loader.conf` is seventh, so
the stale variable wins outright.

That is the row that mattered, and it is now a measurement rather than an
argument. The machine boots the OLD proven slot: safe, and now measured. **It is not
silent, though** — see the correction below. I originally wrote that it was, and
that was wrong: `/data/deployment_pending` already covers it.

The other two mid-flip rows stay reasoning: cut after the entry rename leaves the
old `loader.conf` (trivially the old slot), and cut after the variables are
cleared leaves `loader.conf`'s candidate (the deploy's intent). Neither needs a
guest to establish, because in both the surviving `default` line is the deciding
source and nothing outranks it.

**Still untested:** the same window on a **first install**, where there is no
prior `LoaderEntryDefault` at all — which is precisely why
`configure.sh` omits `bootctl set-default`, and why that omission is load-bearing
rather than incidental. There, `loader.conf` is the only source, so a truncated
one has no fallback; which is the reason all five of the ESP writes now stage and
rename.

---

## SCENARIO D — correcting my own conclusion

SCENARIO D — correcting my own conclusion in the section above

That section ends by saying a deploy interrupted mid-flip "is indistinguishable,
afterwards, from one that never ran", and that shani-deploy should say something
durable about the flip. **Both are wrong.** The mechanism exists, has for some
time, and I did not look for it.

`/data/deployment_pending` is written at deploy start (`shani-deploy.sh:4189`,
`touch "$DEPLOY_PENDING"`) and removed when the deploy completes (`:4215`).
`shani-health` reads it and reports it with an age threshold and a remediation:

    !!  deployment_pending 42min old — deploy interrupted?
    _rec  Stale deployment_pending (42 min) - check: shani-deploy --rollback

So an interrupted flip is surfaced on the next health check, with severity
rising past an hour, and with the command to run. Scenario D's real consequence
is therefore narrower and better than I wrote: the machine boots the old proven
slot, and the user is told the deploy did not complete.

**How I got there, because the method is the point.** I grepped for
`deploy_pending` - lowercase - and found exactly two lines: the default and the
assignment. I read that as "declared and never used" and built a fix on it.
The variable is `DEPLOY_PENDING`, uppercase, and appears at ten sites including
four removal paths and two refusal checks. A case-sensitive grep for the wrong
name returned a clean, plausible, and completely misleading result.

Then, having concluded the feature was missing, I did not search for an existing
consumer either - I reasoned from the code in front of me about what a user
would see. `shani-health.sh` has been answering exactly that question all along.

Two wrong steps in a row, both from not searching, and both producing a result
that read as a finding. The correction matters more than the fix would have:
had I shipped my version, it would have written a second marker over one that
already works, in a different format, with different semantics.
