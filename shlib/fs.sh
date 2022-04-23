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

cp_dir() { # SRC_DIR DST_DIR
	local src_dir="$1"
	local dst_dir="$2"
	checkvars src_dir dst_dir
	check_abs_filepath "$src_dir"
	check_abs_filepath "$dst_dir"
	[ -d "$dst_dir" ] && rm_dir "$dst_dir"
	say -n "Copying dir $src_dir to $dst_dir ... "
	[ "$DRY" ] || must cp -rf "$src_dir" "$dst_dir"
	say OK
}

sha_dir() { # DIR
	local dir="$1"
	checkvars dir
	find "$dir" -type f -print0 | LC_ALL=C sort -z | xargs -0 sha1sum | sha1sum | cut -d' ' -f1
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
