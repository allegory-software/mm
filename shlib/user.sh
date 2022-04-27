#use die fs

user_exists() { # USER
	local user="$1"
	checkvars user
	id -u $user &>/dev/null
}

user_create() { # USER
	local user="$1"
	checkvars user
	say -n "Creating user $user ... "
	user_exists $user || must useradd -m $user
	must chsh -s /bin/bash $user
	must chmod 750 /home/$user
	say OK
}

user_lock_pass() { # USER
	local user="$1"
	checkvars user
	say -n "Locking password for user $user ... "
	must passwd -l $user >/dev/null
	say OK
}

user_check_can_remove() {
	ps -u "$1" &>/dev/null && die "User $1 still has running processes."
}

user_remove() { # USER
	local user="$1"
	checkvars user
	user_check_can_remove $user

	say -n "Removing user $user ... "
	user_exists $user && must userdel $user
	say OK

	rm_dir /home/$user
}

user_rename() { # OLD_USER NEW_USER
	local old_user=$1
	local new_user=$2
	checkvars old_user new_user
	say -n "Renaming user $old_user to $new_user ... "
	user_exists $old_user || die "User not found: $old_user"
	user_exists $new_user && die "User already exists: $new_user"
	user_check_can_remove $old_user

	must usermod -l "$new_user" "$old_user"
	must usermod -d /home/$new_user -m $new_user
	must groupmod -n $new_user $old_user

	say OK
}
