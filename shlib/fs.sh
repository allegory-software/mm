#use die

check_abs_filepath() {
	[ "${1:0:1}" == "/" ] || die "path not absolute: $1"
	[ "${1: -1}" == "/" ] && die "path ends in slash: $1"
}

rm_dir() { # DIR
	local dir="$1"
	checkvars dir
	check_abs_filepath "$dir"
	say -n "Removing dir $dir ... "
	[ "$DRY" ] || must rm -rf "$dir"
	say OK
}

sha_dir() { # DIR
	local dir="$1"
	checkvars dir
	[ -d $dir ] || die "dir not found: $dir"
	(
	set -o pipefail
	find $dir -type f -print0 | LC_ALL=C sort -z | xargs -0 sha1sum | sha1sum | cut -d' ' -f1
	) || exit $?
}

append() { # S FILE
	local s="$1"
	local file="$2"
	checkvars s- file
	say -n "Appending ${#s} bytes to file $file ... "
	debug -n "MUST: append \"$s\" $file "
	if [ "$DRY" ] || printf "%s" "$s" >> "$file"; then
		debug "[$?]"
	else
		die "append $file [$?]"
	fi
	say OK
}

save() { # S FILE [USER]
	local s="$1"
	local file="$2"
	local user="$3"
	checkvars s- file
	say -n "Saving ${#s} bytes to file $file ... "
	debug -n "MUST: save \"$s\" $file "
	if [ "$DRY" ] || printf "%s" "$s" > "$file"; then
		debug "[$?]"
	else
		die "save $file [$?]"
	fi
	if [ "$user" ]; then
		checkvars user
		must chown $user:$user $file
		must chmod 600 $file
	fi
	say OK
}

# TODO: finish this
: '
replace_lines() { # REGEX FILE
	local regex="$1"
	local file="$2"
	checkvars regex- file
	say -n "Removing line containing $regex from file $file ..."
	local s="$(cat "$file")" || die "cat $file [$?]"
	local s1="${s//$regex/}"
	if [ "$s" == "$s1" ]; then
		say "No match"
	else
		say "Match found"
		save "$s" "$file"
		say "OK"
	fi
}
'

sync_dir() { # SRC_DIR= DST_DIR= [LINK_DIR=]
	checkvars SRC_DIR DST_DIR
	[ "$LINK_DIR" ] && {
		LINK_DIR="$(realpath "$LINK_DIR")" # --link-dest path must be absolute.
		checkvars LINK_DIR
	}

	say -n "Sync'ing dir
  src: $src_dir
  dst: $dst_dir "
	[ "$LINK_DIR" ] && say -n "
  lnk: $LINK_DIR "
	say -n "
  ... "

	# NOTE: the dot syntax cuts out the path before it as a way to make the path relative.
	[ "$DRY" ] || must rsync --delete -aHR ${LINK_DIR:+--link-dest=$LINK_DIR} $src_dir/./. $dst_dir

	say "OK. $(dir_lean_size $dst_dir | numfmt --to=iec) bytes in destination."
}

# HOST= SRC_DIR= [DST_DIR=] [LINK_DIR=] [SRC_MACHINE=] [DST_MACHINE=] [PROGRESS=1] sync_dir
rsync_dir() {
	[ "$DST_DIR" ] || DST_DIR="$SRC_DIR"
	checkvars HOST SRC_DIR DST_DIR
	[ "$LINK_DIR" ] && {
		LINK_DIR="$(realpath "$LINK_DIR")" # --link-dest path must be absolute!
		checkvars LINK_DIR
	}
	checkvars SSH_KEY- SSH_HOSTKEY-

	[ "$DST_MACHINE" ] || DST_MACHINE=$HOST

	say -n "Sync'ing dir
  src: $SRC_MACHINE:$SRC_DIR
  dst: $DST_MACHINE:$DST_DIR "
	[ "$LINK_DIR" ] && say -n "
  lnk: $LINK_DIR "
	say -n "
  ... "
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
	[ "$DRY" ] || must rsync --delete --timeout=5 \
		${PROGRESS:+--info=progress2} \
		${LINK_DIR:+--link-dest=$LINK_DIR} \
		-e "ssh -o UserKnownHostsFile=$h -i $p" \
		-aHR "$SRC_DIR/./." "root@$HOST:/$DST_DIR"

	rm -f $p $h
	say "OK"
}
