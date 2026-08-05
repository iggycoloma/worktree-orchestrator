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
        candidates="init add go list path sync diff-local container-up exec remove prune doctor help"
    else
        case "$cmd" in
            go|path|diff-local|container-up)
                [[ "$COMP_CWORD" -eq 2 ]] || return 0
                candidates="$(_wt_names)" ;;
            exec)
                # Past the name, the words belong to the container command.
                [[ "$COMP_CWORD" -eq 2 ]] || return 0
                candidates="$(_wt_names)" ;;
            sync)
                [[ "$COMP_CWORD" -eq 2 ]] || return 0
                candidates="--all $(_wt_names)" ;;
            remove)
                candidates="--branch $(_wt_names)" ;;
            list)
                candidates="--names" ;;
            add)
                # The name is new, so only the optional base ref completes.
                [[ "$COMP_CWORD" -eq 3 ]] || return 0
                candidates="$(_wt_branches)" ;;
            help)
                candidates="init add go list path sync diff-local container-up exec remove prune doctor" ;;
            *)
                return 0 ;;
        esac
    fi

    # Slugs and refs never contain whitespace, so plain word splitting is safe.
    # shellcheck disable=SC2207
    COMPREPLY=( $(compgen -W "$candidates" -- "$cur") )
}

complete -F _wt wt
