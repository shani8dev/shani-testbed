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
