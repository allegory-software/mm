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
	save "
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

mysql_backup_db() { # DB BACKUP_DIR
	local db="$1"
	local dir="$2"
	checkvars db dir
	must mkdir -p "$dir"
	say -n "mysqldump'ing $db to $dir ... "
	must mysqldump -u root \
		--no-create-db \
		--extended-insert \
		--order-by-primary \
		--triggers \
		--routines \
		--single-transaction \
		--quick \
		"$db" | qpress -i dump.sql "$dir/dump.qp"
	say "OK. $(stat --printf="%s" "$dir/dump.qp" | numfmt --to=iec) written."
}

mysql_restore_db() { # DB BACKUP_DIR
	local db="$1"
	local dir="$2"
	checkvars db dir
	qpress -d "$dir/dump.qp" ./dir
	qpress -do database.qp > database.xml
	cat database.qp | qpress -di .
}

# mysql queries --------------------------------------------------------------

has_mysql() { which mysql >/dev/null; }

_must_mysql() {
	if [ -f $HOME/.my.cnf ]; then
		must mysql -N -B "$@"
	else
		# on a fresh mysql install we can login from the `root` system user
		# as mysql user `root` without a password because the default auth
		# plugin for `root` (without hostname!) is `unix_socket`.
		must mysql -N -B -u root "$@"
	fi
}

query_on() { # DB SQL
	_must_mysql "$1" -e "$2"
}

query() { # SQL
	_must_mysql -e "$1"
}

query_to() { # VARNAME SQL
	local -n out="$1"
	local s="$(_must_mysql -e "$2")" || die "$s"
	out="$s"
}

mysql_exec_on() { # DB SQL
	[ "$DRY" ] && { echo "DRY mysql_exec_on $1 [[$2]]"; return; }
	query_on "$@"
}

mysql_exec() { # SQL
	[ "$DRY" ] && { echo "DRY mysql_exec [[$1]]"; return; }
	query "$1"
}

mysql_my_cnf() {
	local user="$1"
	checkvars user
	local home="/home/$user"
	[ "$user" == root ] && home=/root
	echo "$home/.my.cnf"
}

mysql_pass() { # USER/DB
	local cnf=$(mysql_my_cnf "$1")
	[ -f "$cnf" ] && sed -n 's/password=\(.*\)/\1/p' $cnf
}

# update ~/.my.cnf for using mysql and mysqldump without a password.
mysql_gen_my_cnf() { # HOST USER PASS [DB]
	local host="$1"
	local user="$2"
	local pass="$3"
	local db="$4"
	checkvars host user pass
	local cnf=$(mysql_my_cnf $user)
	checkvars cnf
	save "\
[client]
host=$host
user=$user
password=$pass
${db:+database=$db}
" $cnf $user
}

_mysql_create_or_alter_user() { # create|alter HOST USER PASS
	local create="$1"
	local host="$2"
	local user="$3"
	local pass="$4"
	checkvars create host user pass
	mysql_exec "
		$create user '$user'@'$host' identified with mysql_native_password by '$pass';
		flush privileges;
	"
}

mysql_create_user() { # HOST USER PASS
	say -n "Creating MySQL user $2@$1 ... "
	_mysql_create_or_alter_user create "$@"
	say OK
}

mysql_update_pass() { # HOST USER PASS
	say -n "Updating password for MySQL user $2@$1 ... "
	_mysql_create_or_alter_user alter "$@"
	say OK
}

mysql_drop_user() { # HOST USER
	local host="$1"
	local user="$2"
	checkvars host user
	say -n "Dropping MySQL user $user@$host ... "
	mysql_exec "drop user if exists '$user'@'$host'; flush privileges;"
	say OK
}

mysql_create_db() { # DB
	local db="$1"
	checkvars db
	say -n "Creating MySQL database $db ... "
	mysql_exec "
		create database \`$db\`
			character set utf8mb4
			collate utf8mb4_unicode_ci;
	"
	say OK
}

mysql_drop_db() { # DB
	local db="$1"
	checkvars db
	say -n "Dropping MySQL database $db ... "
	mysql_exec "drop database if exists \`$db\`"
	say OK
}

mysql_grant_user_db() { # HOST USER DB
	local host="$1"
	local user="$2"
	local db="$3"
	checkvars host user db
	say -n "Granting all rights on MySQL database $db to user $user ... "
	mysql_exec "
		grant all privileges on \`$db\`.* to '$user'@'$host';
		flush privileges;
	"
	say OK
}

mysql_rename_user() { # OLD_HOST OLD_USER NEW_HOST NEW_USER
	local old_host="$1"
	local old_user="$2"
	local new_host="$3"
	local new_user="$4"
	checkvars old_host old_user new_host new_user
	say -n "Renaming MySQL user $old_user to $new_user ... "
	mysql_exec "
		rename user '$old_user'@'$old_host' to '$new_user'@'$new_host';
		flush privileges;
	"
	say OK
}

mysql_dbs() {
	query "show databases where \`database\` not in
		('mysql', 'information_schema', 'performance_schema', 'sys')"
}

mysql_tables() { # DB
	local db="$1"
	checkvars db
	query "
		select table_name from information_schema.tables
		where table_schema = '$db' and table_type = 'BASE TABLE'
		order by table_name
	"
}

mysql_dump_views() { # DB
	local db="$1"
	checkvars db
	local table
	local ignore="$(
		mysql_tables $db | while read -r table; do
			echo -n " --ignore-table=$db.$table"
		done
	)"
	must mysqldump --no-data --no-create-db --skip-opt $ignore $db
}

mysql_dump_triggers_procs_funcs() {
	local db="$1"
	checkvars db
	must mysqldump --triggers --routines \
		--no-create-info --no-data --no-create-db --skip-opt $db
}

mysql_move_tables() { # DB NEW_DB
	local db="$1"
	local new_db="$2"
	checkvars db new_db
	say -n "Moving all tables from $db to $new_db ... "
	local sql; query_to sql "
		select concat('RENAME TABLE \`', table_name, '\` TO \`$new_db\`.\`', table_name, '\`;') s
		from information_schema.tables
		where table_schema = '$db' and table_type = 'BASE TABLE'
		order by table_name
	"; mysql_exec_on $db "$sql"
	say OK
}

mysql_drop_views() { # DB
	local db="$1"
	checkvars db
	say -n "Dropping all views from $db ... "
	local sql; query_to sql "
		select concat('DROP VIEW \`', table_name, '\`;') s
		from information_schema.views
		where table_schema = '$db'
		order by table_name
	"; mysql_exec_on $db "$sql"
	say OK
}

mysql_drop_triggers() { # DB
	local db="$1"
	checkvars db
	say -n "Dropping all triggers from $db ... "
	local sql; query_to sql "
		select concat ('DROP TRIGGER \`', trigger_name, '\`;')
		from information_schema.triggers
		where trigger_schema = '$db';
	"; mysql_exec_on $db "$sql"
	say OK
}

mysql_drop_procs_funcs() { # DB
	local db="$1"
	checkvars db
	say -n "Dropping all procs & funcs from $db ... "
	local sql; query_to sql "
		select concat('DROP ', routine_type, ' \`', routine_name, '\`;') s
		from information_schema.routines
		where routine_schema = '$db'
	"; mysql_exec_on $db "$sql"
	say OK
}

# MySQL is missing a `RENAME DATABASE` command, so we have to do with
# its `RENAME TABLE` which can move tables between schemas along with
# their checks, indexes and foreign keys, but views, triggers, functions
# and procs we have to move (i.e. drop and recreate) ourselves.
#
# This function assumes there's a SQL user with the same name as the database
# that must also be renamed and granted access to the renamed database.
# Triggers and procs are created under that user in order to set their DEFINER.
#
mysql_rename_db() { # OLD_DB NEW_DB
	local db0="$1"
	local db1="$2"
	checkvars db0 db1

	mysql_create_db $db1

	local vtpf_sql="
		$(mysql_dump_views $db0)
		$(mysql_dump_triggers_procs_funcs $db0)
	" || die "$sql"

	mysql_drop_views       $db0
	mysql_drop_triggers    $db0
	mysql_drop_procs_funcs $db0

	mysql_move_tables $db0 $db1

	mysql_rename_user   localhost $db0 localhost $db1
	mysql_grant_user_db localhost $db1 $db1

	# rename user in DEFINER clauses.
	vtpf_sql="$(echo "$vtpf_sql" | sed "s/\`$db0\`@\`localhost\`/\`$db1\`@\`localhost\`/g")"

	say -n "Adding all views, triggers, procs & funcs from $db0 to $db1 ... "
	mysql_exec_on $db1 "$vtpf_sql"
	say OK

	mysql_drop_db $db0
}
