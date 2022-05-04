
# die hard, see https://github.com/capr/die
say()       { echo "$@" >&2; }
die()       { echo -n "ABORT: " >&2; echo "$@" >&2; exit 1; }
debug()     { if [ "$DEBUG" ]; then echo "$@" >&2; fi; }
run()       { debug -n "EXEC: $@ "; "$@"; local ret=$?; debug "[$ret]"; return $ret; }
must()      { debug -n "MUST: $@ "; "$@"; local ret=$?; debug "[$ret]"; [ $ret == 0 ] || die "$@ [$ret]"; }

# enhanced sudo that can:
#  1. inherit a list of vars.
#  2. run a local function. including multiple function definitions.
run_as() { # user cmd
	local user="$1"; shift
	local cmd="$1"; shift
	local vars="$(for v in $VARS; do printf '%q=%q ' "$v" "${!v}"; done;)"
	local decl="$(declare -f $FUNCS $cmd)"
	if [ "$decl" ]; then
		echo "$decl; $cmd" | eval sudo -u "$user" $vars bash -s
	else
		eval sudo -u "$user" $vars "$cmd" "$@"
	fi
}

checkvars() { # NAME1[-] NAME2 ...
	local var
	for var in $@; do
		if [ "${var::-1}-" == "${var}" ]; then # spaces allowed
			var="${var::-1}"
			[ "${!var}" ] || die "${FUNCNAME[1]}: \$$var required"
		else
			[ "${!var}" ] || die "${FUNCNAME[1]}: \$$var required"
			[[ "${!var}" =~ ( |\') ]] && die "${FUNCNAME[1]}: \$$var contains spaces"
		fi
	done
}

# frontend for calling shlib function safely without exiting the shell.
mm() {
	cmd="${1//\-/_}"; shift
	($cmd "$@")
}
