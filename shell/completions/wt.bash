#!/usr/bin/env bash
# Bash completion for wt (see bin/wt).
#
# Worktree names come from `wt list --names`, which reads git's own worktree
# registry -- so completion covers worktrees created outside wt, and keeps
# working for slugs created under an older WT_SLUG_MAX.

_wt_names() {
    wt list --names 2>/dev/null
}

_wt_branches() {
    git for-each-ref --format='%(refname:short)' refs/heads refs/remotes 2>/dev/null
}

_wt() {
    local cur cmd candidates
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]}"
    cmd="${COMP_WORDS[1]:-}"

    if [[ "$COMP_CWORD" -eq 1 ]]; then
        candidates="init add go list path pull git sync container remove prune ignore doctor version help"
    else
        case "$cmd" in
            go|path|pull)
                [[ "$COMP_CWORD" -eq 2 ]] || return 0
                candidates="$(_wt_names)" ;;
            container)
                # up|exec, then the name; past that the words belong to the
                # container command.
                if [[ "$COMP_CWORD" -eq 2 ]]; then
                    candidates="up exec"
                elif [[ "$COMP_CWORD" -eq 3 ]]; then
                    candidates="$(_wt_names)"
                else
                    return 0
                fi ;;
            git)
                if [[ "$COMP_CWORD" -eq 2 ]]; then
                    candidates="$(_wt_names)"
                else
                    # Past the name, delegate to git's own completion so
                    # subcommands, flags, and refs complete as after 'git '.
                    # Refs are shared repo-wide, so cwd context is correct.
                    if ! declare -F __git_func_wrap >/dev/null 2>&1 \
                        && declare -F _completion_loader >/dev/null 2>&1; then
                        _completion_loader git 2>/dev/null
                    fi
                    if declare -F __git_func_wrap >/dev/null 2>&1; then
                        COMP_WORDS=(git "${COMP_WORDS[@]:3}")
                        ((COMP_CWORD -= 2))
                        __git_func_wrap __git_main
                    fi
                    return 0
                fi ;;
            sync)
                # Name and flags are order-free; offer whichever remain.
                candidates="--all --diff $(_wt_names)" ;;
            remove)
                # The name completes only at the name position; later words
                # can only be the flag.
                if [[ "$COMP_CWORD" -eq 2 ]]; then
                    candidates="--branch $(_wt_names)"
                else
                    candidates="--branch"
                fi ;;
            list)
                candidates="--names --json" ;;
            ignore)
                # Target is any workspace directory, not a worktree name.
                if [[ "$cur" == -* ]]; then
                    candidates="--print"
                else
                    # shellcheck disable=SC2207
                    COMPREPLY=( $(compgen -d -- "$cur") )
                    return 0
                fi ;;
            init)
                # <url> has nothing to offer; <dir> completes directories.
                [[ "$COMP_CWORD" -eq 3 ]] || return 0
                # shellcheck disable=SC2207
                COMPREPLY=( $(compgen -d -- "$cur") )
                return 0 ;;
            add)
                # The name is new, so only the optional base ref and the
                # output flag complete.
                if [[ "$cur" == -* ]]; then
                    candidates="--json"
                elif [[ "$COMP_CWORD" -eq 3 ]]; then
                    candidates="$(_wt_branches)"
                else
                    return 0
                fi ;;
            doctor|version)
                candidates="--json" ;;
            help)
                candidates="init add go list path pull git sync container remove prune ignore doctor version" ;;
            *)
                return 0 ;;
        esac
    fi

    # Slugs and refs never contain whitespace, so plain word splitting is safe.
    # shellcheck disable=SC2207
    COMPREPLY=( $(compgen -W "$candidates" -- "$cur") )
}

complete -F _wt wt
