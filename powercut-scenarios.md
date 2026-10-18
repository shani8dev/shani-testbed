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

**This is reasoning from the write order and the precedence list, not a
measurement.** It has not been booted. To make it a scenario the harness would
need to seed `LoaderEntryDefault`/`LoaderEntryPreferred` in the guest's NVRAM and
have that survive `powercut-scenario.sh`, which it cannot do offline — there is
no efivarfs outside a booted guest, which is the same reason
`SHANIOS_EFIVARS_DIR` exists and why the efivar proof is a firmware boot rather
than a unit test.

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
