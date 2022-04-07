#use die

git_install_git_up() {
	say "Installing 'git up' command..."
	local git_up=/usr/lib/git-core/git-up
	local s='
msg="$1"; [ "$msg" ] || msg="unimportant"
git add -A .
git commit -m "$msg"
git push
'
	must save "$s" $git_up
	must chmod +x $git_up
}

git_config_user() { # email name
	must git config --global user.email "$1"
	must git config --global user.name "$2"
}

git_clone_for() { # user repo dir version label
	local USER="$1"
	local REPO="$2"
	local DIR="$3"
	local VERSION="$4"
	local LABEL="$5"
	checkvars USER REPO DIR
	[ "$VERSION" ] || VERSION=master
	say "Pulling $DIR $VERSION..."
	(
	must mkdir -p $DIR
	must cd $DIR
	[ -d .git ] || must git init -q
	run  git remote remove origin
	must git remote add origin $REPO
	must git -c advice.objectNameWarning=false fetch --depth=1 -q origin "$VERSION:refs/remotes/origin/$VERSION"
	must git -c advice.detachedHead=false checkout -q -B "$VERSION" "origin/$VERSION"
	[ "$LABEL" ] && echo "${LABEL}_commit=$(git rev-parse --short HEAD)"
	exit 0
	) || exit
	must chown -R $USER:$USER $DIR
}

mgit_install() {
	git_clone_for root git@github.com:capr/multigit.git /opt/mgit
	must ln -sf /opt/mgit/mgit /usr/local/bin/mgit
}
