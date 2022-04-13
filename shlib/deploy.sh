#use die ssh user mysql git apt

machine_set_hostname() { # machine
	local HOST="$1"
	checkvars HOST
	must hostnamectl set-hostname $HOST
	must sed -i '/^127.0.0.1/d' /etc/hosts
	must append "\
127.0.0.1 $HOST $HOST
127.0.0.1 localhost
" /etc/hosts
	say "Machine hostname set to: $HOST."
}

machine_set_timezone() { # tz
	local TZ="$1"
	checkvars TZ
	must timedatectl set-timezone "$TZ" # sets /etc/localtime and /etc/timezone
	say "Machine timezone set to: $TZ."
}

machine_prepare() {
	checkvars MACHINE MYSQL_ROOT_PASS

	# disable clound-init because it resets our changes on reboot.
	sudo touch /etc/cloud/cloud-init.disabled

	machine_set_hostname $MACHINE
	machine_set_timezone UTC

	apt_get_install sudo htop mc git gnupg2 lsb-release

	git_install_git_up
	git_config_user "mm@allegory.ro" "Many Machines"
	ssh_git_keys_update

	percona_pxc_install
	mysql_config "\
log_bin_trust_function_creators = 1
default-time-zone = '+00:00'
"
	must service mysql start
	mysql_update_root_pass "$MYSQL_ROOT_PASS"

	# allow binding to ports < 1024 by any user.
	must save 'net.ipv4.ip_unprivileged_port_start=0' \
		/etc/sysctl.d/50-unprivileged-ports.conf
	must sysctl --system

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

	git_clone_for $DEPLOY $REPO /home/$DEPLOY/$APP "$VERSION" app

	git_clone_for $DEPLOY \
		git@github.com:allegory-software/allegory-sdk \
		/home/$DEPLOY/$APP/sdk "$SDK_VERSION" sdk

	git_clone_for $DEPLOY \
		git@github.com:allegory-software/allegory-sdk-bin-debian10 \
		/home/$DEPLOY/$APP/sdk/bin/linux "$SDK_VERSION"

	VARS="DEBUG VERBOSE $DEPLOY_VARS" \
	FUNCS="say die debug run must deploy_gen_conf" \
		run_as $DEPLOY app_setup_script

	say "Installing the app..."
	must app install forealz

	must app start

	say "Deploy done."
}

deploy_gen_conf() {
	echo -n "\
--deploy vars
${DEPLOY:+deploy = '$DEPLOY'}
${ENV:+env = '$ENV'}
${VERSION:+version = '$VERSION'}
${MYSQL_DB:+db_name = '$MYSQL_DB'}
${MYSQL_USER:+db_user = '$MYSQL_USER'}
${MYSQL_PASS:+db_pass = '$MYSQL_PASS'}
${SECRET:+secret = '$SECRET'}

--custom vars
${HTTP_PORT:+http_port = '$HTTP_PORT'}
${HTTP_PORT:+http_port = $HTTP_PORT}
${SMTP_HOST:+smtp_host = '$SMTP_HOST'}
${SMTP_HOST:+smtp_user = '$SMTP_USER'}
${SMTP_HOST:+smtp_pass = '$SMTP_PASS'}
${HOST:+host = '$HOST'}
${NOREPLY_EMAIL:+noreply_email = '$NOREPLY_EMAIL'}
${DEV_EMAIL:+dev_email = '$DEV_EMAIL'}
${DEFAULT_COUNTRY:+default_country = '$DEFAULT_COUNTRY'}
${SESSION_COOKIE_SECURE_FLAG:+session_cookie_secure_flag = $SESSION_COOKIE_SECURE_FLAG}

log_host = '127.0.0.1'
log_port = 5555
https_addr = false
"
}

app_setup_script() {
	must deploy_gen_conf > /home/$DEPLOY/$APP/${APP}.conf
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
