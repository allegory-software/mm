#use mysql fs

bkp_dir() { # machine|deploy [BKP] [files|mysql]
	[ "$1" ] || die
	[ "$2" ] || return
	echo -n /root/mm-$1-backups/$2
	[ "$3" ] && echo -n /$3
}

deploy_backup_files() { # DIR
	echo NYI
}

deploy_restore_files() { # DIR
	echo NYI
}

machine_backup_files() { # BKP_DIR [PARENT_BKP_DIR]
	local dir="$1"
	local parent_dir="$2"
	checkvars dir

	must rsync -aR ${parent_dir:+ --link-dest=$parent_dir} /home $dir

	[ "$parent_dir" ] && must ln -s $parent_dir $dir-parent
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
	local dir="$(bkp_dir $1 $2)"

	# print dir size in bytes excluding files that have more than one hard-link.
	find "$dir" -type f -links 1 -printf "%s\n" | awk '{s=s+$1} END {print s}'

	# print dir sha checksum
	sha_dir "$dir"
}

machine_backup_remove() {
	local mbkp="$1"
	checkvars mbkp
	rm_dir "$(bkp_dir machine $mbkp)"
}

machine_backup() { # MBKP [PARENT_MBKP]
	local mbkp="$1"
	local parent_mbkp="$2"
	checkvars mbkp

	mysql_backup_all     "$(bkp_dir machine $mbkp mysql)" "$(bkp_dir machine "$parent_mbkp" mysql)"
	machine_backup_files "$(bkp_dir machine $mbkp files)" "$(bkp_dir machine "$parent_mbkp" files)"

	backup_info machine $mbkp
}

machine_restore() { # mbkp
	local mbkp="$1"
	checkvars mbkp

	deploy_stop_all

	mysql_restore_all     "$(bkp_dir machine $mbkp mysql)"
	machine_restore_files "$(bkp_dir machine $mbkp files)"

	deploy_start_all
}

deploy_backup() { # DEPLOY DBKP
	local deploy="$1"
	local dbkp="$2"
	checkvars deploy dbkp

	mysql_backup_db     "$deploy" "$(bkp_dir deploy $dbkp mysql)"
	deploy_backup_files "$deploy" "$(bkp_dir deploy $dbkp files)"

	backup_info deploy $dbkp
}

deploy_backup_remove() { # DBKP
	local dbkp="$1"
	checkvars dbkp
	rm_dir "$(bkp_dir deploy $dbkp)"
}

deploy_restore() { # DBKP DEPLOY
	local dbkp="$1"
	local deploy="$2"
	checkvars dbkp deploy
	mysql_restore_db     "$deploy" "$(bkp_dir deploy $dbkp mysql)"
	deploy_restore_files "$deploy" "$(bkp_dir deploy $dbkp files)"
}
