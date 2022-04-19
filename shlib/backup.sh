#use mysql fs

bkp_dir() { # machine|deploy [BKP] [files|mysql]
	[ "$1" ] || die
	[ "$2" ] || return
	echo -n /root/mm-$1-backups/$2
	[ "$3" ] && echo -n /$3
}

deploy_backup_files() {
	echo NYI
}

deploy_restore_files() {
	echo NYI
}

machine_backup_files() { # BKP_DIR [PARENT_BKP_DIR]
	local BKP_DIR="$1"
	local PARENT_BKP_DIR="$2"
	checkvars BKP_DIR

	must rsync -aR ${PARENT_BKP_DIR:+ --link-dest=$PARENT_BKP_DIR} /home $BKP_DIR

	[ "$PARENT_BKP_DIR" ] && \
		must ln -s $PARENT_BKP_DIR $BKP_DIR-parent
}

machine_restore_files() { # BKP_DIR
	local BKP_DIR="$1"
	checkvars BKP_DIR

	local PARENT_BKP_DIR="$(readlink $BKP_DIR-parent)"

	ls -1 $BKP_DIR | while read $DEPLOY; do
		user_create $DEPLOY
	done

	must rsync --delete -aR ${PARENT_BKP_DIR:+ --link-dest=$PARENT_BKP_DIR} $BKP_DIR /home
}

backup_info() { # TYPE BKP
	local DIR="$(bkp_dir $1 $2)"
	du -bs "$DIR" | cut -f1  # print dir size in bytes
	sha_dir "$DIR"           # print dir sha checksum
}

machine_backup_remove() {
	local BKP="$1"
	checkvars BKP
	rm_dir "$(bkp_dir machine $MBKP)"
}

machine_backup() { # BKP [PARENT_BKP]
	local BKP="$1"
	local PARENT_BKP="$2"
	checkvars BKP

	mysql_backup_all     "$(bkp_dir machine $BKP mysql)" "$(bkp_dir machine "$PARENT_BKP" mysql)"
	machine_backup_files "$(bkp_dir machine $BKP files)" "$(bkp_dir machine "$PARENT_BKP" files)"

	backup_info machine $BKP
}

machine_restore() { # BKP
	local BKP="$1"
	checkvars BKP

	deploy_stop_all

	mysql_restore_all     "$(bkp_dir machine $BKP mysql)"
	machine_restore_files "$(bkp_dir machine $BKP files)"

	deploy_start_all
}

deploy_backup() { # DEPLOY BKP
	local DEPLOY="$1"
	local BKP="$2"
	checkvars DEPLOY BKP

	mysql_backup_db     "$DEPLOY" "$(bkp_dir deploy $BKP mysql)"
	deploy_backup_files "$DEPLOY" "$(bkp_dir deploy $BKP files)"

	backup_info deploy $BKP
}

deploy_restore() { # DEPLOY BKP
	local BKP="$1"
	checkvars BKP
	mysql_restore_db     "$DEPLOY" "$(bkp_dir deploy $BKP mysql)"
	deploy_restore_files "$DEPLOY" "$(bkp_dir deploy $BKP files)"
}

