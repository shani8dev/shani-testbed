#!/bin/bash
# slot-test-mode: boot
#
# fresh-user — what a person gets on a fresh install: a new user created
# from /etc/skel the way the installer does it (useradd -m -s /bin/zsh),
# then their first interactive shell, tools and desktop defaults, checked in
# the real image rather than in a container with hand-installed packages.
#
#   - every tool the shipped shell/git configs call is installed
#   - zsh, bash and fish start with no errors; zsh shows the fastfetch
#     greeting and the starship prompt
#   - /etc/tmux.conf is accepted by tmux; git's pager (delta) runs
#   - desktop profiles: the Nerd Font the Konsole/prompt glyphs need exists
#   - every key in every shipped *.gschema.override exists in the image's
#     schemas (a key for an app/schema the image doesn't have is silently
#     ignored by glib-compile-schemas); NEGATIVE control: a bogus override
#     is reported by the same check
#
# Checks for a feature carry the package version that first shipped it
# (`since`): an older image - e.g. the current stable, run by `gate` -
# reports SKIP naming its version instead of FAIL, so the test describes
# what that image claims to ship. A newer image that lost a feature still
# fails.
set -u
res() { printf 'RESULT %-40s %s\n' "$1" "$2"; }
has() {  # <pkg> <first-version> — installed at that version or newer
    local v; v=$(pacman -Q "$1" 2>/dev/null | awk '{print $2}')
    [[ -n $v ]] && (( $(vercmp "$v" "$2") >= 0 ))
}
since() {  # <result-name> <pkg> <first-version> — else report SKIP
    has "$2" "$3" && return 0
    res "$1" "SKIP ($2 $(pacman -Q "$2" 2>/dev/null | awk '{print $2}') predates $3)"
    return 1
}
u=freshuser H=/home/$u
userdel -r "$u" >/dev/null 2>&1
useradd -m -s /bin/zsh "$u" || { res useradd-from-skel FAIL; exit 0; }
res useradd-from-skel PASS
[[ -f $H/.zshrc && -f $H/.config/starship.toml ]] && res skel-copied PASS || res skel-copied "FAIL ($(ls -A $H | tr '\n' ' '))"

as_user() { runuser -u "$u" -- env -i HOME="$H" USER="$u" LOGNAME="$u" SHELL=/bin/zsh \
    PATH=/usr/local/bin:/usr/bin TERM=xterm-256color LANG=C.UTF-8 "$@"; }
in_pty() { as_user script -qefc "stty rows 40 cols 120; $1" /dev/null 2>&1 | tr -d '\r'; }
ERR='command not found|[Nn]o such file|[Ee]rror|unknown option|parse error|bad pattern|\(eval\)'

echo "== tools the shipped configs use"
missing=""
tools="zsh fish starship mcfly fzf fastfetch tmux micro"
has shani-settings 0.0.5-42 && tools+=" bat eza fd zoxide delta"
has shani-tools-extra 1.2-12 && tools+=" rg tldr"
for t in $tools; do
    command -v "$t" >/dev/null || missing+=" $t"
done
[[ -z $missing ]] && res config-tools-installed "PASS ($(wc -w <<<"$tools") tools)" || res config-tools-installed "FAIL (missing:$missing)"

echo "== first interactive shells"
out=$(in_pty "zsh -i -c 'print ZSH_DONE'")
bad=$(grep -E "$ERR" <<<"$out" | grep -v ZSH_DONE | head -3)
grep -q ZSH_DONE <<<"$out" && [[ -z $bad ]] && res zsh-starts-clean PASS || res zsh-starts-clean "FAIL (${bad:-no output})"
if since zsh-fastfetch-greeting shani-settings 0.0.5-42; then
    grep -q 'hani' <<<"$out" && res zsh-fastfetch-greeting PASS || res zsh-fastfetch-greeting FAIL
fi
p=$(as_user zsh -i -c 'starship prompt' 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g')
grep -q "$u" <<<"$p" && res starship-prompt PASS || res starship-prompt "FAIL ($(head -c 80 <<<"$p"))"
for sh in bash fish; do
    [[ $sh == bash ]] && as_user cp -n "$H/.bashrc_shani" "$H/.bashrc" 2>/dev/null
    out=$(in_pty "$sh -i -c 'echo SH_DONE'")
    bad=$(grep -E "$ERR" <<<"$out" | grep -v SH_DONE | head -3)
    grep -q SH_DONE <<<"$out" && [[ -z $bad ]] && res "$sh-starts-clean" PASS || res "$sh-starts-clean" "FAIL (${bad:-no output})"
done

echo "== tmux and git"
if since tmux-conf-accepted shani-settings 0.0.5-42; then
    out=$(as_user tmux -L fresh -f /dev/null new-session -d \; source-file /etc/tmux.conf 2>&1); rc=$?
    as_user tmux -L fresh kill-server 2>/dev/null
    [[ $rc -eq 0 && -z $out ]] && res tmux-conf-accepted PASS || res tmux-conf-accepted "FAIL ($out)"
fi
if since git-delta-pager shani-settings 0.0.5-42; then
    repo=$(as_user mktemp -d)
    as_user git -C "$repo" init -q && echo a | as_user tee "$repo/f" >/dev/null && as_user git -C "$repo" add f \
      && as_user git -C "$repo" -c user.name=t -c user.email=t@t commit -qm i && echo b | as_user tee "$repo/f" >/dev/null
    out=$(in_pty "git -C $repo --paginate diff"); rc=$?
    [[ $rc -eq 0 && $(git config --system core.pager) == delta ]] && ! grep -Eq "$ERR" <<<"$out" \
        && res git-delta-pager PASS || res git-delta-pager "FAIL (rc=$rc)"
fi

echo "== desktop defaults"
if [[ -d /usr/share/xsessions || -d /usr/share/wayland-sessions ]]; then
    if since nerd-font-installed shani-fonts 1.3-5; then
        fc-list : family | grep -qi 'FiraMono Nerd Font' && res nerd-font-installed PASS || res nerd-font-installed FAIL
    fi
else
    res nerd-font-installed "PASS (no desktop session on this profile)"
fi

# every key of every *.gschema.override must exist in the installed schemas
dead_keys() {  # override-file...
    local f l sec k
    for f in "$@"; do
        sec=
        while IFS= read -r l; do
            case "$l" in
                # [schema] or [schema:DESKTOP] (a desktop-specific override)
                "["*"]") sec=${l#[}; sec=${sec%]}; sec=${sec%%:*} ;;
                [a-z]*=*) k=${l%%=*}; k=${k% }
                    gsettings list-keys "$sec" 2>/dev/null | grep -qx "$k" || echo "$(basename "$f"): $sec $k" ;;
            esac
        done < "$f"
    done
}
if command -v gsettings >/dev/null && compgen -G '/usr/share/glib-2.0/schemas/*.gschema.override' >/dev/null; then
    mapfile -t ovr < <(ls /usr/share/glib-2.0/schemas/*.gschema.override)
    dead=$(dead_keys "${ovr[@]}")
    [[ -z $dead ]] && res gschema-override-keys-live "PASS (${#ovr[@]} files)" \
        || res gschema-override-keys-live "FAIL ($(wc -l <<<"$dead") dead: $(head -3 <<<"$dead" | tr '\n' ';'))"
    neg=$(mktemp --suffix=.gschema.override)
    printf '[org.gnome.desktop.interface]\nno-such-key=true\n[org.example.NoSuchSchema]\nfoo=1\n' > "$neg"
    [[ $(dead_keys "$neg" | wc -l) -eq 2 ]] && res gschema-check-negative-control PASS || res gschema-check-negative-control FAIL
    rm -f "$neg"
else
    res gschema-override-keys-live "PASS (no GSettings overrides on this profile)"
fi

userdel -r "$u" >/dev/null 2>&1
echo "== probe done"
