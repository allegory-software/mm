#!/bin/bash

app=mm

mgit=../bin/mgit

exec_app() { exec ./luajit $app.lua "$@"; }

install() {
	local env="$1"; shift; [ "$env" ] || env=work

	(
	cd ..
	git clone git@github.com:capr/multigit.git mgit
	mkdir -p bin
	ln -sf mgit/mgit bin/mgit
	)

	$mgit convert
	$mgit clone-release $app-$env
	exec_app install
}

usage() {
	echo "Usage: $app ..."
	echo "   start | stop | restart | status   control the server"
	echo "   see                               tail the log file"
	echo "   install                           install on a fresh user account"
	exec_app help
}

cd "${0%$app}" || exit 1

case "$1" in
	"")           usage ;;
	help)         usage ;;
	--help)       usage ;;
	install)      install "$@" ;;
	start|stop|restart|status|see) SERVICE=$app exec $mgit service "$@" ;;
	*)            exec_app "$@" ;;
esac
