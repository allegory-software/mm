#!/bin/bash

SDK_VERSION=work

# die hard, see https://github.com/capr/die
say()   { echo "$@" >&2; }
die()   { echo -n "ABORT: " >&2; echo "$@" >&2; exit 1; }
debug() { [ "$DEBUG" ] && echo "$@" >&2; }
run()   { debug -n "EXEC: $@ "; "$@"; local ret=$?; debug "[$ret]"; return $ret; }
must()  { debug -n "MUST: $@ "; "$@"; local ret=$?; debug "[$ret]"; [ $ret == 0 ] || die "$@ [$ret]"; }

run_app()  {      ./$APP "$@"; }
exec_app() { exec ./$APP "$@"; }

deploy() {
	set -u # break on undefined vars.
	say "Self-deploying APP=$APP ENV=$ENV VERSION=$VERSION..."

	if USE_MGIT; then
		must mgit convert
		must mgit baseurl luapower "git@github.com:luapower/"
		must mgit -SS clone-release $APP
	else
		local A=git@github.com:allegory-software
		local O="--depth=1 -b $SDK_VERSION --single-branch"
		must git clone $O $A/allegory-sdk               sdk
		must git clone $O $A/allegory-sdk-bin-debian10  sdk/bin/linux
	fi

	cat << EOF > ${APP}_conf.lua
return {
	deploy    = '$DEPLOY',
	env       = '$ENV',
	version   = '$VERSION',
	db_schema = '$MYSQL_SCHEMA',
	db_user   = '$MYSQL_USER',
	db_pass   = '$MYSQL_PASS',
	secret    = '$SECRET',
	log_host  = '127.0.0.1',
	log_port  = 5555,
}
EOF

	exec_app install
}

usage() {
	say
	say " USAGE: $APP [OPTIONS] COMMAND ..."
	say
	say "   run                               run the server in the console"
	say "   start | stop | restart | status   run the server in background"
	say "   tail                              tail the log file"
	say
	say "   [help|--help]                     show this screen"
	say
	run_app help extra
	say
	say " OPTIONS:"
	say
	say "   -v                                verbose"
	say "   --debug                           print commands"
	say
}

APP="$(basename "$0")"
must cd "${0%$APP}"

while true; do
	case "$1" in
		-v)       export VERBOSE=1; shift ;;
		--debug)  export DEBUG=1; shift ;;
		*)        break ;;
	esac
done
case "$1" in
	""|help|--help)  usage ;;
	deploy)          shift; deploy "$@" ;;
	run|start|stop|restart|status|tail) SERVICE=$APP exec sh/service "$@" ;;
	*)            exec_app "$@" ;;
esac
