#use die

rm_subdir() {
	[ "${1:0:1}" == "/" ] || { say "base dir not absolute"; return 1; }
	[ "$2" ] || { say "subdir required"; return 1; }
	local dir="$1/$2"
	say "Removing dir '$dir'..."
	must rm -rf "$dir"
}
