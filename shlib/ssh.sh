#use die fs

ssh_hostkey_update() { # HOST FINGERPRINT
	local host="$1"
	local fp="$2"
	checkvars host fp-
	say "Updating SSH host fingerprint for host $host (/etc/ssh) ... (*)"
	local kh=/etc/ssh/ssh_known_hosts
	run ssh-keygen -R "$host" -f $kh # remove host line if found
	local newline=$'\n'
	append "$fp$newline" $kh
	must chmod 644 $kh
	say "(*) SSH host fingerprint updated."
}

ssh_host_update() { # host keyname [unstable_ip]
	local host="$1"
	local keyname="$2"
	checkvars host keyname
	say "Assigning SSH key '$keyname' to host '$host' $HOME $3 ... (*)"
	must mkdir -p $HOME/.ssh
	local CONFIG=$HOME/.ssh/config
	touch "$CONFIG"
	local s="$(sed 's/^Host/\n&/' $CONFIG | sed '/^Host '"$1"'$/,/^$/d;/^$/d')"
	s="$s
Host $1
  HostName $1
  IdentityFile $HOME/.ssh/${2}.id_rsa"
	[ "$3" ] && s="$s
  CheckHostIP no"
	save "$s" $CONFIG
	must chown $USER:$USER -R $HOME/.ssh
	say "(*) SSH key assigned."
}

ssh_key_update() { # keyname key
	say "Updating SSH key '$1' ($HOME) ... (*)"
	must mkdir -p $HOME/.ssh
	local idf=$HOME/.ssh/${1}.id_rsa
	save "$2" $idf $USER
	must chown $USER:$USER -R $HOME/.ssh
	say "(*) SSH key updated."
}

ssh_host_key_update() { # host keyname key [unstable_ip]
	ssh_key_update "$2" "$3"
	ssh_host_update "$1" "$2" "$4"
}

ssh_update_pubkey() { # keyname key
	say "Updating SSH public key '$1' ... (*)"
	local ak=$HOME/.ssh/authorized_keys
	must mkdir -p $HOME/.ssh
	[ -f $ak ] && must sed -i "/ $1/d" $ak
	local newline=$'\n'
	must append "$2$newline" $ak
	must chmod 600 $ak
	must chown $USER:$USER -R $HOME/.ssh
	say "(*) SSH public key updated."
}

ssh_pubkey() { # keyname
	cat $HOME/.ssh/authorized_keys | grep " $1\$"
}

ssh_git_keys_update_for_user() { # USER
	local USER="$1"
	checkvars USER GIT_HOSTS-
	for NAME in $GIT_HOSTS; do
		local -n HOST=${NAME^^}_HOST
		local -n SSH_KEY=${NAME^^}_SSH_KEY
		checkvars HOST SSH_KEY-

		HOME=/home/$USER USER=$USER ssh_host_key_update \
			$HOST mm_$NAME "$SSH_KEY" unstable_ip
	done
}

ssh_git_keys_update() {
	checkvars GIT_HOSTS-
	for NAME in $GIT_HOSTS; do
		local -n HOST=${NAME^^}_HOST
		local -n SSH_HOSTKEY=${NAME^^}_SSH_HOSTKEY
		local -n SSH_KEY=${NAME^^}_SSH_KEY
		checkvars HOST SSH_HOSTKEY- SSH_KEY-

		ssh_hostkey_update  $HOST "$SSH_HOSTKEY"
		ssh_host_key_update $HOST mm_$NAME "$SSH_KEY" unstable_ip

		(
		shopt -s nullglob
		for USER in *; do
			[ -d /home/$USER/.ssh ] && \
				HOME=/home/$USER USER=$USER ssh_host_key_update \
					$HOST mm_$NAME "$SSH_KEY" unstable_ip
		done
		exit 0 # for some reason, for sets an exit code...
		) || exit
	done
}

rsync_to() { # HOST DIR|FILE [LINK_DIR]
	local host="$1"
	local dir="$2"
	local link_dir="$3"
	checkvars host dir
	[ "$link_dir" ] && {
		link_dir="$(realpath "$link_dir")" # --link-dest path must be absolute.
		checkvars link_dir
	}
	checkvars SSH_KEY- SSH_HOSTKEY-

	say -n "Copying dir $dir to host $host ${link_dir:+link_dir $link_dir }... "
	local p=/root/.scp_clone_dir.p.$$
	local h=/root/.scp_clone_dir.h.$$
	trap 'rm -f $p $h' EXIT
	printf "%s" "$SSH_KEY"     > $p || die "saving $p failed. [$?]"
	printf "%s" "$SSH_HOSTKEY" > $h || die "saving $h failed. [$?]"
	must chmod 600       $p $h
	must chown root:root $p $h
	SSH_KEY=
	SSH_HOSTKEY=

	# NOTE: the dot syntax cuts out the path before it as a way to make the path relative.
	[ "$DRY" ] || must rsync --delete --timeout=5 ${link_dir:+--link-dest=$link_dir} \
		-e "ssh -o UserKnownHostsFile=$h -i $p" \
		-aR "$dir/./." "root@$host:/$dir"

	rm -f $p $h
	say "OK"
}
