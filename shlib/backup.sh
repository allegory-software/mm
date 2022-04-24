#use mysql fs

bkp_dir() { # machine|deploy [BKP] [files|mysql]
	[ "$1" ] || die
	[ "$2" ] || return
	echo -n /root/mm-$1-backups/$2
	[ "$3" ] && echo -n /$3
}

# print dir size in bytes excluding files that have more than one hard-link.
dir_lean_size() { # DIR
	local s="$(find "$1" -type f -links 1 -printf "%s\n" | awk '{s=s+$1} END {print s}')"
	[ "$s" ] || s=0
	echo "$s"
}

_hardlink() {
	say -n "Hardlinking $1 to $2 ... "
	[ -d "$2" ] && rm_dir "$2"

	must cp -al "$1" "$2"

	say "OK. $(dir_lean_size "$2" | numfmt --to=iec) written."
}

deploy_backup_files() { # DEPLOY BACKUP_DIR
	local deploy="$1"
	local dir="$2"
	checkvars deploy dir

	_hardlink /home/$deploy $dir
}

deploy_restore_files() { # DEPLOY BACKUP_DIR
	local deploy="$1"
	local dir="$2"
	checkvars deploy dir

	_hardlink $dir /home/$deploy
}

machine_backup_files() { # BACKUP_DIR [PARENT_BACKUP_DIR]
	local dir="$1"
	local parent_dir="$2"
	checkvars dir

	must rsync -aR ${parent_dir:+--link-dest=$parent_dir} /home $dir

	[ "$parent_dir" ] && must ln -s $parent_dir $dir-parent
}

machine_restore_files() { # BKP_DIR
	local dir="$1"
	checkvars dir

	local parent_dir="$(readlink $dir-parent)"

	ls -1 $dir | while read $DEPLOY; do
		user_create $DEPLOY
	done

	must rsync --delete -aR ${parent_dir:+--link-dest=$parent_dir} $dir /home
}

backup_info() { # TYPE BKP
	local dir=$(bkp_dir $1 $2)

	# print dir lean size
	dir_lean_size "$dir"

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

	mysql_backup_all     $(bkp_dir machine $mbkp mysql) $(bkp_dir machine "$parent_mbkp" mysql)
	machine_backup_files $(bkp_dir machine $mbkp files) $(bkp_dir machine "$parent_mbkp" files)

	backup_info machine $mbkp
}

machine_restore() { # mbkp
	local mbkp="$1"
	checkvars mbkp

	deploy_stop_all

	mysql_restore_all     $(bkp_dir machine $mbkp mysql)
	machine_restore_files $(bkp_dir machine $mbkp files)

	deploy_start_all
}

deploy_backup() { # DEPLOY DBKP
	local deploy="$1"
	local dbkp="$2"
	checkvars deploy dbkp

	mysql_backup_db     $deploy $(bkp_dir deploy $dbkp mysql)
	deploy_backup_files $deploy $(bkp_dir deploy $dbkp files)

	backup_info deploy $dbkp
}

deploy_backup_remove() { # DBKP
	local dbkp="$1"
	checkvars dbkp

	rm_dir $(bkp_dir deploy $dbkp)
}

deploy_restore() { # DBKP DEPLOY
	local dbkp="$1"
	local deploy="$2"
	checkvars dbkp deploy

	deploy_remove $deploy
	deploy_setup  $deploy

	mysql_restore_db     $deploy $(bkp_dir deploy $dbkp mysql)
	deploy_restore_files $deploy $(bkp_dir deploy $dbkp files)

}
