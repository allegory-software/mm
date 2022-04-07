#use die fs

# percona install ------------------------------------------------------------

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
	mysql_config_clear
	mysql_config "[mysqld]"
}

mysql_config_clear() {
	must save "" /etc/mysql/mysql.conf.d/z.cnf
}

mysql_config() {
	must append "$1" /etc/mysql/mysql.conf.d/z.cnf
}

# percona xtrabackup ---------------------------------------------------------

xbkp() {
	local DIR="$1"; shift
	must xtrabackup --target-dir="$DIR" --user=root $@ # password read from ~/.my.cnf
}

xbkp_backup() { # deploy bkp [parent_bkp]
	local DEPLOY="$1"
	local BKP="$2"
	local PARENT_BKP="$3"
	checkvars DEPLOY BKP
	local d="/root/mm-bkp/$DEPLOY/$BKP"
	must mkdir -p "$d"
	xbkp "$d" --backup --databases="$DEPLOY" --compress --compress-threads=2
	du -b "$d" | cut -f1                      # backup size
	sha1sum "$d"/* | sha1sum | cut -d' ' -f1  # checksum
}

xbkp_restore() { # deploy bkp
	local DEPLOY="$1"
	local BKP="$2"
	checkvars DEPLOY BKP
	local d="/root/mm-bkp/$DEPLOY/$BKO"
	xbkp "$d" --decompress --parallel --decompress-threads=2
	xbkp "$d" --prepare --export
	xbkp "$d" --move-back
}

xbkp_copy() { # deploy bkp host
	local DEPLOY="$1"
	local BKP="$2"
	local HOST="$3"
	checkvars DEPLOY BKP HOST
	rsync_to "$HOST" "/root/mm-bkp/$DEPLOY/$BKP"
}

xbkp_remove() { # deploy bkp
	local DEPLOY="$1"
	local BKP="$2"
	checkvars DEPLOY BKP
	rm_subdir "/root/mm-bkp/$DEPLOY" "$BKP"
}

# mysql queries --------------------------------------------------------------

has_mysql() { which mysql >/dev/null; }

query() {
	if [ -f /root/.my.cnf ]; then
		must mysql -N -B -h localhost -u root -e "$1"
	else
		# on a fresh mysql install we can login from the `root` system user
		# as mysql user `root` without a password because the default auth
		# plugin for `root` (without hostname!) is `unix_socket`.
		must mysql -N -B -u root -e "$1"
	fi
}

mysql_table_exists() { # db table
	[ "$(query "select 1 from information_schema.tables
		where table_schema = '$1' and table_name = '$2'")" ]
}

mysql_column_exists() { # db table column
	[ "$(query "select 1 from information_schema.columns
		where table_schema = '$1' and table_name = '$2' and column_name = '$3'")" ]
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
	must save "\
[client]
password=$1
" /root/.my.cnf
	must chmod 600 /root/.my.cnf
}

mysql_create_db() { # db
	say "Creating MySQL database '$1'..."
	query "
		create database \`$1\`
			character set utf8mb4
			collate utf8mb4_unicode_ci;
	"
}

mysql_drop_db() { # db
	say "Dropping MySQL database '$1'..."
	query "drop database if exists \`$1\`"
}

mysql_grant_user() { # host user db
	query "
		grant all privileges on \`$3\`.* to '$2'@'$1';
		flush privileges;
	"
}
