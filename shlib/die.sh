
# die hard, see https://github.com/capr/die
say()   { echo "$@" >&2; }
die()   { echo -n "ABORT: " >&2; echo "$@" >&2; exit 1; }
debug() { [ -z "$DEBUG" ] || echo "$@" >&2; }
run()   { debug -n "EXEC: $@ "; "$@"; local ret=$?; debug "[$ret]"; return $ret; }
must()  { debug -n "MUST: $@ "; "$@"; local ret=$?; debug "[$ret]"; [ $ret == 0 ] || die "$@ [$ret]"; }

run_as() { sudo -u "$1" -s DEBUG="$DEBUG" VERBOSE="$VERBOSE" -s --; }
