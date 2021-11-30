
# die hard, see https://github.com/capr/die
say()   { echo "$@" >&2; }
die()   { echo -n "ABORT: " >&2; echo "$@" >&2; exit 1; }
debug() { [ -z "$DEBUG" ] || echo "$@" >&2; }
run()   { debug -n "EXEC: $@ "; "$@"; local ret=$?; debug "[$ret]"; return $ret; }
must()  { debug -n "MUST: $@ "; "$@"; local ret=$?; debug "[$ret]"; [ $ret == 0 ] || die "$@ [$ret]"; }

run_as() { sudo -u "$1" -s DEBUG="$DEBUG" VERBOSE="$VERBOSE" -s --; }

rm_subdir() {
	[ "${1:0:1}" == "/" ] || { say "base dir not absolute"; return 1; }
	[ "$2" ] || { say "subdir required"; return 1; }
	local dir="$1/$2"
	say "Removing dir '$dir'..."
	must rm -rf "$dir"
}

ssh_hostkey_update() { # host fingerprint
	say "Updating SSH host fingerprint for host '$1' (/etc/ssh)..."
	local kh=/etc/ssh/ssh_known_hosts
	run ssh-keygen -R "$1" -f $kh
	must printf "%s\n" "$2" >> $kh
	must chmod 644 $kh
}

ssh_host_update() { # host keyname [moving_ip]
	say "Assigning SSH key '$2' to host '$1' $HOME $3..."
	must mkdir -p $HOME/.ssh
	local CONFIG=$HOME/.ssh/config
	sed < $CONFIG "/^$/d;s/Host /$NL&/" | sed '/^Host '"$1"'$/,/^$/d;' > $CONFIG
	(
		printf "%s\n" "Host $1"
		printf "\t%s\n" "HostName $1"
		printf "\t%s\n" "IdentityFile $HOME/.ssh/${2}.id_rsa"
		[ "$3" ] && printf "\t%s\n" "CheckHostIP no"
	) >> $CONFIG
	must chown $USER:$USER -R $HOME/.ssh
}

ssh_key_update() { # keyname key
	say "Updating SSH key '$1' ($HOME)..."
	must mkdir -p $HOME/.ssh
	local idf=$HOME/.ssh/${1}.id_rsa
	must printf "%s" "$2" > $idf
	must chmod 600 $idf
	must chown $USER:$USER -R $HOME/.ssh
}

ssh_host_key_update() { # host keyname key [moving_ip]
	ssh_key_update "$2" "$3"
	ssh_host_update "$1" "$2" "$4"
}

ssh_update_pubkey() { # keyname key
	say "Updating SSH public key '$1'..."
	local ak=$HOME/.ssh/authorized_keys
	must mkdir -p $HOME/.ssh
	[ -f $ak ] && must sed -i "/ $1/d" $ak
	must printf "%s\n" "$2" >> $ak
	must chmod 600 $ak
	must chown $USER:$USER -R $HOME/.ssh
}

ssh_pubkey() { # keyname
	cat $HOME/.ssh/authorized_keys | grep " $1\$"
}

git_install_git_up() {
	say "Installing 'git up' command..."
	local git_up=/usr/lib/git-core/git-up
	cat << 'EOF' > $git_up
msg="$1"; [ "$msg" ] || msg="unimportant"
git add -A .
git commit -m "$msg"
git push
EOF
	must chmod +x $git_up
}

git_config_user() { # email name
	run git config --global user.email "$1"
	run git config --global user.name "$2"
}

user_create() { # user
	say "Creating user '$1'..."
	must useradd -m $1
	must chsh -s /bin/bash $1
}

user_lock_pass() { # user
	say "Locking password for user '$1'..."
	must passwd -l $1 >&2
}

user_remove() {
	[ "$1" ] || die "user required"
	say "Removing user '$1'..."
	id -u $1 &>/dev/null && must userdel $1
	rm_subdir /home $1
}

has_mysql() { which mysql >/dev/null; }

query() {
	if [ -f /root/mysql_root_pass ]; then
		MYSQL_PWD="$(cat /root/mysql_root_pass)" must mysql -N -B -h 127.0.0.1 -u root -e "$1"
	else
		# on a fresh mysql install we can login from the `root` system user
		# as mysql user `root` without a password because the default auth
		# plugin for `root` (without hostname!) is `unix_socket`.
		must mysql -N -B -u root -e "$1"
	fi
}

mysql_create_user() { # host user pass
	say "Creating MySQL user '$2@$1'..."
	query "
		create user '$2'@'$1' identified with mysql_native_password by '$3';
		flush privileges;
	"
}

mysql_drop_user() { # host user
	say "Dropping MySQL user '$2@$1'..."
	query "drop user if exists '$2'@'$1'; flush privileges;"
}

mysql_update_pass() { # host user pass
	say "Updating MySQL password for user '$2@$1'..."
	query "
		alter user '$2'@'$1' identified with mysql_native_password by '$3';
		flush privileges;
	"
}

mysql_update_root_pass() { # pass
	mysql_update_pass localhost root "$1"
	must echo -n "$1" > /root/mysql_root_pass
	must chmod 600 /root/mysql_root_pass
}

mysql_create_schema() { # schema
	say "Creating MySQL schema '$1'..."
	query "
		create database $1
			character set utf8mb4
			collate utf8mb4_unicode_ci;
	"
}

mysql_drop_schema() { # schema
	say "Dropping MySQL schema '$1'..."
	query "drop database if exists $1"
}

mysql_grant_user() { # host user schema
	query "
		grant all privileges on $3.* to '$2'@'$1';
		flush privileges;
	"
}

apt_get() {
	export DEBIAN_FRONTEND=noninteractive
	must apt-get -y -qq -o=Dpkg::Use-Pty=0 $@
}

apt_get_install() { # package1 ...
	say "Installing packages: $@..."
	apt_get update
	apt_get install $@
}

percona_pxc_install() {
	local f=percona-release_latest.generic_all.deb
	must wget -nv https://repo.percona.com/apt/$f
	export DEBIAN_FRONTEND=noninteractive
	must dpkg -i $f
	apt_get update
	apt_get install --fix-broken
	must rm $f
	must percona-release setup -y pxc80
	apt_get_install percona-xtradb-cluster percona-xtrabackup-80 qpress
}

mgit_install() {
	must mkdir -p /opt
	must cd /opt
	if [ -d mgit ]; then
		cd mgit && git pull
	else
		must git clone git@github.com:capr/multigit.git mgit
	fi
	must ln -sf /opt/mgit/mgit /usr/local/bin/mgit
}

xbkp() {
	local d="$1"; shift
	must xtrabackup --target-dir="$d" \
		--user=root --password="$(cat /root/mysql_root_pass)" $@
}

mysql_table_exists() { # schema table
	[ "$(query "select 1 from information_schema.tables
		where table_schema = '$1' and table_name = '$2'")" ]
}

mysql_column_exists() { # schema table column
	[ "$(query "select 1 from information_schema.columns
		where table_schema = '$1' and table_name = '$2' and column_name = '$3'")" ]
}

schema_version() { # deploy
	mysql_table_exists "$1" config \
		&& mysql_column_exists "$1" config schema_version \
		&& query "select schema_version from \`$1\`.config"
}

xbkp_backup() { # deploy bkp parent_bkp
	local sv="$(schema_version)"; [ "$sv" ] || sv=0
	local d="/root/mm-bkp/$1/$sv-$2"
	must mkdir -p "$d"
	must xbkp "$d" --backup --databases="$1" --compress --compress-threads=2
}

xbkp_restore() { # deploy bkp
	local d="/root/mm-bkp/$1/$2"
	xbkp "$d" --decompress --parallel --decompress-threads=2
	xbkp "$d" --prepare --export
	xbkp "$d" --move-back
}

xbkp_remove() { # deploy bkp
	[ "$1" ] || die "deploy missing"
	rm_subdir "/root/mm-bkp/$1" "$2"
}

