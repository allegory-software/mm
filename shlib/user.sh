#use die fs

user_create() { # user
	local user="$1"
	checkvars user
	say "Creating user $user ..."
	id -u 1>&2 2>/dev/null $user || must useradd -m $user
	must chsh -s /bin/bash $user
	must chmod 750 /home/$user
}

user_lock_pass() { # user
	local user="$1"
	checkvars user
	say "Locking password for user $user '..."
	must passwd -l $user >&2
}

user_exists() { # user
	local user="$1"
	checkvars user
	id -u $user &>/dev/null
}

user_remove() {
	local user="$1"
	checkvars user
	say "Removing user $user ..."
	user_exists $user || { say "User not found: $user."; return 0; }
	must userdel $user
	rm_dir /home/$user
}

user_rename() {
	local old_user=$1
	local new_user=$2
	checkvars old_user new_user
	say "Renaming user $old_user to $new_user ..."
	user_exists $old_user || { say "User not found: $old_user."; return 0; }
	ps -u $old_user &>/dev/null && die "User $old_user still has running processes."
	must usermod -l "$new_user" "$old_user"
	must usermod -d /home/$new_user -m $new_user
	must groupmod -n $new_user $old_user
}
