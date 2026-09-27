#!/bin/bash
# slot-test-mode: boot
#
# pam-wiring — every PAM module referenced by a shipped PAM service is actually
# installed, and Shanios' own system-auth override still resolves.
#
# WHY THIS EXISTS: a PAM service can name a module that no installed package
# provides, and nothing warns. PAM does not fail at install time; the stack only
# breaks when that service is used, which for a greeter service means the
# feature is silently dead. Found on a real Arch install: gdm-smartcard loads
# `auth required pam_pkcs11.so` and no official Arch repository ships
# pam_pkcs11.so, so PIV card login could not work on any edition. A reference is
# not a shipment — both directions have to be checked.
#
# NEGATIVE control: a planted service naming a module that does not exist is
# reported, then removed.
set -u
res() { printf 'RESULT %-40s %s\n' "$1" "$2"; }

SEC_DIRS="/usr/lib/security /lib/security /usr/lib64/security"

# Echo "<service>:<module>" for every referenced module that resolves to no file.
missing_modules() {
    local svc mod dir
    for svc in /etc/pam.d/* /usr/lib/pam.d/*; do
        [ -f "$svc" ] || continue
        # module args are whitespace-separated; first field is the module path
        # Only tokens ending in .so are modules. That filters out @include
        # service names (system-auth, system-login) and the words inside a
        # bracketed control field ([success=ok default=1]) without having to
        # re-parse PAM's grammar. Split on [:space:] and not just " ": PAM
        # aligns with TABS, so splitting on spaces leaves a whole line as one
        # token whose tail still matches an unanchored .so pattern.
        for mod in $(sed -e 's/#.*$//' "$svc" | tr '[:space:]' '\n' \
                       | grep -E '^pam_[A-Za-z0-9_.-]*\.so$' | sort -u); do
            [ -n "$mod" ] || continue
            case "$mod" in /*) ;; *) mod="$mod" ;; esac
            local found=0
            for dir in $SEC_DIRS; do
                if [ -e "$dir/$mod" ]; then found=1; break; fi
            done
            [ "$found" -eq 1 ] || echo "$(basename "$svc"):$mod"
        done
    done
}

NEG=/etc/pam.d/zz-shani-negctl-pam-wiring
cleanup() { rm -f "$NEG"; }
trap cleanup EXIT

# --- the real check -------------------------------------------------------
missing=$(missing_modules)
if [ -z "$missing" ]; then
    res pam-modules-resolve "PASS (every referenced PAM module is installed)"
else
    while read -r bad; do
        [ -n "$bad" ] || continue
        res pam-module-missing "FAIL ($bad is referenced but not installed)"
    done <<<"$missing"
fi

# --- Shanios' own override, if present -----------------------------------
if [ -f /etc/pam.d/system-auth ] && grep -q '^auth .*pam_u2f\.so' /etc/pam.d/system-auth; then
    if [ -e /usr/lib/security/pam_u2f.so ] || [ -e /lib/security/pam_u2f.so ]; then
        res shani-system-auth-u2f "PASS (system-auth adds pam_u2f.so and it is installed)"
    else
        res shani-system-auth-u2f "FAIL (system-auth references pam_u2f.so but it is not installed)"
    fi
else
    res shani-system-auth-u2f "SKIP (system-auth has no pam_u2f line; image predates the override)"
fi

# --- NEGATIVE control: the check must catch a planted dangling reference --
printf 'auth required pam_shani_definitely_not_a_real_module.so\n' > "$NEG"
if missing_modules | grep -q 'zz-shani-negctl-pam-wiring:'; then
    res negative-control-detected "PASS (planted dangling module reference was reported)"
else
    res negative-control-detected "FAIL (planted dangling module reference was NOT reported)"
fi
cleanup
trap - EXIT

echo "== probe done"
