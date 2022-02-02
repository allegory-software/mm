#!/bin/bash
app_dir="$(dirname "$0")"
app_name="$(basename "$0")"
exec "$app_dir/sdk/bin/linux/luajit" "$app_dir/$app_name.lua" "$@"

SDK_VERSION=work

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
}
