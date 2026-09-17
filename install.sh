#!/usr/bin/env bash
# Installer for wt. Two ways in, one result:
#
#   curl -fsSL https://raw.githubusercontent.com/iggycoloma/worktree-orchestrator/main/install.sh | bash
#       clones (or fast-forwards) a managed checkout under XDG data and
#       installs from it
#
#   ./install.sh
#       run from inside a checkout, installs from that checkout -- no
#       second clone
#
# Installs symlinks under PREFIX (default ~/.local): bin/wt plus the bash,
# zsh and fish completions and the fish function, then prints what the
# user's shell still needs for 'wt go' and completion. Re-runnable; a dirty or diverged managed checkout is
# kept, never clobbered. Override WT_ORCH_REPO / WT_ORCH_DIR / PREFIX via
# the environment.
#
# The whole script runs through main() called on the last line, so a
# truncated download parses to nothing instead of executing half a script.

set -euo pipefail

WT_ORCH_REPO="${WT_ORCH_REPO:-https://github.com/iggycoloma/worktree-orchestrator.git}"
WT_ORCH_DIR="${WT_ORCH_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/worktree-orchestrator}"
PREFIX="${PREFIX:-$HOME/.local}"

log()  { printf 'wt-install: %s\n' "$*" >&2; }
warn() { printf 'wt-install: warning: %s\n' "$*" >&2; }
die()  { printf 'wt-install: error: %s\n' "$*" >&2; exit 1; }

main() {
    command -v git >/dev/null 2>&1 || die "git is required"

    # When run as a file, BASH_SOURCE names it; when piped, it is empty and
    # the dirname probe falls back to the cwd -- which is still the right
    # answer for someone piping from inside a checkout.
    local src script_dir
    script_dir="$(dirname "${BASH_SOURCE[0]:-.}")"
    if [[ -f "$script_dir/bin/wt" ]]; then
        src="$(cd "$script_dir" && pwd)"
    else
        # -e, not -d: a worktree-style checkout (wt's own orchestration
        # main/ included) has a .git pointer file, not a directory.
        if [[ -e "$WT_ORCH_DIR/.git" ]]; then
            if ! git -C "$WT_ORCH_DIR" pull --ff-only -q 2>/dev/null; then
                warn "could not fast-forward $WT_ORCH_DIR; keeping the existing checkout"
            fi
        else
            log "cloning $WT_ORCH_REPO -> $WT_ORCH_DIR"
            git clone -q "$WT_ORCH_REPO" "$WT_ORCH_DIR" || die "clone failed: $WT_ORCH_REPO"
        fi
        src="$WT_ORCH_DIR"
    fi
    [[ -x "$src/bin/wt" ]] || die "$src/bin/wt missing or not executable"

    mkdir -p "$PREFIX/bin" \
        "$PREFIX/share/bash-completion/completions" \
        "$PREFIX/share/zsh/site-functions" \
        "$PREFIX/share/fish/vendor_completions.d" \
        "$PREFIX/share/fish/vendor_functions.d"
    ln -sf "$src/bin/wt" "$PREFIX/bin/wt"
    ln -sf "$src/completions/wt.bash" "$PREFIX/share/bash-completion/completions/wt"
    ln -sf "$src/completions/_wt" "$PREFIX/share/zsh/site-functions/_wt"
    ln -sf "$src/completions/wt.fish" "$PREFIX/share/fish/vendor_completions.d/wt.fish"
    ln -sf "$src/functions/wt.fish" "$PREFIX/share/fish/vendor_functions.d/wt.fish"
    log "installed: $PREFIX/bin/wt -> $src/bin/wt"

    case ":$PATH:" in
        *":$PREFIX/bin:"*) ;;
        *) warn "$PREFIX/bin is not on PATH; add it to your shell profile" ;;
    esac
    command -v rsync >/dev/null 2>&1 \
        || warn "rsync not found; orchestration-mode provisioning needs it"
    command -v flock >/dev/null 2>&1 \
        || warn "flock not found; port allocation needs it (util-linux on Linux, 'brew install flock' on macOS)"

    "$PREFIX/bin/wt" version >&2

    shell_setup_hint
}

# 'wt go' can only cd from a shell function, and zsh only completes wt once
# the completion dir is registered; shell-init provides both. Printed rather
# than appended: the installer never edits startup files.
shell_setup_hint() {
    local shell_name="${SHELL:-}"
    shell_name="${shell_name##*/}"
    case "$shell_name" in
        bash|zsh)
            log "to enable 'wt go' and tab completion, add this line to ~/.${shell_name}rc:"
            log "  eval \"\$(wt shell-init $shell_name)\""
            ;;
        fish)
            # fish autoloads from <user data dir>/fish/vendor_*.d, so the
            # links above are the whole setup unless PREFIX is elsewhere.
            if [[ "$PREFIX/share" == "${XDG_DATA_HOME:-$HOME/.local/share}" ]]; then
                log "fish loads 'wt go' and tab completion from $PREFIX/share/fish on its own; open a new shell"
            else
                log "to enable 'wt go' and tab completion, add this line to ~/.config/fish/config.fish:"
                log "  wt shell-init fish | source"
            fi
            ;;
        *)
            log "'wt go' and tab completion need shell integration, available for bash, zsh and fish: see 'wt shell-init --help'"
            ;;
    esac
}

main "$@"
