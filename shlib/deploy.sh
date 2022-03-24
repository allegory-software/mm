#use die ssh user mysql git apt

machine_prepare() {
	checkvars MYSQL_ROOT_PASS

	apt_get_install sudo htop mc git gnupg2 lsb-release

	git_install_git_up
	git_config_user "mm@allegory.ro" "Many Machines"
	ssh_git_keys_update

	percona_pxc_install
	mysql_config "log_bin_trust_function_creators = 1"
	must service mysql start
	mysql_update_root_pass "$MYSQL_ROOT_PASS"

	# allow binding to ports < 1024.
	echo 'net.ipv4.ip_unprivileged_port_start=0' > /etc/sysctl.d/50-unprivileged-ports.conf
	sysctl --system

	say "Prepare done."
}

deploy_setup() {
	checkvars DEPLOY MYSQL_PASS GIT_HOSTS

	[ -d /home/$DEPLOY ] && return

	user_create $DEPLOY
	user_lock_pass $DEPLOY

	ssh_git_keys_update_for_user $DEPLOY

	mysql_create_db $DEPLOY
	mysql_create_user localhost $DEPLOY "$MYSQL_PASS"
	mysql_grant_user  localhost $DEPLOY $DEPLOY

	say "First-time setup done."
}

deploy_remove() {
	checkvars DEPLOY

	deploy_app_stop
	mysql_drop_db $DEPLOY
	mysql_drop_user localhost $DEPLOY
	user_remove $DEPLOY

	say "Deploy removed."
}

app() {
	checkvars DEPLOY APP
	(
	must cd /home/$DEPLOY/$APP
	VARS="DEBUG VERBOSE" run_as $DEPLOY ./$APP "$@"
	)
}

deploy() {
	checkvars DEPLOY REPO APP ENV DEPLOY_VARS
	say "Deploying APP=$APP ENV=$ENV VERSION=$VERSION SDK_VERSION=$SDK_VERSION..."

	[ -d /home/$DEPLOY/$APP ] && app running && must app stop

	deploy_setup

	git_clone_for $DEPLOY $REPO /home/$DEPLOY/$APP "$VERSION"

	git_clone_for $DEPLOY \
		git@github.com:allegory-software/allegory-sdk \
		/home/$DEPLOY/$APP/sdk "$SDK_VERSION"

	git_clone_for $DEPLOY \
		git@github.com:allegory-software/allegory-sdk-bin-debian10 \
		/home/$DEPLOY/$APP/sdk/bin/linux "$SDK_VERSION"

	VARS="DEBUG VERBOSE $DEPLOY_VARS" \
	FUNCS="say die debug run must" \
		run_as $DEPLOY app_setup_script

	say "Installing the app..."
	must app install forealz

	must app start

	say "Deploy done."
}

app_setup_script() {

	local s="\
deploy     = '$DEPLOY'
env        = '$ENV'
version    = '$VERSION'
db_name    = '$MYSQL_DB'
db_user    = '$MYSQL_USER'
db_pass    = '$MYSQL_PASS'
secret     = '$SECRET'
--custom vars
smtp_host  = '$SMTP_HOST'
smtp_user  = '$SMTP_USER'
smtp_pass  = '$SMTP_PASS'
host       = '$HOST'
noreply_email = '$NOREPLY_EMAIL'
dev_email  = '$DEV_EMAIL'
default_country = '$DEFAULT_COUNTRY'
log_host   = '127.0.0.1'
log_port   = 5555
session_cookie_secure_flag = '$SESSION_COOKIE_SECURE_FLAG' ~= 'false'
https_addr = false
"
	must echo "$s" > /home/$DEPLOY/$APP/${APP}.conf

}

deploy_status() {
	checkvars DEPLOY APP
	[ -d /home/$DEPLOY                    ] || say "no /home/$DEPLOY dir"
	[ -d /home/$DEPLOY/$APP               ] || say "no /home/$DEPLOY/$APP dir"
	[ -d /home/$DEPLOY/$APP/sdk           ] || say "no sdk dir"
	[ -d /home/$DEPLOY/$APP/sdk/bin/linux ] || say "no sdk/bin/linux dir"
	[ -f /home/$DEPLOY/$APP/${APP}.conf   ] || say "no ${APP}.conf"
	app status
}
