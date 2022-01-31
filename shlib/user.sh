#use die

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
