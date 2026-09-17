# Fish autoload stub for wt (see bin/wt).
#
# install.sh links this into fish's vendor_functions.d, where fish sources it
# the first time `wt` is typed. The function body comes from the executable
# so that it has one definition, the one `wt shell-init fish` prints.
command wt shell-init fish | source
