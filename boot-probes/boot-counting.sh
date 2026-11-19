#!/bin/bash
# boot-counting — does systemd-boot count tries for ShaniOS's default entry, and
# is a counted (trial) boot only blessed once the login screen is up?
#
# Runs inside a FIRMWARE boot (iso-install --boot-only --console-exec), the only
# place systemd-boot, LoaderBootCountPath and the ESP are real. One boot per
# phase; each later phase reads what the boot before it did:
#
#   verify                 RESULT lines for THIS boot (waits for it to settle)
#   arm-exhausted SLOT KEY PREFERRED DEFAULT
#                          for the NEXT boot: SLOT's entry has no tries left and
#                          the selection efivars are set - which slot boots?
#   restore SLOT           the entries and efivars as an install leaves them
#   setup KEY [break-dm|fix-dm]
#                          for the NEXT boot: the default entry becomes a fresh
#                          +3-0 trial written with KEY (uki|efi), the files
#                          console-put to /tmp/bc_<name> are installed into the booted
#                          slot, and the display manager is broken (ExecStart=
#                          /bin/false, a NEGATIVE control) or fixed again
#
# Usage, one boot each (from ../shani-install-media; one console-put per file):
#   --console-exec="bash /tmp/bc.sh setup uki"          # install + arm a trial
#   --console-exec="bash /tmp/bc.sh verify; bash /tmp/bc.sh setup uki break-dm"
#   --console-exec="bash /tmp/bc.sh verify; bash /tmp/bc.sh setup uki fix-dm"
#
# Files it installs when present as /tmp/bc_<name> (--console-put=SRC:/tmp/bc_<name>;
# console-put cannot make directories):
#   shani-desktop-health.sh  -> /usr/local/bin/shani-desktop-health
#   *.service                -> /usr/lib/systemd/system/
#   10-shani.conf            -> /usr/lib/systemd/system/systemd-bless-boot.service.d/
set -u
EFIVARS=/sys/firmware/efi/efivars
GUID=4a67b082-0a4c-41cf-b6c7-440b29bb8c4f
res() { printf 'RESULT %-36s %s\n' "$1" "$2"; }

esp_mount() {
    mountpoint -q /boot/efi && return 0
    mkdir -p /boot/efi && mount LABEL=shani_boot /boot/efi
}

booted_slot() { grep -o 'subvol=@[a-z]*' /proc/cmdline | head -1 | sed 's/subvol=@//'; }

verify() {
    # The boot has to settle first: the debug shell starts with the boot.
    timeout 900 systemctl is-system-running --wait >/dev/null 2>&1
    local i u
    for (( i = 0; i < 400; i++ )); do
        u=$(systemctl show -P ActiveState shani-desktop-health.service mark-boot-success.service bless-boot.service | grep -c activating)
        [[ $u -eq 0 ]] && break
        sleep 1
    done
    esp_mount || { res esp-mounted FAIL; return 1; }
    local slot; slot=$(booted_slot)
    res booted-slot "$slot"
    res systemd "$(systemctl --version | head -1)"
    res sd-boot "$(grep -a -o -m1 'systemd-boot [0-9][^ ]*' /boot/efi/EFI/BOOT/grubx64.efi | head -1)"
    res entries "$(ls /boot/efi/loader/entries | tr '\n' ' ')"
    res entry-key "$(sed -n 's/^\(efi\|uki\)[[:space:]].*/\1/p' /boot/efi/loader/entries/shanios-"$slot"*.conf | head -1)"
    if [[ -e $EFIVARS/LoaderBootCountPath-$GUID ]]; then
        res LoaderBootCountPath "present: $(tr -d '\0' < "$EFIVARS/LoaderBootCountPath-$GUID" | cut -c5- | tr -cd '[:print:]')"
    else
        res LoaderBootCountPath absent
    fi
    for u in shani-desktop-health mark-boot-success bless-boot systemd-bless-boot; do
        res "unit:$u" "$(systemctl show -P ActiveState,Result,ConditionResult "$u.service" | paste -sd/)"
    done
    res boot-ok "$([[ -e /data/boot-ok ]] && echo present || echo absent)"
    res boot_desktop_failure "$(cat /data/boot_desktop_failure 2>/dev/null || echo absent)"
    res desktop-health-log "$(journalctl -b -t shani-desktop-health -o cat --no-pager | tail -3 | paste -sd'|')"
    res bless-log "$(journalctl -b -u bless-boot.service -o cat --no-pager | tail -2 | paste -sd'|')"
    res seat0 "$(loginctl show-seat seat0 -P ActiveSession 2>/dev/null) dm=$(systemctl is-active display-manager.service)"
    res drm "$(cat /sys/class/drm/card*-*/status 2>/dev/null | paste -sd,)"
}

setup() {
    local key="$1" dm="${2:-}" slot top entry name
    slot=$(booted_slot)
    esp_mount || { res setup-esp FAIL; return 1; }
    # the booted slot's entry becomes a fresh, unproven +3-0 trial with KEY
    entry=$(ls /boot/efi/loader/entries/shanios-"$slot"*.conf | head -1)
    name="shanios-${slot}+3-0.conf"
    sed "s/^\(efi\|uki\)\([[:space:]]\)/${key}\2/" "$entry" > /boot/efi/loader/entries/.bc.tmp \
        && mv -f /boot/efi/loader/entries/.bc.tmp "/boot/efi/loader/entries/${name}"
    [[ $entry == */"$name" ]] || rm -f "$entry"
    grep -q "^default shanios-${slot}.conf" /boot/efi/loader/loader.conf \
        || sed -i "s/^default .*/default shanios-${slot}.conf/" /boot/efi/loader/loader.conf
    sync
    res setup-entry "$(ls /boot/efi/loader/entries | tr '\n' ' ') key=$(sed -n 's/^\(efi\|uki\)[[:space:]].*/\1/p' "/boot/efi/loader/entries/${name}")"

    # files into the booted slot (read-only subvolume: lift ro, copy, restore)
    if compgen -G '/tmp/bc_*' >/dev/null; then
        top=/run/bc-top; mkdir -p "$top"
        mount -o subvolid=5 LABEL=shani_root "$top" || { res setup-slot FAIL; return 1; }
        # -f: an installed slot is a received subvolume (received_uuid set),
        # which btrfs refuses to make writable without it - as shani-deploy does
        btrfs property set -f -ts "$top/@$slot" ro false || { res setup-slot "FAIL (ro)"; umount "$top"; return 1; }
        local f t d="$top/@$slot"
        for f in /tmp/bc_*; do
            case ${f#/tmp/bc_} in
                shani-desktop-health.sh) install -Dm755 "$f" "$d/usr/local/bin/shani-desktop-health" ;;
                10-shani.conf) install -Dm644 "$f" "$d/usr/lib/systemd/system/systemd-bless-boot.service.d/10-shani.conf" ;;
                *.service) install -Dm644 "$f" "$d/usr/lib/systemd/system/${f#/tmp/bc_}" ;;
            esac
        done
        btrfs property set -f -ts "$d" ro true
        sync
        local bad=""
        for f in /tmp/bc_*; do
            case ${f#/tmp/bc_} in
                shani-desktop-health.sh) t="$d/usr/local/bin/shani-desktop-health" ;;
                10-shani.conf) t="$d/usr/lib/systemd/system/systemd-bless-boot.service.d/10-shani.conf" ;;
                *.service) t="$d/usr/lib/systemd/system/${f#/tmp/bc_}" ;;
                *) continue ;;
            esac
            cmp -s "$f" "$t" || bad+=" ${f#/tmp/bc_}"
        done
        umount "$top"
        [[ -z $bad ]] && res setup-files "PASS installed: $(ls /tmp/bc_* | sed 's|/tmp/bc_||' | paste -sd' ')" \
            || res setup-files "FAIL not installed:${bad}"
    fi

    # NEGATIVE control: a login screen that never comes up
    local real
    real=$(basename "$(readlink -f /etc/systemd/system/display-manager.service)")
    case $dm in
        break-dm)
            mkdir -p "/etc/systemd/system/${real}.d"
            printf '[Service]\nExecStart=\nExecStart=/bin/false\nRestart=no\n' > "/etc/systemd/system/${real}.d/99-bc-break.conf"
            res setup-dm "broken (${real})" ;;
        fix-dm)
            rm -f "/etc/systemd/system/${real}.d/99-bc-break.conf"
            res setup-dm "fixed (${real})" ;;
    esac
    rm -f /data/boot_desktop_failure
    sync
}

# arm-exhausted SLOT KEY PREFERRED DEFAULT - for the NEXT boot: SLOT's entry has
# no tries left (+0-3, KEY), LoaderEntryPreferred=PREFERRED and
# LoaderEntryDefault=DEFAULT (entry ids, or "-" to leave unset). Which slot the
# next boot lands on says which of systemd-boot's selection steps skips an
# exhausted entry (src/boot/boot.c config_select_default_entry()).
efivar_clear() {
    local f="$EFIVARS/$1-$GUID"
    [[ -e $f ]] || return 0
    chattr -i "$f" 2>/dev/null; rm -f "$f"
}
arm_exhausted() {
    local slot="$1" key="$2" pref="$3" def="$4" entry
    esp_mount || { res arm-esp FAIL; return 1; }
    entry=$(ls /boot/efi/loader/entries/shanios-"$slot"*.conf | head -1)
    sed "s/^\(efi\|uki\)\([[:space:]]\)/${key}\2/" "$entry" > /boot/efi/loader/entries/.bc.tmp \
        && mv -f /boot/efi/loader/entries/.bc.tmp "/boot/efi/loader/entries/shanios-${slot}+0-3.conf"
    [[ $entry == */"shanios-${slot}+0-3.conf" ]] || rm -f "$entry"
    efivar_clear LoaderEntryPreferred; efivar_clear LoaderEntryDefault; efivar_clear LoaderEntryOneShot
    [[ $pref == - ]] || bootctl --esp-path=/boot/efi set-preferred "$pref" || res arm-preferred FAIL
    [[ $def == - ]] || bootctl --esp-path=/boot/efi set-default "$def" || res arm-default FAIL
    sync
    res arm-exhausted "$(ls /boot/efi/loader/entries | tr '\n' ' ')pref=$pref default=$def $(grep '^default' /boot/efi/loader/loader.conf)"
    res arm-efivars "$(ls "$EFIVARS" | grep -E '^LoaderEntry(Preferred|Default|OneShot)' | cut -d- -f1 | paste -sd' ')"
}

# restore SLOT - SLOT's entry an unproven +3-0 with the "efi" key, the selection
# efivars cleared, loader.conf's default SLOT: the disk as an install leaves it.
restore() {
    local slot="$1" entry
    esp_mount || { res restore-esp FAIL; return 1; }
    entry=$(ls /boot/efi/loader/entries/shanios-"$slot"*.conf | head -1)
    sed "s/^\(efi\|uki\)\([[:space:]]\)/efi\2/" "$entry" > /boot/efi/loader/entries/.bc.tmp \
        && mv -f /boot/efi/loader/entries/.bc.tmp "/boot/efi/loader/entries/shanios-${slot}+3-0.conf"
    [[ $entry == */"shanios-${slot}+3-0.conf" ]] || rm -f "$entry"
    efivar_clear LoaderEntryPreferred; efivar_clear LoaderEntryDefault; efivar_clear LoaderEntryOneShot
    sed -i "s/^default .*/default shanios-${slot}.conf/" /boot/efi/loader/loader.conf
    sync
    res restore "$(ls /boot/efi/loader/entries | tr '\n' ' ')$(grep '^default' /boot/efi/loader/loader.conf)"
}

case ${1:-} in
    verify) verify ;;
    setup) shift; setup "$@" ;;
    arm-exhausted) shift; arm_exhausted "$@" ;;
    restore) shift; restore "$@" ;;
    *) echo "usage: boot-counting.sh verify | setup uki|efi [break-dm|fix-dm] | arm-exhausted SLOT KEY PREF|- DEFAULT|- | restore SLOT" >&2; exit 2 ;;
esac
