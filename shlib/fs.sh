#use die

rm_dir() { # dir
	[ "${1:0:1}" == "/" ] || { say "path not absolute"; return 1; }
	[ "${1: -1}" == "/" ] && { say "path ends in slash"; return 1; }
	local dir="$1"
	say "Removing dir $dir ..."
	must rm -rf "$dir"
}

cp_dir() { # src_dir dst_dir
	local src_dir="$1"
	local dst_dir="$2"
	checkvars src_dir dst_dir
	[ "${src_dir:0:1}" == "/" ] || { say "src dir not absolute"; return 1; }
	say "Removing dir $dst_dir ..."
	must rm -rf "$dst_dir"
	say "Copying dir $src_dir to $dst_dir ..."
	must cp -rf "$src_dir" "$dst_dir"
}

sha_dir() { # dir
	local dir="$1"
	checkvars dir
	find "$dir" -type f -print0 | LC_ALL=C sort -z | xargs -0 sha1sum | sha1sum | cut -d' ' -f1
}
