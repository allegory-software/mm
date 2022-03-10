#use die

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
	mysql_config "[mysqld]"
}

mysql_config() {
	echo "$1" >> /etc/mysql/mysql.conf.d/z.cnf
}

# percona xtrabackup ---------------------------------------------------------

xbkp() {
	local d="$1"; shift
	must xtrabackup --target-dir="$d" \
		--user=root --password="$(cat /root/mysql_root_pass)" $@
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

# mysql queries --------------------------------------------------------------

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

mysql_table_exists() { # db table
	[ "$(query "select 1 from information_schema.tables
		where table_schema = '$1' and table_name = '$2'")" ]
}

mysql_column_exists() { # db table column
	[ "$(query "select 1 from information_schema.columns
		where table_schema = '$1' and table_name = '$2' and column_name = '$3'")" ]
}

schema_version() { # deploy
	mysql_table_exists "$1" config \
		&& mysql_column_exists "$1" config schema_version \
		&& query "select schema_version from \`$1\`.config"
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
