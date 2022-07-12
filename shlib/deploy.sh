#use die ssh user mysql git apt

machine_set_hostname() { # machine
	local HOST="$1"
	checkvars HOST
	must hostnamectl set-hostname $HOST
	must sed -i '/^127.0.0.1/d' /etc/hosts
	append "\
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

acme_sh() {
	local cmd_args="/root/.acme.sh/acme.sh --config-home /root/.acme.sh.etc"
	run $cmd_args "$@"
	local ret=$?; [ $ret == 2 ] && ret=0 # skipping gets exit code 2.
	[ $ret == 0 ] || die "$cmd_args "$@" [$ret]"
}

acme_check() {
	say "Checking SSL certificate with acme.sh ... "
	acme_sh --cron
}

tarantool_install() { # tarantool 2.10
	must curl -L https://tarantool.io/BsbZsuW/release/2/installer.sh | bash
	apt_get_install tarantool
}

machine_prepare() {
	checkvars MACHINE MYSQL_ROOT_PASS DHPARAM-

	# disable clound-init because it resets our changes on reboot.
	sudo touch /etc/cloud/cloud-init.disabled

	machine_set_hostname $MACHINE
	machine_set_timezone UTC

	# remount /proc so we can pass in secrets via cmdline without them leaking.
	must mount -o remount,rw,nosuid,nodev,noexec,relatime,hidepid=2 /proc
	# make that permanent...
	must sed -i '/^proc/d' /etc/fstab
	append "proc  /proc  proc  defaults,nosuid,nodev,noexec,relatime,hidepid=1  0  0" /etc/fstab

	apt_get_install sudo htop mc git nginx gnupg2 lsb-release

	tarantool_install

	# add dhparam.pem from mm (dhparam is public).
	save "$DHPARAM" /etc/nginx/dhparam.pem

	# remove nginx placeholder vhost.
	must rm -f /etc/nginx/sites-enabled/default
	nginx -s reload

	# install acme.sh to auto-renew SSL certs.
	curl https://get.acme.sh | sh -s email=my@example.com --nocron --config-home /root/.acme.sh.etc

	# ZeroSSL is default but it's very slow, so we're switching back to LE.
	acme_sh --set-default-ca --server letsencrypt

	git_install_git_up
	git_config_user "mm@allegory.ro" "Many Machines"
	ssh_git_keys_update

	mysql_install
	mysql_config "\
# our binlog is row-based, but we still get an error when creating procs.
log_bin_trust_function_creators = 1
"
	must service mysql start
	mysql_update_pass localhost root $MYSQL_ROOT_PASS
	mysql_gen_my_cnf  localhost root $MYSQL_ROOT_PASS

	# allow binding to ports < 1024 by any user.
	must save 'net.ipv4.ip_unprivileged_port_start=0' \
		/etc/sysctl.d/50-unprivileged-ports.conf
	must sysctl --system

	say "Prepare done."
}

machine_rename() { # OLD_MACHINE NEW_MACHINE
	local OLD_MACHINE=$1
	local NEW_MACHINE=$2
	checkvars OLD_MACHINE NEW_MACHINE
	machine_set_hostname "$NEW_MACHINE"
}

deploy_nginx_config() { # DOMAIN= HTTP_PORT= DEPLOY= APP= $0 [acme]

	# acme thumbprint got with `acme.sh --register-account` (thumbprint is public).
	local ACME_THUMBPRINT="gXTX0h3wk2OSU0eL5VoACugp_I4GFhFmRt8BcdhSOG4"

	local acme_location="\
	location ~ ^/\.well-known/acme-challenge/([-_a-zA-Z0-9]+)$ {
		default_type text/plain;
		return 200 \"\$1.$ACME_THUMBPRINT\";
	}
"

	local nginx_conf

	if [ "$1" == acme ]; then

		checkvars DOMAIN

		nginx_conf="\
server {
	listen 80;
	server_name $DOMAIN;

$acme_location
}
"
	else

		checkvars HTTP_PORT DOMAIN DEPLOY APP

		cp_file /home/$DEPLOY/$APP/www/5xx.html /var/www/$DEPLOY/5xx.html

		local error_page="\
	error_page 502 503 504 /5xx.html;
	location /5xx.html {
		root /var/www/$DEPLOY;
	}
"

		nginx_conf="\
server {
	listen 80;
	server_name $DOMAIN;

	location / {
		return 301 https://\$host\$request_uri;
	}

$error_page
$acme_location
}

server {
	listen 443 ssl;
	server_name $DOMAIN;

	ssl_protocols TLSv1.2 TLSv1.3;
	ssl_ciphers ECDH+AESGCM:ECDH+AES256:ECDH+AES128:DH+3DES:!ADH:!AECDH:!MD5;
	ssl_prefer_server_ciphers on;
	ssl_session_cache shared:SSL:10m;
	ssl_session_timeout 4h;
	ssl_session_tickets on;
	ssl_certificate      /root/.acme.sh.etc/$DOMAIN/$DOMAIN.cer;
	ssl_certificate_key  /root/.acme.sh.etc/$DOMAIN/$DOMAIN.key;
	ssl_dhparam          /etc/nginx/dhparam.pem;

	# HSTS with preloading to google. Another amazing tech from the web people.
	add_header Strict-Transport-Security: \"max-age=63072000; includeSubDomains; preload\" always;

	location / {
		proxy_pass http://127.0.0.1:$HTTP_PORT;
		proxy_set_header X-Forwarded-Host \$http_host;
		proxy_set_header X-Forwarded-For  \$proxy_add_x_forwarded_for;
		proxy_set_header X-Forwarded-Port \$server_port;
	}

$error_page
$acme_location
}
"

fi

	save "$nginx_conf" /etc/nginx/sites-enabled/$DOMAIN
	say -n "Reloading nginx config... "
	must nginx -s reload
	say "OK"
}

deploy_issue_cert() { # DOMAIN
	local DOMAIN="$1"
	checkvars DOMAIN

	say "Issuing SSL certificate for $DOMAIN with acme.sh ... "
	local keyfile=/root/.acme.sh.etc/$DOMAIN/$DOMAIN.key
	deploy_nginx_config acme
	acme_sh --issue -d $DOMAIN --stateless
	[ -f $keyfile ] || die "SSL certificate not created: $keyfile."
}

deploy_setup() {
	checkvars DEPLOY MYSQL_PASS GIT_HOSTS-

	user_create    $DEPLOY
	user_lock_pass $DEPLOY

	ssh_git_keys_update_for_user $DEPLOY

	mysql_create_db     $DEPLOY
	mysql_create_user   localhost $DEPLOY $MYSQL_PASS
	mysql_grant_user_db localhost $DEPLOY $DEPLOY
	mysql_gen_my_cnf    localhost $DEPLOY $MYSQL_PASS $DEPLOY

	[ "$HTTP_PORT" -a "$DOMAIN" ] && deploy_nginx_config

	say "Deploy setup done."
}

deploy_remove() { # DEPLOY
	local DEPLOY="$1"
	checkvars DEPLOY

	user_remove $DEPLOY

	mysql_drop_db $DEPLOY
	mysql_drop_user localhost $DEPLOY

	say "Deploy removed."
}

app() {
	checkvars DEPLOY APP
	local dir=/home/$DEPLOY/$APP
	[ -d $dir ] || die "App dir missing. Not deployed?"
	(
	must cd /home/$DEPLOY/$APP
	VARS="DEBUG VERBOSE" run_as $DEPLOY ./$APP "$@"
	)
}

deploy() {
	checkvars DEPLOY REPO APP DEPLOY_VARS-
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

	deploy_gen_conf

	say "Installing the app..."
	must app install forealz

	must app start

	say "Deploy done."
}

deploy_gen_conf() {
	checkvars DEPLOY APP MYSQL_PASS SECRET
	local conf=/home/$DEPLOY/$APP/${APP}.conf
	must save "\
--deploy vars
deploy = '$DEPLOY'
${ENV:+env = '$ENV'}
${VERSION:+version = '$VERSION'}
db_name = '$DEPLOY'
db_user = '$DEPLOY'
db_pass = '$MYSQL_PASS'
secret = '$SECRET'

--custom vars
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
" $conf $DEPLOY
}

deploy_rename() { # OLD_DEPLOY NEW_DEPLOY [nosql]
	local OLD_DEPLOY="$1"
	local NEW_DEPLOY="$2"
	local OPT="$3"
	checkvars OLD_DEPLOY NEW_DEPLOY
	checkvars DEPLOY APP

	local MYSQL_PASS="$(mysql_pass $OLD_DEPLOY)"
	user_rename      $OLD_DEPLOY $NEW_DEPLOY
	mysql_rename_db  $OLD_DEPLOY $NEW_DEPLOY
	[ "$MYSQL_PASS" ] && \
		mysql_gen_my_cnf localhost $NEW_DEPLOY $MYSQL_PASS $NEW_DEPLOY

	deploy_gen_conf
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
