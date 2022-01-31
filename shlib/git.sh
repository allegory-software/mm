#use die

git_install_git_up() {
	say "Installing 'git up' command..."
	local git_up=/usr/lib/git-core/git-up
	cat << 'EOF' > $git_up
msg="$1"; [ "$msg" ] || msg="unimportant"
git add -A .
git commit -m "$msg"
git push
EOF
	must chmod +x $git_up
}

git_config_user() { # email name
	run git config --global user.email "$1"
	run git config --global user.name "$2"
}

mgit_install() {
	must mkdir -p /opt
	must cd /opt
	if [ -d mgit ]; then
		cd mgit && git pull
	else
		must git clone git@github.com:capr/multigit.git mgit
	fi
	must ln -sf /opt/mgit/mgit /usr/local/bin/mgit
}

