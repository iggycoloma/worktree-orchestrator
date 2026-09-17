# Fish completion for wt (see bin/wt).
#
# Worktree names come from `wt list --names`, which reads git's own worktree
# registry -- so completion covers worktrees created outside wt, and keeps
# working for slugs created under an older WT_SLUG_MAX.

function __wt_worktrees
    command wt list --names 2>/dev/null
end

function __wt_refs
    git for-each-ref --format='%(refname:short)' refs/heads refs/remotes 2>/dev/null
end

# True when the word being completed is argument number $argv[1] (the command
# itself is 1) of one of the subcommands that follow. One helper instead of
# stacked -n conditions, which fish before 3.4 does not accept.
function __wt_completing
    set -l words (commandline -opc)
    test (count $words) -eq (math $argv[1] - 1); or return 1
    test $argv[1] -eq 2; and return 0
    contains -- $words[2] $argv[2..-1]
end

function __wt_subcommand
    set -l words (commandline -opc)
    test (count $words) -ge 2; and contains -- $words[2] $argv
end

# Past --, the words belong to the container command.
function __wt_container_open
    set -l words (commandline -opc)
    __wt_subcommand container; and not contains -- -- $words
end

complete -c wt -f -n '__wt_completing 2' -a init -d 'create an orchestration dir'
complete -c wt -f -n '__wt_completing 2' -a convert -d 'convert the enclosing clone into an orchestration dir'
complete -c wt -f -n '__wt_completing 2' -a add -d 'create a worktree'
complete -c wt -f -n '__wt_completing 2' -a go -d 'cd into a worktree'
complete -c wt -f -n '__wt_completing 2' -a list -d 'list worktrees for the current project'
complete -c wt -f -n '__wt_completing 2' -a path -d 'print the worktree\'s path'
complete -c wt -f -n '__wt_completing 2' -a pull -d 'fetch origin and fast-forward a worktree'
complete -c wt -f -n '__wt_completing 2' -a git -d 'run git in the named worktree'
complete -c wt -f -n '__wt_completing 2' -a sync -d 'refresh local/ files into a worktree'
complete -c wt -f -n '__wt_completing 2' -a container -d 'manage the worktree\'s dev container'
complete -c wt -f -n '__wt_completing 2' -a remove -d 'remove a worktree + its containers'
complete -c wt -f -n '__wt_completing 2' -a prune -d 'clean up stale worktree administrative entries'
complete -c wt -f -n '__wt_completing 2' -a ignore -d 'write a workspace .ignore'
complete -c wt -f -n '__wt_completing 2' -a doctor -d 'check layout, tooling, and provisioning config'
complete -c wt -f -n '__wt_completing 2' -a shell-init -d 'print shell integration'
complete -c wt -f -n '__wt_completing 2' -a version -d 'print the version and origin'
complete -c wt -f -n '__wt_completing 2' -a help -d 'show help for a command'

complete -c wt -f -n '__wt_completing 3 go path pull git remove' -a '(__wt_worktrees)'
complete -c wt -f -n '__wt_subcommand sync' -a '(__wt_worktrees)'
complete -c wt -f -n '__wt_subcommand sync' -l all -d 'sync main plus every worktree'
complete -c wt -f -n '__wt_subcommand sync' -l diff -d 'preview drift without copying'
complete -c wt -f -n '__wt_subcommand pull' -l all -d 'pull main plus every worktree'
complete -c wt -f -n '__wt_subcommand remove' -l branch -d 'also delete the branch'

complete -c wt -f -n '__wt_completing 3 container' -a 'up exec'
complete -c wt -f -n '__wt_completing 4 container' -a '(__wt_worktrees)'
complete -c wt -n __wt_container_open -l config -r -F -d 'pick a devcontainer.json'

complete -c wt -f -n '__wt_subcommand add' -l json -d 'print the created worktree as one object'
complete -c wt -f -n '__wt_completing 4 add' -a '(__wt_refs)'

complete -c wt -f -n '__wt_subcommand list' -l names -d 'print bare directory names, one per line'
complete -c wt -f -n '__wt_subcommand list doctor version' -l json -d 'print structured output'
complete -c wt -f -n '__wt_subcommand convert' -l dry-run -d 'print the plan and change nothing'
complete -c wt -n '__wt_subcommand ignore' -l print -d 'write to stdout instead of the file'
complete -c wt -f -n '__wt_completing 3 shell-init' -a 'bash zsh fish'
complete -c wt -f -n '__wt_completing 3 help' -a 'init convert add go list path pull git sync container remove prune ignore doctor shell-init version'
