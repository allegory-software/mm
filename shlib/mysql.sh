#use die fs

# percona install ------------------------------------------------------------

mysql_install() {
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

mysql_config() {
	must save "
[mysqld]
$1" /etc/mysql/mysql.conf.d/z.cnf
}

# TODO: install percona's monitoring and management tool and see if it's
# worth having it running.
mysql_set_pool_size() {
	query "set global innodb_buffer_pool_size = $1"
}

mysql_stop() {
	say "Stopping mysql server..."
	must service mysql stop
}

mysql_start() {
	say "Starting mysql server..."
	must service mysql start
}

# xtrabackup backups ---------------------------------------------------------

# https://www.percona.com/doc/percona-xtrabackup/8.0/xtrabackup_bin/incremental_backups.html
# https://www.percona.com/doc/percona-xtrabackup/8.0/backup_scenarios/incremental_backup.html

xbkp() {
	must xtrabackup --user=root "$@" # password is read from ~/.my.cnf
}

mysql_backup_all() { # BKP_DIR [PARENT_BKP_DIR]
	local BKP_DIR="$1"
	local PARENT_BKP_DIR="$2"
	checkvars BKP_DIR

	must mkdir -p $BKP_DIR

	xbkp --backup --target-dir=$BKP_DIR \
		--rsync --parallel=$(nproc) --compress --compress-threads=$(nproc) \
		${PARENT_BKP_DIR:+--incremental-basedir=$PARENT_BKP_DIR}

	[ "$PARENT_BKP_DIR" ] && \
		must ln -s $PARENT_BKP_DIR $BKP_DIR-parent
}

mysql_restore_all() { # BKP_DIR

	local BKP_DIR="$1"
	checkvars BKP_DIR

	# walk up the parent chain and collect dirs in reverse.
	# BKP_DIR becomes the last parent, i.e. the non-incremental backup.
	local BKP_DIRS="$BKP_DIR"
	while true; do
		local PARENT_BKP_DIR="$(readlink $BKP_DIR-parent)"
		[ "$PARENT_BKP_DIR" ] || break
		BKP_DIRS="$PARENT_BKP_DIR $DIRS"
		BKP_DIR="$PARENT_BKP_DIR"
	done

	local RESTORE_DIR=/root/mm-machine-restore/mysql

	# prepare base backup and all incrementals in order without doing rollbacks.
	cp_dir "$BKP_DIR" "$RESTORE_DIR"
	local PARENT_BKP_DIR=""
	for BKP_DIR in $BKP_DIRS; do
		xbkp --prepare --target-dir=$RESTORE_DIR --apply-log-only \
			--rsync --parallel=$(nproc) --decompress --decompress-threads=$(nproc) $O \
			${PARENT_BKP_DIR:+--incremental-dir=$BKP_DIR}
		PARENT_BKP_DIR=$BKP_DIR
	done

	# perform rollbacks.
	xbkp --prepare --target-dir=$RESTORE_DIR

	mysql_stop

	rm_dir /var/lib/mysql
	must mkdir -p /var/lib/mysql
	xbkp --move-back --target-dir=$RESTORE_DIR
	must chown -R mysql:mysql /var/lib/mysql
	rm_dir $RESTORE_DIR

	mysql_start

}

# mysqldump backups ----------------------------------------------------------

mysql_backup_db() { # DB BKP_DIR
	local DB="$1"
	local BKP_DIR="$2"
	checkvars DB BKP_DIR
	must mkdir -p "$BKP_DIR"
	must mysqldump -u root \
		--add-drop-database \
		--extended-insert \
		--order-by-primary \
		--routines \
		--single-transaction \
		--quick \
		"$DB" > "$BKP_DIR/mysqldump.sql"
}

mysql_restore_db() { # DB BKP_DIR
	echo NYI
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
