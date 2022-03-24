#use die

ssh_hostkey_update() { # host fingerprint
	say "Updating SSH host fingerprint for host '$1' (/etc/ssh)..."
	local kh=/etc/ssh/ssh_known_hosts
	run ssh-keygen -R "$1" -f $kh # remove host line if found
	must printf "%s\n" "$2" >> $kh
	must chmod 644 $kh
}

ssh_host_update() { # host keyname [unstable_ip]
	say "Assigning SSH key '$2' to host '$1' $HOME $3..."
	must mkdir -p $HOME/.ssh
	local CONFIG=$HOME/.ssh/config
	touch "$CONFIG"
	local s="$(sed 's/^Host/\n&/' $CONFIG | sed '/^Host '"$1"'$/,/^$/d;/^$/d')"
	(
		echo "$s"
		printf "%s\n" "Host $1"
		printf "\t%s\n" "HostName $1"
		printf "\t%s\n" "IdentityFile $HOME/.ssh/${2}.id_rsa"
		[ "$3" ] && printf "\t%s\n" "CheckHostIP no"
	) > $CONFIG
	must chown $USER:$USER -R $HOME/.ssh
}

ssh_key_update() { # keyname key
	say "Updating SSH key '$1' ($HOME)..."
	must mkdir -p $HOME/.ssh
	local idf=$HOME/.ssh/${1}.id_rsa
	must printf "%s" "$2" > $idf
	must chmod 600 $idf
	must chown $USER:$USER -R $HOME/.ssh
}

ssh_host_key_update() { # host keyname key [unstable_ip]
	ssh_key_update "$2" "$3"
	ssh_host_update "$1" "$2" "$4"
}

ssh_update_pubkey() { # keyname key
	say "Updating SSH public key '$1'..."
	local ak=$HOME/.ssh/authorized_keys
	must mkdir -p $HOME/.ssh
	[ -f $ak ] && must sed -i "/ $1/d" $ak
	must printf "%s\n" "$2" >> $ak
	must chmod 600 $ak
	must chown $USER:$USER -R $HOME/.ssh
}

ssh_pubkey() { # keyname
	cat $HOME/.ssh/authorized_keys | grep " $1\$"
}

ssh_git_keys_update_for_user() { # user
	local USER="$1"
	check_vars USER GIT_HOSTS
	for NAME in $GIT_HOSTS; do

		local HOST=${NAME^^}_HOST
		local FINGERPRINT=${NAME^^}_FINGERPRINT
		local KEY=${NAME^^}_KEY

		HOST="${!HOST}"
		FINGERPRINT="${!FINGERPRINT}"
		KEY="${!KEY}"

		HOME=/home/$USER USER=$USER ssh_host_key_update \
			$HOST mm_$NAME "$KEY" unstable_ip
	done
}

ssh_git_keys_update() {
	check_vars GIT_HOSTS

	for NAME in $GIT_HOSTS; do

		local HOST=${NAME^^}_HOST
		local FINGERPRINT=${NAME^^}_FINGERPRINT
		local KEY=${NAME^^}_KEY

		HOST="${!HOST}"
		FINGERPRINT="${!FINGERPRINT}"
		KEY="${!KEY}"

		ssh_hostkey_update  $HOST "$FINGERPRINT"
		ssh_host_key_update $HOST mm_$NAME "$KEY" unstable_ip

		(
		shopt -s nullglob
		for USER in *; do
			[ -d /home/$USER/.ssh ] && \
				HOME=/home/$USER USER=$USER ssh_host_key_update \
					$HOST mm_$NAME "$KEY" unstable_ip
		done
		exit 0 # for some reason, for sets an exit code...
		) || exit

	done
}
