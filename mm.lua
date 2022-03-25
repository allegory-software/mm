--go@ x:\sdk\bin\windows\luajit mm.lua -v run
--go@ plink d10 -t -batch sdk/bin/linux/luajit mm/mm.lua -v
--[[

	Many Machines, the independent man's SAAS provisioning tool.
	Written by Cosmin Apreutesei. Public Domain.

	Many Machines is a bare-bones provisioning and administration tool
	for web apps deployed on dedicated machines or VPS, as opposed to cloud
	services as it's customary these days (unless you count VPS as cloud).

FEATURES
	- Lua API, web UI & cmdline for everything.
	- Windows-native sysadmin tools (sshfs, putty, etc.).
	- agentless.
	- keeps a database of machines and deployments.
	- maintain secure access to all services via bulk key updates:
		- ssh root access.
		- MySQL root access.
		- github & azure devops access.
	- "one-click" launcher for secure admin sessions:
		- bash (cmd & putty).
		- mysql (cmd & putty).
		- remote fs mounts (Windows & Linux).
		- ssh tunnels.
	- machine "prepare" script (one-time install script for a new machine).
	- task system with process tracking and output capturing.
	- deploy script.
	- remote logging server.
	- MySQL backups: full, incremental, per-db, per-table, hot-restore.
	- file replication: full, incremental (hardlink-based).

LIMITATIONS
	- the machines need to run Linux (Debian 10) and have a public IP.
	- all deployments connect to the same MySQL server instance.
	- each deployment is given a single MySQL db.
	- git hosts are hardcoded (github & azure-devops currently supported).
	- single ssh key for git access.

	TODO: make mm portable by using file rowsets instead of mysql.
	TODO: make mm even more portable by saving the var dir to git-hosted encrypted zip files.

	TODO: one-command-multiple-machines/deployments: both web and cmdline.
	TODO: bind libssh2 or see what is needed to implement ssh2 protocol in Lua.

]]

local function mm_schema()

	tables.provider = {
		provider    , strpk,
		website     , url,
		note        , text,
		pos         , pos,
		ctime       , ctime,
	}

	tables.machine = {
		machine     , strpk,
		provider    , strid, not_null, fk,
		location    , strid, not_null,
		public_ip   , strid,
		local_ip    , strid,
		fingerprint , b64key,
		ssh_key_ok  , bool,
		admin_page  , url,
		last_seen   , datetime_s,
		os_ver      , name,
		mysql_ver   , name,
		cpu         , name,
		cores       , uint16,
		ram_gb      , double,
		ram_free_gb , double,
		hdd_gb      , double,
		hdd_free_gb , double,
		pos         , pos,
		ctime       , ctime,
	}

	tables.deploy = {
		deploy           , strpk,
		machine          , strid, not_null, fk,
		repo             , url, not_null,
		app              , strid, not_null,
		wanted_version       , strid,
		wanted_sdk_version   , strid,
		deployed_version     , strid,
		deployed_sdk_version , strid,
		env              , strid, not_null,
		secret           , b64key, not_null, --multi-purpose
		mysql_pass       , hash, not_null,
		ctime            , ctime,
		mtime            , mtime,
		pos              , pos,
	}

	tables.deploy_vars = {
		deploy           , strid, not_null,
		name             , strid, not_null, pk,
		val              , text, not_null,
	}

	tables.deploy_log = {
		deploy   , strid, not_null, child_fk,
		ctime    , ctime, pk,
		severity , strid,
		module   , strid,
		event    , strid,
		message  , text,
	}

	tables.bkp = {
		bkp         , idpk,
		parent_bkp  , id, child_fk(bkp),
		deploy      , strid, not_null, child_fk,
		start_time  , datetime_s,
		duration    , uint,
		size        , uint52,
		checksum    , hash,
		name        , name,
	}

	tables.task = {
		task          , url, pk,
		--running
		action        , name, not_null,
		args          , url, --as Lua serialized array
		--schedule
		start_at      , timeofday, --null means start right away.
		run_every     , uint, --in seconds; null means de-arm after start.
		armed         , bool1,
		--editing
		generated_by  , name,
		editable      , bool1,
		--log
		last_run      , datetime,
		last_duration , double, --in seconds
		last_status   , strid,
	}

	--[=[

	query[[
	$table repl (
		repl        $pk,
		deploy      $str,
		master      $strid not_null, $fk(repl, master, machine),
		path        $url not_null
	);
	]]

	query[[
	$table repl_copy (
		repl        $id not_null, $child_fk(repl_copy, repl),
		machine     $strid not_null, $child_fk(repl, machine),
		last_sync   timestamp,
		primary key (repl, machine),
	);
	]]

	]=]

end

local xapp = require'$xapp'

config('https_addr', false)
config('multilang', false)
config('allow_create_user', false)
config('auto_create_user', false)

local mm = xapp('mm', ...)

local b64 = require'base64'.encode
local mustache = require'mustache'
local queue = require'queue'

--config ---------------------------------------------------------------------

mm.sshfsdir = [[C:\PROGRA~1\SSHFS-Win\bin]] --no spaces!
mm.sshdir   = mm.bindir

mm.use_plink = false

mm.git_hosting = {
	github = {
		host = 'github.com',
		fingerprint = [[
			ssh-rsa AAAAB3NzaC1yc2EAAAABIwAAAQEAq2A7hRGmdnm9tUDbO9IDSwBK6TbQa+PXYPCPy6rbTrTtw7PHkccKrpp0yVhp5HdEIcKr6pLlVDBfOLX9QUsyCOV0wzfjIJNlGEYsdlLJizHhbn2mUjvSAHQqZETYP81eFzLQNnPHt4EVVUh7VfDESU84KezmD5QlWpXLmvU31/yMf+Se8xhHTvKSCZIFImWwoG6mbUoWf9nzpIoaSjB+weqqUUmpaaasXVal72J+UX2B+2RPW3RcT0eOzQgqlJL3RKrTJvdsjE3JEAvGq3lGHSZXy28G3skua2SmVi/w4yCE6gbODqnTWlg7+wC604ydGXA8VJiS5ap43JXiUFFAaQ==
		]],
	},
	azure = {
		host = 'ssh.dev.azure.com',
		fingerprint = [[
			ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQC7Hr1oTWqNqOlzGJOfGJ4NakVyIzf1rXYd4d7wo6jBlkLvCA4odBlL0mDUyZ0/QUfTTqeu+tm22gOsv+VrVTMk6vwRU75gY/y9ut5Mb3bR5BV58dKXyq9A9UeB5Cakehn5Zgm6x1mKoVyf+FFn26iYqXJRgzIZZcZ5V6hrE0Qg39kZm4az48o0AUbf6Sp4SLdvnuMa2sVNwHBboS7EJkm57XQPVU3/QpyNLHbWDdzwtrlS+ez30S3AdYhLKEOxAG8weOnyrtLJAUen9mTkol8oII1edf7mWWbWVf0nBmly21+nZcmCTISQBtdcyPaEno7fFQMDD26/s0lfKob4Kw8H
		]],
	},
}
for name, t in pairs(mm.git_hosting) do
	t.name = name
	t.key = load(indir(mm.vardir, _('mm_%s.key', name))):trim()
	t.fingerprint = t.host .. ' ' .. t.fingerprint:trim()
end

--logging.filter[''] = true

config('page_title_suffix', 'Many Machines')
config('sign_in_logo', '/sign-in-logo.png')
config('favicon_href', '/favicon1.ico')
config('dev_email', 'cosmin.apreutesei@gmail.com')

config('secret', '!xpAi$^!@#)fas!`5@cXiOZ{!9fdsjdkfh7zk')
config('smtp_host', 'mail.bpnpart.com')
config('smtp_user', 'admin@bpnpart.com')
config('host', 'bpnpart.com')
config('noreply_email', 'admin@bpnpart.com')

local cmd_ssh_keys    = cmdsection'SSH KEY MANAGEMENT'
local cmd_ssh         = cmdsection'SSH TERMINALS'
local cmd_ssh_tunnels = cmdsection'SSH TUNNELS'
local cmd_ssh_mounts  = cmdsection'SSH-FS MOUNTS'
local cmd_mysql       = cmdsection'MYSQL'
local cmd_machines    = cmdsection'MACHINES'
local cmd_deployments = cmdsection'DEPLOYMENTS'

--load_opensans()
mm.schema:import(mm_schema)

--database -------------------------------------------------------------------

cmd('install [forealz]', 'Install the app', function(doit)
	create_db()
	local dry = doit ~= 'forealz'
	db():sync_schema(mm.schema, {dry = dry})
	if not dry then
		create_user()
	end
	say'Install done.'
end)

--web api client -------------------------------------------------------------

local function api(action, ...)
	local uri = url{segments = {'', action, ...}}
	local ret, res = assert(getpage{
		host = config'mm_host',
		uri = uri,
		headers = {
			cookie = {
				session = config'session_cookie',
			},
		},
	})
	local ct = res.headers['content-type']
	if ct and ct.media_type == mime_types.json then
		if ret.error then
			die(ret.error)
		elseif ret.notify then
			say(ret.notify)
		end
	end
	return ret, res
end

--tools ----------------------------------------------------------------------

local function NYI(event)
	logerror('mm', event, 'NYI')
end

function sshcmd(cmd)
	return win and indir(mm.sshdir, cmd) or cmd
end

local function from_server(from_db)
	return not from_db and mm.conf.mm_host and not mm.server_running
end

function mm.known_hosts_file(from_db)
	local file = indir(mm.vardir, 'known_hosts')
	if from_server(from_db) then
		local s = api'known-hosts'
		save(file, s)
	end
	return file
end
function action.known_hosts()
	setmime'txt'
	out(load(mm.known_hosts_file(true)))
end

function mm.keyfile(machine, from_db, ext)
	machine = machine and machine:trim()
	local file = 'mm'..(machine and '-'..machine or '')..'.'..(ext or 'key')
	file = indir(mm.vardir, file)
	if from_server(from_db) then
		local s = api('keyfile', machine, ext)
		save(file, s)
	end
	return file
end
function action.keyfile(machine, ext)
	local keyfile = mm.keyfile(repl(machine, ''), true, repl(ext, ''))
	setmime'txt'
	outfile(keyfile)
end

function mm.ppkfile(machine, from_db)
	return mm.keyfile(machine, from_db, 'ppk')
end

function mm.pubkey(machine)
	--NOTE: Windows ssh-keygen puts the key name at the end, but the Linux one doesn't.
	local s = readpipe(sshcmd'ssh-keygen'..' -y -f "'..mm.keyfile(machine)..'"'):trim()
	return s:match('^[^%s]+%s+[^%s]+')..' mm'
end

--TODO: `plink -hostkey` doesn't work when the server has multiple fingerprints.
function mm.ssh_hostkey(machine)
	machine = checkarg(str_arg(machine))
	local key = first_row([[
		select fingerprint from machine where machine = ?
	]], machine)
	local key = checkfound(key):trim()
	local cmd = {sshcmd'ssh-keygen', '-E', 'sha256', '-lf', '-'}
	local opt = {stdin = key, task = 'ssh_hostkey '..machine,
		capture_stderr = false,
		action = 'ssh_hostkey', args = {'machine'}, keyed = false}
	return mm.exec(cmd, opt):stdout():trim():match'%s([^%s]+)'
end
function action.ssh_hostkey(machine)
	allow(admin())
	setmime'txt'
	out(mm.ssh_hostkey(machine))
end
cmd_ssh_keys('ssh-hostkey MACHINE', 'Show a SSH host key', function(machine)
	print(api('ssh-hostkey', machine))
end)

--run this to avoid getting the incredibly stupid "perms are too open" error from ssh.
function mm.ssh_key_fix_perms(machine)
	if not win then return end
	local s = mm.keyfile(machine, true)
	readpipe('icacls %s /c /t /Inheritance:d', s)
	readpipe('icacls %s /c /t /Grant %s:F', s, env'UserName')
	readpipe('takeown /F %s', s)
	readpipe('icacls %s /c /t /Grant:r %s:F', s, env'UserName')
	readpipe('icacls %s /c /t /Remove:g "Authenticated Users" BUILTIN\\Administrators BUILTIN Everyone System Users', s)
	readpipe('icacls %s', s)
end
cmd_ssh_keys('ssh-key-fix-perms [MACHINE]', 'Fix SSH key perms for VBOX',
	mm.ssh_key_fix_perms)

function mm.ssh_key_gen_ppk(machine)
	local key = mm.keyfile(machine)
	local ppk = mm.ppkfile(machine)
	if win then
		exec(indir(mm.bindir, 'winscp.com')..' /keygen %s /output=%s', key, ppk)
	else
		local p76 = ' --ppk-param version=2'
		--^^included putty 0.76 has this (debian's putty-tools which is 0.70 doesn't).
		exec(indir(mm.bindir, 'puttygen')..' %s -O private -o %s%s', key, ppk, p76)
	end
end
cmd_ssh_keys('ssh-key-gen-ppk MACHINE', 'Generate .ppk file for a SSH key',
	mm.ssh_key_gen_ppk)

function mm.mysql_root_pass(machine) --last line of the private key
	local s = load(mm.keyfile(machine))
		:gsub('%-+.-PRIVATE%s+KEY%-+', ''):gsub('[\r\n]', ''):trim():sub(-32)
	assert(#s == 32)
	return s
end
function action.mysql_root_pass(machine)
	allow(admin())
	setmime'txt'
	out(mm.mysql_root_pass(machine))
end
cmd_mysql('mysql-root-pass [MACHINE]', 'Show the MySQL root password', function(machine)
	print(api('mysql-root-pass', machine))
end)

local function deploy_vars(deploy)

	deploy = checkarg(str_arg(deploy), 'deploy required')

	local vars = {}
	for k,v in pairs(assertf(first_row([[
		select
			d.deploy,
			d.machine,
			d.repo,
			d.app,
			coalesce(d.wanted_version, '') version,
			coalesce(d.wanted_sdk_version, '') sdk_version,
			coalesce(d.env, 'dev') env,
			d.deploy mysql_db,
			d.deploy mysql_user,
			d.mysql_pass,
			d.secret
		from
			deploy d
		where
			deploy = ?
	]], deploy), 'invalid deploy "%s"', deploy)) do
		vars[k:upper()] = v
	end

	for _, name, val in each_row_vals([[
		select
			name, val
		from
			deploy_vars
		where
			deploy = ?
	]], deploy) do
		vars[name] = val
	end

	vars.DEPLOY_VARS = cat(keys(vars, true), ' ')

	return vars, d
end

--admin web UI ---------------------------------------------------------------

css[[
.header {
	display: flex;
	border-bottom: 1px solid var(--x-smoke);
	align-items: center;
	justify-content: space-between;
	padding: 0 .5em;
	min-height: calc(var(--x-grid-header-height) + 1px);
}

body[theme=dark] .sign-in-logo {
	filter: invert(1);
}

body[theme=dark] .header {
	background-color: #111;
}

textarea.x-editbox-input[console] {
	opacity: 1;
}

#mm_config_form.maxcols1 {
	max-width: 400px;
	grid-template-areas:
		"h1"
		"mm_pubkey"
		"ssh_key_gen_button"
		"ssh_key_updates_button"
		"h2"
		"mysql_root_pass"
	;
}

#mm_deploys_form.maxcols1 {
	grid-template-areas:
		"deploy      status               status                 machine"
		"app         app                  env                    env    "
		"wanted_version    wanted_version   wanted_sdk_version    wanted_sdk_version"
		"deployed_version  deployed_version deployed_sdk_version  deployed_sdk_version"
		"repo        repo                 repo                   repo   "
		"secret      secret               secret                 secret "
		"mysql_pass  mysql_pass           mysql_pass             mysql_pass"
		"ctime       ctime                mtime                  mtime  "
		"restart     restart              start                  stop   "
		"dep         dep                  remdep                 remdep "
	;
}

.mm-logo {
	max-width: 18px;
	display: inline;
	vertical-align: bottom;
	padding-right: 2px;
}

]]

html[[
<x-if hidden global=signed_in>
<x-split fixed_size=140>
	<div theme=dark vflex>
		<div class=header>
			<div><b><img src=/favicon1.ico class=mm-logo> MANY MACHINES</b></div>
			<x-usr-button></x-usr-button>
		</div>
		<x-listbox id=mm_actions_listbox>
			<div action=deploys>Deployments</div>
			<div action=machines>Machines</div>
			<div action=providers>Providers</div>
			<div action=config>Configuration</div>
		</x-listbox>
	</div>
	<x-vsplit fixed_side=second>
		<x-switcher nav_id=mm_actions_listbox>
			<x-grid action=providers id=mm_providers_grid rowset_name=providers></x-grid>
			<x-vsplit action=machines>
				<x-grid id=mm_machines_grid rowset_name=machines></x-grid>
			</x-vsplit>
			<x-split action=deploys fixed_size=400>
				<x-tabs>
					<x-grid label=Deployments id=mm_deploys_grid rowset_name=deploys></x-grid>
				</x-tabs>
				<x-split fixed_size=400>
					<x-tabs>
						<x-form label="Deploy" id=mm_deploys_form nav_id=mm_deploys_grid grid>
							<x-input col=deploy           ></x-input>
							<x-input col=status           ></x-input>
							<x-input col=machine          ></x-input>
							<x-input col=app              ></x-input>
							<x-input col=wanted_version       ></x-input>
							<x-input col=deployed_version     ></x-input>
							<x-input col=wanted_sdk_version   ></x-input>
							<x-input col=deployed_sdk_version ></x-input>
							<x-input col=env              ></x-input>
							<x-input col=repo             ></x-input>
							<x-input col=secret           widget.copy></x-input>
							<x-input col=mysql_pass       widget.copy></x-input>
							<x-input col=ctime            ></x-input>
							<x-input col=mtime            ></x-input>

							<x-button icon="fa fa-arrow-rotate-left" area=restart
								action_name=deploy_restart
								text="Restart"></x-button>

							<x-button icon="fa fa-play" area=start
								action_name=deploy_start
								text="Start"
								style="align-self: bootom"></x-button>

							<x-button icon="fa fa-power-off" area=stop danger
								action_name=deploy_stop
								text="Stop"></x-button>

							<x-button icon="fa fa-pizza-slice" area=dep
								action_name=deploy_deploy
								text="Deploy"></x-button>

							<x-button icon="fa fa-trash" area=remdep danger
								action_name=deploy_remove
								text="Remove App"
								confirm="Are you sure you want to remove the app?"></x-button>

						</x-form>
						<x-grid
							label="Custom Vars"
							param_nav_id=mm_deploys_grid params=deploy
							rowset_name=deploy_vars
						></x-grid>
					</x-tabs>
					<x-tabs>
						<x-grid
							label="Live Log"
							id=mm_deploy_log_grid
							rowset_name=deploy_log
							param_nav_id=mm_deploys_grid params=deploy
						></x-grid>
						<x-grid
							label="Backups"
							id=mm_backups
							rowset_name=backups
							param_nav_id=mm_deploys_grid params=deploy
						></x-grid>
					</x-tabs>
				</x-split>
			</x-split>
			<div action=config class="x-container" style="justify-content: center">
				<x-bare-nav id=mm_config_nav rowset_name=config></x-bare-nav>
				<x-form nav_id=mm_config_nav id=mm_config_form grid>
					<h2 area=h1>SSH</h2>
					<x-textarea mono rows=12 col=mm_pubkey infomode=under
						info="This is the SSH key used to log in as root on all machines.">
					</x-textarea>
					<x-button danger action_name=ssh_key_gen style="grid-area: ssh_key_gen_button"
						text="Generate new key" icon="fa fa-key">
					</x-button>
					<x-button danger action_name=ssh_key_updates style="grid-area: ssh_key_updates_button"
						text="Upload key to all machines" icon="fa fa-upload">
					</x-button>
					<div area=h2><hr><h2>MySQL</h2></div>
					<x-passedit col=mysql_root_pass copy
						info="Derived from the SSH Key. When updating the SSH key
							the MySQL root password is updated too."></x-passedit>
				</x-form>
			</div>
		</x-switcher>
		<x-tabs>
			<x-split label="Running Tasks" fixed_side=second fixed_size=600>
				<x-grid id=mm_running_tasks_grid rowset_name=running_tasks save_on_input action_band_visible=no></x-grid>
				<x-tabs>
					<x-textarea mono console class=x-stretched label="OUT/ERR" id=mm_task_out_textarea nav_id=mm_running_tasks_grid col=out></x-textarea>
					<x-textarea mono console class=x-stretched label="STDIN" id=mm_task_stdin_textarea nav_id=mm_running_tasks_grid col=stdin></x-textarea>
				</x-tabs>
			</x-split>
			<x-split label="Scheduled Tasks" fixed_side=second fixed_size=600>
				<x-grid id=mm_scheduled_tasks_grid rowset_name=scheduled_tasks></x-grid>
				<x-grid vertical
					id=mm_scheduled_task_grid
					rowset_name=scheduled_task
					param_nav_id=mm_scheduled_tasks_grid params=task
				></x-grid>
			</x-split>
		</x-tabs>
	</x-vsplit>
</x-split>
</x-if>
]]

js[[

// machines gre / refresh button field attrs & action
rowset_field_attrs['machines.refresh'] = {
	type: 'button',
	w: 40,
	button_options: {icon: 'fas fa fa-sync', bare: true, text: '', load_spin: true},
	action: function(machine) {
		this.load(['', 'machine-info-update', machine])
	},
}

// output textarea auto-scroll.
on('mm_task_out_textarea.init', function(e) {
	e.do_after('do_update_val', function() {
		let te = e.$1('textarea')
		if (te)
			te.scroll(0, te.scrollHeight)
	})
})

function check_notify(t) {
	if (t.notify)
		notify(t.notify, t.notify_kind || 'info')
}

// machines grid context menu items.
on('mm_machines_grid.init', function(e) {

	e.on('init_context_menu_items', function(items) {

		let grid_items = [].set(items)
		items.clear()

		items.push({
			text: 'Grid options',
			items: grid_items,
		})

		let ssh_items = []

		items.push({
			text: 'SSH',
			items: ssh_items,
		})

		ssh_items.push({
			text: 'Update host fingerprint',
			action: function() {
				let machine = e.focused_row_cell_val('machine')
				if (machine)
					get(['', 'ssh-hostkey-update', machine], check_notify)
			},
		})

		ssh_items.push({
			text: 'Update key',
			action: function() {
				let machine = e.focused_row_cell_val('machine')
				if (machine)get(['', 'ssh-key-update', machine], check_notify)
			},
		})

		ssh_items.push({
			text: 'Check key',
			action: function() {
				let machine = e.focused_row_cell_val('machine')
				if (machine)get(['', 'ssh-key-check', machine], check_notify)
			},
		})

		items.push({
			text: 'Prepare machine',
			action: function() {
				let machine = e.focused_row_cell_val('machine')
				if (machine)
					get(['', 'machine-prepare', machine], check_notify)
			},
		})

		items.push({
			text: 'Update git keys',
			action: function() {
				let machine = e.focused_row_cell_val('machine')
				if (machine)
					get(['', 'git-keys-update', machine], check_notify)
			},
		})

		items.push({
			text: 'Start log server',
			action: function() {
				let machine = e.focused_row_cell_val('machine')
				if (machine)
					get(['', 'log-server', machine], check_notify)
			},
		})

		items.push({
			text: 'Test log server',
			action: function() {
				let machine = e.focused_row_cell_val('machine')
				if (machine)
					get(['', 'testlog', machine], check_notify)
			},
		})

	})

})

function ssh_key_gen() {
	this.load(['', 'ssh-key-gen'], check_notify)
}

function ssh_key_updates() {
	this.load(['', 'ssh-key-update'], check_notify)
}

function deploy_action(btn, action) {
	let deploy = mm_deploys_grid.focused_row_cell_val('deploy')
	btn.load(['', action, deploy], check_notify)
}
function deploy_start   () { deploy_action(this, 'deploy-start') }
function deploy_stop    () { deploy_action(this, 'deploy-stop') }
function deploy_restart () { deploy_action(this, 'deploy-restart') }
function deploy_deploy  () { deploy_action(this, 'deploy') }
function deploy_remove  () { deploy_action(this, 'deploy-remove') }

]]

rowset.providers = sql_rowset{
	allow = 'admin',
	select = [[
		select
			provider,
			website,
			note,
			pos,
			ctime
		from
			provider
	]],
	pk = 'provider',
	field_attrs = {
		website = {type = 'url'},
	},
	insert_row = function(self, row)
		self:insert_into('provider', row, 'provider website note pos')
	end,
	update_row = function(self, row)
		self:update_into('provider', row, 'provider website note pos')
	end,
	delete_row = function(self, row)
		self:delete_from('provider', row)
	end,
}

rowset.machines = sql_rowset{
	allow = 'admin',
	select = [[
		select
			pos,
			machine as refresh,
			machine,
			provider,
			location,
			public_ip,
			local_ip,
			admin_page,
			ssh_key_ok,
			last_seen,
			cpu,
			cores,
			ram_gb,
			ram_free_gb,
			hdd_gb,
			hdd_free_gb,
			os_ver,
			mysql_ver,
			ctime
		from
			machine
	]],
	pk = 'machine',
	order_by = 'pos, ctime',
	field_attrs = {
		public_ip   = {text = 'Public IP Address'},
		local_ip    = {text = 'Local IP Address', hidden = true},
		admin_page  = {type = 'url', text = 'VPS admin page of this machine'},
		ssh_key_ok  = {readonly = true, text = 'SSH key is up-to-date'},
		last_seen   = {readonly = true},
		cpu         = {readonly = true, text = 'CPU'},
		cores       = {readonly = true, w = 20},
		ram_gb      = {readonly = true, w = 40, decimals = 1, text = 'RAM (GB)'},
		ram_free_gb = {readonly = true, w = 40, decimals = 1, text = 'RAM/free (GB)'},
		hdd_gb      = {readonly = true, w = 40, decimals = 1, text = 'HDD (GB)'},
		hdd_free_gb = {readonly = true, w = 40, decimals = 1, text = 'HDD/free (GB)'},
		os_ver      = {readonly = true, text = 'Operating System'},
		mysql_ver   = {readonly = true, text = 'MySQL Version'},
	},
	insert_row = function(self, row)
		self:insert_into('machine', row, 'machine provider location public_ip local_ip admin_page pos')
		cp(mm.keyfile(), mm.keyfile(row.machine))
		cp(mm.ppkfile(), mm.ppkfile(row.machine))
	end,
	update_row = function(self, row)
		self:update_into('machine', row, 'machine provider location public_ip local_ip admin_page pos')
		local m1 = row.machine
		local m0 = row['machine:old']
		if m1 and m1 ~= m0 then
			if exists(mm.keyfile(m0)) then mv(mm.keyfile(m0), mm.keyfile(m1)) end
			if exists(mm.ppkfile(m0)) then mv(mm.ppkfile(m0), mm.ppkfile(m1)) end
		end
	end,
	delete_row = function(self, row)
		self:delete_from('machine', row)
		local m0 = row['machine:old']
		rm(mm.keyfile(m0))
		rm(mm.ppkfile(m0))
	end,
}

local function validate_deploy(d)
	if not d then return end
	d = d:trim()
	if d == '' then return 'cannot be empty' end
	if d:find'^[^a-z]' then return 'must start with a small letter' end
	if d:find'[_%-]$' then return 'cannot end in a hyphen or underscore' end
	if d:find'[^a-z0-9_%-]' then return 'can only contain small letters, digits, hyphens and underscores' end
	if d:find'%-%-' then return 'cannot contain double-hyphens' end
	if d:find'__' then return 'cannot contain double-underscores' end
end

rowset.deploys = sql_rowset{
	allow = 'admin',
	select = [[
		select
			pos,
			deploy,
			'' as status,
			machine,
			app,
			wanted_version,
			deployed_version,
			wanted_sdk_version,
			deployed_sdk_version,
			env,
			repo,
			secret,
			mysql_pass,
			ctime,
			mtime
		from
			deploy
	]],
	pk = 'deploy',
	name_col = 'deploy',
	field_attrs = {
		deploy = {
			validate = validate_deploy,
		},
		status = {
			compute = function(self, vals)
				local vars = mm.deploy_state_vars[vals.deploy]
				local t = vars and vars.live
				if not t then return null end
				local dt = max(0, time() - t)
				return dt < 3 and 'live' or null
			end,
		},
	},
	ro_cols = 'secret mysql_pass deployed_version deployed_sdk_version',
	hide_cols = 'secret mysql_pass repo',
	insert_row = function(self, row)
		row.secret = b64(random_string(46)) --results in a 64 byte string
 		row.mysql_pass = b64(random_string(23)) --results in a 32 byte string
 		self:insert_into('deploy', row, 'deploy machine repo app wanted_version env secret mysql_pass pos')
	end,
	update_row = function(self, row)
		self:update_into('deploy', row, 'deploy machine repo app wanted_version env pos')
	end,
	delete_row = function(self, row)
		self:delete_from('deploy', row)
	end,
}

rowset.deploy_vars = sql_rowset{
	allow = 'admin',
	select = [[
		select
			deploy,
			name,
			val
		from
			deploy_vars
	]],
	hide_cols = 'deploy',
	where_all = 'deploy in (:param:filter)',
	pk = 'deploy name',
	insert_row = function(self, row)
		self:insert_into('deploy_vars', row, 'deploy name val')
	end,
	update_row = function(self, row)
		self:update_into('deploy_vars', row, 'name val')
	end,
	delete_row = function(self, row)
		self:delete_from('deploy_vars', row)
	end,
}

rowset.config = virtual_rowset(function(self, ...)

	self.allow = 'admin'
	self.fields = {
		{name = 'config_id', type = 'number'},
		{name = 'mm_pubkey', text = 'MM\'s Public Key', maxlen = 8192},
		{name = 'mysql_root_pass', text = 'MySQL Root Password'},
	}
	self.pk = 'config_id'

	function self:load_rows(rs, params)
		local row = {1, mm.pubkey(), mm.mysql_root_pass()}
		rs.rows = {row}
	end

end)

--async exec -----------------------------------------------------------------

function mm.exec(cmd, opt)

	opt = opt or empty

	local task, err = mm.task(update({cmd = cmd}, opt))
	if not task then return nil, err end

	local webb_cx = cx() and not cx().fake
	local capture_stdout = opt.capture_stdout ~= false or webb_cx
	local capture_stderr = opt.capture_stderr ~= false or webb_cx

	local p, err = proc.exec{
		cmd = cmd,
		env = opt.env and update(proc.env(), opt.env),
		async = true,
		autokill = true,
		stdout = capture_stdout,
		stderr = capture_stderr,
		stdin = opt.stdin and true or false,
	}

	if not p then
		task:logerror('exec', '%s', err)
	else

		task.process = p
		task:setstatus'running'

		if p.stdin then
			resume(thread(function()
				dbg('mm', 'execin', '%s', opt.stdin)
				local ok, err = p.stdin:write(opt.stdin)
				if not ok then
					task:logerror('stdinwr', '%s', err)
				end
				p.stdin:close() --signal eof
			end, 'exec-stdin %s', p))
		end

		if p.stdout then
			resume(thread(function()
				local buf, sz = u8a(4096), 4096
				while true do
					local len, err = p.stdout:read(buf, sz)
					if not len then
						task:logerror('stdoutrd', '%s', err)
						break
					elseif len == 0 then
						break
					end
					local s = ffi.string(buf, len)
					task:out(s)
				end
				p.stdout:close()
			end, 'exec-stdout %s', p))
		end

		if p.stderr then
			resume(thread(function()
				local buf, sz = u8a(4096), 4096
				while true do
					local len, err = p.stderr:read(buf, sz)
					if not len then
						task:logerror('stderrrd', '%s', err)
						break
					elseif len == 0 then
						break
					end
					local s = ffi.string(buf, len)
					task:err(s)
				end
				p.stderr:close()
			end, 'exec-stderr %s', p))
		end

		--release all db connections now in case this is a long running task.
		release_dbs()

		local exit_code, err = p:wait()
		if not exit_code then
			task:logerror('procwait', '%s', err)
		end
		while not (
				 (not p.stdin or p.stdin:closed())
			and (not p.stdout or p.stdout:closed())
			and (not p.stderr or p.stderr:closed())
		) do
			sleep(.1)
		end
		p:forget()
		task:finish(exit_code)
	end

	if opt and not webb_cx then
		task:free()
	else
		resume(thread(function()
			sleep(10)
			while task.pinned do
				sleep(1)
			end
			task:free()
		end, 'exec-linger %s', p))
	end

	check500(#task.errors == 0, cat(task.errors, '\n'))
	check500(task.exit_code == 0, 'Task finished with exit code %d', task.exit_code)

	return task
end

--ssh ------------------------------------------------------------------------

function mm.ip(md, from_db)
	if from_server(from_db) then
		return unpack((api('ip', md)))
	end
	local md = checkarg(str_arg(md), 'machine or deploy required')
	local m = first_row('select machine from deploy where deploy = ?', md) or md
	local ip = first_row('select public_ip from machine where machine = ?', m)
	return checkfound(ip, 'machine not found'), m
end
function action.ip(machine)
	out_json{mm.ip(machine, true)}
end
cmd_machines('ip MACHINE|DEPLOY', 'Get the IP address of a machine or deployment',
	function(machine)
		print(api('ip', machine)[1])
	end)

function mm.ssh(md, args, opt)
	opt = opt or {}
	local ip, machine = mm.ip(md)
	opt.machine = machine
	return mm.exec(extend({
		sshcmd'ssh',
		opt.allocate_tty and '-t' or '-T',
		'-o', 'BatchMode=yes',
		'-o', 'ConnectTimeout=5',
		'-o', 'PreferredAuthentications=publickey',
		'-o', 'UserKnownHostsFile='..mm.known_hosts_file(),
		'-i', mm.keyfile(machine),
		'root@'..ip,
	}, args), opt)
end

function mm.sshi(machine, args, opt)
	return mm.ssh(machine, args,
		update({capture_stdout = false, allocate_tty = true}, opt))
end

--remote sh scripts with stdin injection -------------------------------------

--passing both the script and the script's expected stdin contents through
--ssh's stdin at the same time is only possible due to a ridiculous behavior
--that only sh could have: sh reads its input one-byte-at-a-time and
--stops reading exactly after the `exit` command, not one byte more, so we can
--feed in stdin right after that. worse-is-better at its finest.
function mm.ssh_sh(machine, script, script_env, opt)
	opt = opt or {}
	local script_env = update({
		DEBUG   = env'DEBUG' or '',
		VERBOSE = env'VERBOSE' or '',
	}, script_env)
	local s = mm.sh_script(script:outdent(), script_env, opt.pp_env)
	opt.stdin = '{\n'..s..'\n}; exit'..(opt.stdin or '')
	note('mm', 'ssh-sh', '%s %s %s', machine, script_env, opt)
	return mm.ssh(machine, {'bash', '-s'}, opt)
end

--shell scripts with preprocessor --------------------------------------------

local function load_shfile(self, name)
	local path = indir(mm.dir, 'shlib', name..'.sh')
	return load(path)
end

mm.shlib = {} --{name->code}
setmetatable(mm.shlib, {__index = load_shfile})

function mm.sh_preprocess(vars)
	return mustache.render(s, vars, nil, nil, nil, nil, proc.esc_unix)
end

function mm.sh_script(s, env, pp_env, included)
	included = included or {}
	if type(s) == 'function' then
		s = s(env)
	end
	s = s:gsub('\r\n', '\n')
	local function include_one(s)
		local s = assertf(mm.shlib[s], 'no script: %s', s)
		return mm.sh_script(s, nil, pp_env, included)
	end
	local function include(s)
		local t = {}
		for _,s in ipairs(names(s)) do
			include_one(s)
		end
		return cat(t, '\n')
	end
	local function use(s)
		local t = {}
		for _,s in ipairs(names(s)) do
			if not included[s] then
				included[s] = true
				add(t, include_one(s))
			end
		end
		return cat(t, '\n')
	end
	local function include_lf(s)
		return '\n'..include(s)
	end
	local function use_lf(s)
		return '\n'..use(s)
	end
	s = s:gsub( '^[ \t]*#use[ \t]+([^#\r\n]+)', use)
	s = s:gsub('\n[ \t]*#use[ \t]+([^#\r\n]+)', use_lf)
	s = env and proc.quote_vars(env, nil, 'unix')..'\n'..s or s
	if pp_env then
		return mm.sh_preprocess(s, pp_env)
	else
		return s
	end
end

--running tasks --------------------------------------------------------------

mm.tasks = {}
mm.tasks_by_id = {}
mm.tasks_by_strid = {}
local last_task_id = 0
local task_events_thread

local task = {}

function mm.task(opt)
	local self = opt.task and opt.keyed ~= false and mm.tasks_by_strid[opt.task]
	if self and self.status == 'running' then
		return nil, self
	end
	last_task_id = last_task_id + 1
	local self = object(task, opt, {
		id = last_task_id,
		start_time = time(),
		duration = 0,
		status = 'new',
		errors = {},
		_out = {},
		_err = {},
		_outerr = {}, --interlaced, as they come
	})
	mm.tasks[self] = true
	mm.tasks_by_id[self.id] = self
	if self.task then
		mm.tasks_by_strid[self.task] = self
	end
	if self.persistent then
		insert_or_update_row('task', {
			task = assert(self.task),
			action = assert(self.action),
			args = pp.format(assert(self.args), false),
			run_every = self.run_every,
			generated_by = self.generated_by,
			editable = self.editable or false,
		})
	end
	return self
end

function task:free()
	mm.tasks[self] = nil
	mm.tasks_by_id[self.id] = nil
	if self.task then
		mm.tasks_by_strid[self.task] = nil
	end
	if self.persistent then
		delete_row('task', {self.task})
	end
	rowset_changed'running_tasks'
end

function task:changed()
	self.duration = (self.end_time or time()) - self.start_time
	rowset_changed'running_tasks'
end

function task:setstatus(s, exit_code)
	self.status = s
	self:changed()
end

function task:finish(exit_code)
	self.end_time = time()
	self.exit_code = exit_code
	self:setstatus(exit_code and 'finished' or 'killed')
	local s = self:stdouterr()
	if s ~= '' then
		dbg('mm', 'taskout', '%s\n%s', self.task or self.action or self.id, s)
	end
end

function task:do_kill()
	--
end

function task:kill()
	self:do_kill()
	self:finish()
end

function task:logerror(event, ...)
	add(self.errors, _(...))
	logerror('mm', event, ...)
	self:changed()
end

function task:out(s)
	add(self._out, s)
	add(self._outerr, s)
	self:changed()
end

function task:err(s)
	add(self._err, s)
	add(self._outerr, s)
	self:changed()
end

function task:stdout    () return cat(self._out) end
function task:stderr    () return cat(self._err) end
function task:stdouterr () return cat(self._outerr) end

rowset.running_tasks = virtual_rowset(function(self, ...)

	self.allow = 'admin'
	self.fields = {
		{name = 'id'        , type = 'number', w = 20},
		{name = 'pinned'    , type = 'bool'},
		{name = 'task'      , },
		{name = 'action'    , hidden = true, },
		{name = 'args'      , hidden = true, },
		{name = 'machine'   , hidden = true, hint = 'Machine(s) that this task affects'},
		{name = 'status'    , },
		{name = 'start_time', type = 'timestamp'},
		{name = 'duration'  , type = 'number', decimals = 2,  w = 20,
			hint = 'Duration till last change in input, output or status'},
		{name = 'stdin'     , hidden = true, maxlen = 16*1024^2},
		{name = 'out'       , hidden = true, maxlen = 16*1024^2},
		{name = 'exit_code' , type = 'number', w = 20},
		{name = 'errors'    , },
	}
	self.pk = 'id'
	self.rw_cols = 'pinned'

	local function task_row(task)
		return {
			task.id,
			task.pinned or false,
			task.task,
			task.action,
			task.args and cat(imap(task.args, tostring), ' '),
			task.machine,
			task.status,
			task.start_time,
			task.duration,
			task.stdin,
			task:stdouterr(),
			task.exit_code,
			concat(task.errors, '\n'),
		}
	end

	function self:load_rows(rs, params)
		local filter = params['param:filter']
		rs.rows = {}
		for task in sortedpairs(mm.tasks, function(t1, t2) return t1.start_time < t2.start_time end) do
			add(rs.rows, task_row(task))
		end
	end

	function self:load_row(row)
		local task = mm.tasks_by_id[row['id:old']]
		return task and task_row(task)
	end

	function self:update_row(row)
		local task = mm.tasks_by_id[row['id:old']]
		if not task then return end
		task.pinned = row.pinned
	end

	function self:delete_row(row)
		task:kill()
	end

end)

--scheduled tasks ------------------------------------------------------------

mm.argdef = {
	log_server = {
		{name = 'machine', lookup_cols = 'machine', lookup_rowset_name = 'lookup_machine'},
	},
	rtunnel = {
		{name = 'machine', lookup_cols = 'machine', lookup_rowset_name = 'lookup_machine'},
		{name = 'ports'},
	},
}

rowset.scheduled_task = virtual_rowset(function(self)
	self.allow = 'admin'
	self.manual_init_fields = true
	function self:load_rows(rs, params)
		local tasks = params['param:filter']
		checkarg(tasks and #tasks == 1)
		local task = tasks[1]
		local task = first_row('select task, action, args from task where task = ?', task)
		local row = check500(loadstring('return '..task.args))()
		self.fields = mm.argdef[task.action]
		if not self.fields then
			self.fields = {}
			for i,v in ipairs(row) do
				self.fields[i] = {name = 'arg'..i}
			end
		end
		rs.rows = {row}
		self:init_fields()
	end
	function self:update_row(row)
		local task = row['task:old']
		local task = first_row('select args from task where task = ?', task)
	end
end)

rowset.scheduled_tasks = sql_rowset{
	allow = 'admin',
	select = [[
		select
			task,
			action,
			args,
			start_at,
			run_every,
			armed,
			generated_by,
			editable,
			last_run,
			last_duration,
			last_status
		from
			task
	]],
	pk = 'task',
	ro_cols = 'task action args',
	hide_cols = 'action args',
	insert_row = function(self, row)
		self:insert_into('task', row, 'task action args start_at run_every armed')
	end,
	update_row = function(self, row)
		checkarg(row['editable:old'])
		self:update_into('task', row, 'task action args start_at run_every armed')
	end,
	delete_row = function(self, row)
		checkarg(row['editable:old'])
		self:delete_from('task', row)
	end,
}

local function run_task(action, args)
	local cmd = mm[action]
	local args, err = loadstring('return '..(args or '{}'))
	args = args and args()
	if not istab(args) then
		args, err = nil, 'task args not a table'
	end
	warnif('mm', 'task', not cmd, 'invalid task action "%s"', action)
	warnif('mm', 'task', not args, 'invalid task args "%s": %s', args, err)
	if not (cmd and args) then
		return
	end
	resume(webb.thread(function()
		cx().fake = false
		cmd(unpack(args))
		cx().fake = true
	end, 'run-task'))
end

local function run_tasks()
	local now = time()
	local today = glue.day(now)
	for _, task, action, args, start_at, run_every in each_row_vals[[
		select
			task,
			action,
			args,
			time_to_sec(start_at) start_at,
			run_every,
			last_run
		from
			task
		where
			armed = 1
		order by
			last_run
	]] do
		local start_at = start_at and today + start_at or now
		local dt = run_every and run_every ~= 0
			and (now - start_at) % run_every or 0
		--^^ seconds past last target time
		if dt <= (run_every or 0) / 2 then --up-to half-interval late
			local target_time = now - dt
			if (last_run or -1/0) < target_time then --not already run
				local armed = run_every and true or false
				update_row('task', {task, last_run = now, armed = armed})
				run_task(action, args)
			end
		end
	end
end

--listings -------------------------------------------------------------------

local mysql = require'mysql'
local function timeago(s)
	--NOTE: this only works if both the MySQL server and the app server have
	--the same timezone. The correct way is to get the date in UTC.
	return glue.timeago(false, mysql.datetime_to_timestamp(s))
end

function action.machines()
	outpqr(query({
		compact=1,
		field_attrs = {
			last_seen = {mysql_to_lua = timeago},
		},
	}, [[
		select
			machine,
			public_ip,
			last_seen,
			cores,
			ram_gb, ram_free_gb,
			hdd_gb, hdd_free_gb,
			cpu,
			os_ver,
			mysql_ver,
			ctime
		from machine
		order by pos, ctime
	]]))
end
cmd_machines('m|machines', 'Show the list of machines',
	function()
		out(api'machines')
	end)

function action.deploys()
	outpqr(query({
		compact=1,
		field_attrs = {},
	}, [[
		select
			deploy,
			machine,
			repo,
			app,
			wanted_version,
			deployed_version,
			env,
			ctime
		from deploy
		order by pos, ctime
	]]))
end
cmd_deployments('d|deploys', 'Show the list of deployments',
	function()
		out(api'deploys')
	end)

--command: machine-info-update -----------------------------------------------

function mm.machine_info(machine)
	local stdout = mm.ssh_sh(machine, [=[

		#use mysql

		echo "           os_ver $(lsb_release -sd)"
		echo "        mysql_ver $(has_mysql && query 'select version();')"
		echo "              cpu $(lscpu | sed -n 's/^Model name:\s*\(.*\)/\1/p')"
		                   cps="$(lscpu | sed -n 's/^Core(s) per socket:\s*\(.*\)/\1/p')"
		               sockets="$(lscpu | sed -n 's/^Socket(s):\s*\(.*\)/\1/p')"
		echo "            cores $(expr $sockets \* $cps)"
		echo "           ram_gb $(cat /proc/meminfo | awk '/MemTotal/ {$2/=1024*1024; printf "%.2f",$2}')"
		echo "      ram_free_gb $(cat /proc/meminfo | awk '/MemAvailable/ {$2/=1024*1024; printf "%.2f",$2}')"
		echo "           hdd_gb $(df -l | awk '$6=="/" {printf "%.2f",$2/(1024*1024)}')"
		echo "      hdd_free_gb $(df -l | awk '$6=="/" {printf "%.2f",$4/(1024*1024)}')"

	]=], nil, {task = 'machine_info '..machine, keyed = false}):stdout()
	local t = {machine = machine, last_seen = time()}
	for s in stdout:trim():lines() do
		local k,v = assert(s:match'^%s*(.-)%s+(.*)')
		add(t, k)
		t[k] = v
	end

	assert(query([[
	update machine set
		os_ver      = :os_ver,
		mysql_ver   = :mysql_ver,
		cpu         = :cpu,
		cores       = :cores,
		ram_gb      = :ram_gb,
		ram_free_gb = :ram_free_gb,
		hdd_gb      = :hdd_gb,
		hdd_free_gb = :hdd_free_gb,
		last_seen   = from_unixtime(:last_seen)
	where
		machine = :machine
	]], t).affected_rows == 1)
	rowset_changed'machines'

	return t
end

function action.machine_info(machine)
	local t = mm.machine_info(machine)
	for i,k in ipairs(t) do
		outprint(_('%20s %s', k, t[k]))
	end
end
cmd_machines('machine-info MACHINE', 'Show machine info',
	function(machine)
		out(api('machine-info', machine))
	end)

--command: ssh-hostkey-update ------------------------------------------------

function mm.gen_known_hosts_file()
	local t = {}
	for i, ip, s in each_row_vals[[
		select public_ip, fingerprint
		from machine
		where fingerprint is not null
		order by pos, ctime
	]] do
		add(t, s)
	end
	save(mm.known_hosts_file(true), concat(t, '\n'))
end

function mm.ssh_hostkey_update(machine)
	local cmd = {sshcmd'ssh-keyscan', '-4', '-T', '2', '-t', 'rsa', (mm.ip(machine, true))}
	local opt = {task = 'ssh_hostkey_update '..machine,
		action = 'ssh_hostkey_update', args = {'machine'}}
	local task, err = mm.exec(cmd, opt)
	if not task then return nil, err end
	local fp = task:stdout()
	assert(update_row('machine', {machine, fingerprint = fp}).affected_rows == 1)
	mm.gen_known_hosts_file()
end
function action.ssh_hostkey_update(machine)
	allow(admin())
	mm.ssh_hostkey_update(machine)
	out_json{machine = machine, notify = 'Host fingerprint updated for '..machine}
end
cmd_ssh_keys('ssh-hostkey-update MACHINE', 'Make a machine known again to us',
	function(machine)
		api('ssh-hostkey-update', machine)
	end)

--command: ssh-key-gen -------------------------------------------------------

function mm.ssh_key_gen()
	rm(mm.keyfile())
	exec(sshcmd'ssh-keygen'..' -f %s -t rsa -b 2048 -C "mm" -q -N ""', mm.keyfile())
	rm(mm.keyfile()..'.pub') --we'll compute it every time.
	mm.ssh_key_fix_perms()
	mm.ssh_key_gen_ppk()
	rowset_changed'config'
	query'update machine set ssh_key_ok = 0'
	rowset_changed'machines'
end
function action.ssh_key_gen()
	allow(admin())
	mm.ssh_key_gen()
	out_json{notify = 'SSH key generated'}
end
cmd_ssh_keys('ssh-key-gen', 'Generate a new SSH key', function()
	api'ssh-key-gen'
end)

--command: pubkey ------------------------------------------------------------

--for manual updating via `curl mm.allegory.ro/pubkey/MACHINE >> authroized_keys`.
function action.ssh_pubkey(machine)
	allow(admin())
	setmime'txt'
	out(mm.pubkey(machine))
end
cmd_ssh_keys('ssh-pubkey [MACHINE]', 'Show a SSH public key', function(machine)
	print(api('ssh-pubkey', machine))
end)

--command: ssh-key-update ----------------------------------------------------

function mm.each_machine(f)
	local threads = sock.threadset()
	for _, machine in each_row_vals'select machine from machine' do
		resume(threads:thread(f, machine))
	end
	assert(threads:wait())
end

function mm.ssh_key_update(machine)
	if not machine then
		mm.each_machine(mm.ssh_key_update)
		return true
	end

	note('mm', 'upd-key', '%s', machine)
	local pubkey = mm.pubkey()
	local stored_pubkey = mm.ssh_sh(machine, [=[
		#use ssh mysql user
		has_mysql && mysql_update_root_pass "$MYSQL_ROOT_PASS"
		ssh_update_pubkey mm "$PUBKEY"
		user_lock_pass root
		ssh_pubkey mm
	]=], {
		PUBKEY = pubkey,
		MYSQL_ROOT_PASS = mm.mysql_root_pass(),
	}, {task = 'ssh_key_update '..machine}):stdout():trim()

	if stored_pubkey ~= pubkey then
		return nil, 'Public key NOT updated'
	end

	cp(mm.keyfile(), mm.keyfile(machine))
	cp(mm.ppkfile(), mm.ppkfile(machine))
	mm.ssh_key_fix_perms(machine)

	update_row('machine', {ssh_key_ok = true, ['machine:old'] = machine}, 'ssh_key_ok')
	rowset_changed'machines'

	return true
end
function action.ssh_key_update(machine)
	allow(admin())
	check500(mm.ssh_key_update(machine))
	out_json{machine = machine,
		notify = machine
			and 'SSH key updated for '..machine
			or 'SSH key update tasks created',
	}
end
cmd_ssh_keys('ssh_key_update [MACHINE]', 'Update SSH key(s)', function(machine)
	api('ssh-key-update', machine)
end)

function mm.ssh_key_check(machine)
	local host_pubkey = mm.ssh_sh(machine, [[
		#use ssh
		ssh_pubkey mm
	]], nil, {task = 'ssh_key_check '..machine}):stdout():trim()
	return host_pubkey == mm.pubkey()
end
function action.ssh_key_check(machine)
	allow(admin())
	local ok = mm.ssh_key_check(machine)
	update_row('machine', {ssh_key_ok = ok, ['machine:old'] = machine}, 'ssh_key_ok')
	rowset_changed'machines'
	out_json{
		notify = 'SSH key is'..(ok and '' or ' NOT')..' up-to-date for '..machine,
		notify_kind = ok and 'info' or 'warn',
		machine = machine,
		ssh_key_ok = ok,
	}
end
cmd_ssh_keys('ssh_key_check MACHINE', 'Check a SSH key', function(machine)
	api('ssh-key-check', machine)
end)

--git keys update -------------------------------------------------------------

local function git_hosting_vars()
	local vars = {GIT_HOSTS = cat(keys(mm.git_hosting, true), ' ')}
	for host,t in pairs(mm.git_hosting) do
		for k,v in pairs(t) do
			vars[(host..'_'..k):upper()] = v
		end
	end
	return vars
end

function mm.git_keys_update(machine)
	local vars = git_hosting_vars()
	mm.ssh_sh(machine, [=[
		#use ssh
		ssh_git_keys_update
	]=], vars, {task = 'git_keys_update '..machine})
end
function action.git_keys_update(machine)
	allow(admin())
	if not machine then
		mm.each_machine(function(machine)
			mm.git_keys_update(machine)
		end)
		return true
	end
	mm.git_keys_update(machine)
	out_json{machine = machine, notify = 'Git keys updated for '..machine}
end
cmd_ssh_keys('git-keys-update [MACHINE]', 'Updage Git SSH keys',
	function(machine)
		api('git-keys-update', machine)
	end)

--command: machine-prepare ---------------------------------------------------

function mm.machine_prepare(machine)
	local vars = git_hosting_vars()
	vars.MYSQL_ROOT_PASS = mm.mysql_root_pass(machine)
	mm.ssh_sh(machine, [=[
		#use deploy
		machine_prepare
	]=], vars, {task = 'machine_prepare '..machine})
end

function action.machine_prepare(machine)
	mm.machine_prepare(machine)
	out_json{machine = machine, notify = 'Machine prepared: '..machine}
end
cmd_machines('machine_prepare MACHINE', 'Prepare a new machine', function(machine)
	api('machine-prepare', machine)
end)

--deploy commands ------------------------------------------------------------

function mm.deploy(deploy)
	local vars = deploy_vars(deploy)
	update(vars, git_hosting_vars())
	mm.ssh_sh(vars.MACHINE, [[
		#use deploy
		deploy
	]], vars, {task = 'deploy '..deploy})
	update_row('deploy', {vars.DEPLOY, deployed_version = vars.VERSION})
end
function action.deploy(deploy)
	mm.deploy(deploy)
	out_json{deploy = deploy, notify = 'Deployed: '..deploy}
end
cmd_deployments('deploy DEPLOY', 'Deploy an app', function(deploy)
	api('deploy', deploy)
end)

function mm.deploy_remove(deploy)
	local vars = deploy_vars(deploy)
	mm.ssh_sh(vars.MACHINE, [[
		#use deploy
		deploy_remove
	]], {
		DEPLOY = vars.DEPLOY,
		APP = vars.APP,
	}, {task = 'deploy_remove '..deploy})
end
function action.deploy_remove(deploy)
	mm.deploy_remove(deploy)
	out_json{deploy = deploy, notify = 'Deploy removed: '..deploy}
end
cmd_deployments('deploy-remove DEPLOY', 'Remove a deployment', function(deploy)
	api('deploy-remove', deploy)
end)

function mm.deploy_run(deploy, ...)
	local vars = deploy_vars(deploy)
	local cmd_args = proc.quote_args_unix(...)
	mm.ssh_sh(vars.MACHINE, [[
		#use deploy
		app $cmd_args
		]], {
			DEPLOY = vars.DEPLOY,
			APP = vars.APP,
			cmd_args = cmd_args,
		}, {task = 'deploy_run '..deploy..' '..cmd_args})
end
local function app_cmd(cmd, notify)
	return function(deploy, ...)
		mm.deploy_run(deploy, cmd, ...)
		if notify then
			out_json({deploy = deploy, notify = notify})
		end
	end
end
mm.deploy_start   = app_cmd('start'  , 'App started')
mm.deploy_stop    = app_cmd('stop'   , 'App stopped')
mm.deploy_restart = app_cmd('restart', 'App restarted')
mm.deploy_status  = app_cmd('status')

action.deploy_start   = mm.deploy_start
action.deploy_stop    = mm.deploy_stop
action.deploy_restart = mm.deploy_restart
action.deploy_status  = mm.deploy_status

--TODO:
--cmd_deployments('deploy-run     DEPLOY ...', 'Run a deployed app', mm.deploy_run)
--cmd_deployments('deploy-start   DEPLOY', 'Start a deployed app', mm.deploy_start)
--cmd_deployments('deploy-stop    DEPLOY', 'Stop a deployed app', mm.deploy_stop)
--cmd_deployments('deploy-restart DEPLOY', 'Restart a deployed app', mm.deploy_restart)
--cmd_deployments('deploy-status  DEPLOY', 'Check status for a deployed app', mm.deploy_status)

--remote logging -------------------------------------------------------------

mm.log_port = 5555
mm.log_local_port1 = 6000
mm.log_ports = {} --{port->machine}
mm.log_queue_size = 10000

function mm.logport(machine)
	machine = checkarg(str_arg(machine))
	for port = mm.log_local_port1, 65535 do
		if not mm.log_ports[port] then
			mm.log_ports[port] = machine
			return port
		end
	end
	error'all ports are used'
end

mm.deploy_logs = {}
mm.deploy_state_vars = {}

function mm.log_server(machine)
	machine = checkarg(str_arg(machine))
	local lport = mm.logport(machine)
	resume(thread(function()
		mm.rtunnel(machine, lport..':'..mm.log_port, {
			persistent = true,
			run_every = 0,
			generated_by = 'log_server',
			editable = false,
		})
	end, 'log-server-rtunnel %s', machine))
	local task, err = mm.task({
		task = 'log_server '..machine,
		action = 'log_server', args = {machine},
		machine = machine,
		persistent = true,
		run_every = 0,
		generated_by = 'log_server',
		editable = false,
	})
	if not task then return nil, err end
	local tcp = assert(sock.tcp())
	assert(tcp:setopt('reuseaddr', true))
	assert(tcp:listen('127.0.0.1', lport))
	sock.liveadd(tcp, 'logging')
	resume(thread(function()
		task:setstatus'running'
		while not task.stop do
			local ctcp, err = tcp:accept()
			local ra = ctcp.remote_addr
			local rp = ctcp.remote_port
			local la = ctcp. local_addr
			local lp = ctcp. local_port
			sock.liveadd(ctcp, 'logging')
			resume(thread(function()
				local lenbuf = u32a(1)
				local msgbuf = buffer()
				local plenbuf = cast(u8p, lenbuf)
				while not task.stop do
					local len = ctcp:recvn(plenbuf, 4)
					if not len then break end
					local len = lenbuf[0]
					local buf = msgbuf(len)
					assert(ctcp:recvn(buf, len))
					local s = ffi.string(buf, len)
					local msg = loadstring('return '..s)()
					msg.machine = machine
					if msg.event == 'set' then
						attr(mm.deploy_state_vars, msg.deploy)[msg.k] = msg.v
					else
						local q = mm.deploy_logs[msg.deploy]
						if not q then
							q = queue.new(mm.log_queue_size)
							q.next_id = 1
							mm.deploy_logs[msg.deploy] = q
						end
						if q:full() then
							q:pop()
						end
						msg.id = q.next_id
						q.next_id = q.next_id + 1
						q:push(msg)
						rowset_changed'deploy_log'
					end
				end
				ctcp:close()
			end, 'log-server-client %s', ctcp))
		end
		task:free()
	end, 'log-server %s %s', tcp, machine))
end

action.log_server = mm.log_server

rowset.deploy_log = virtual_rowset(function(self)
	self.allow = 'admin'
	self.fields = {
		{name = 'id'      , hidden = true},
		{name = 'time'    , max_w = 100, type = 'timestamp'},
		{name = 'deploy'  , max_w =  80},
		{name = 'severity', max_w =  60},
		{name = 'module'  , max_w =  60},
		{name = 'event'   , max_w =  60},
		{name = 'message' , maxlen = 16 * 1024^2},
		{name = 'env'     , hidden = true},
	}
	self.pk = 'id'
	function self:load_rows(rs, params)
		rs.rows = {}
		local deploys = params['param:filter']
		if deploys then
			for _, deploy in ipairs(deploys) do
				local msg_queue = mm.deploy_logs[deploy]
				if msg_queue then
					for msg in msg_queue:items() do
						add(rs.rows, {msg.id, msg.time, msg.deploy, msg.severity, msg.module, msg.event, msg.message, msg.env})
					end
				end
			end
		end
	end
end)

--backups --------------------------------------------------------------------

rowset.backups = sql_rowset{
	allow = 'admin',
	select = [[
		select
			b.bkp        ,
			b.parent_bkp ,
			b.deploy     ,
			b.start_time ,
			b.duration   ,
			b.size       ,
			b.checksum   ,
			b.name
		from bkp b
	]],
	where_all = 'b.deploy in (:param:filter)',
	pk = 'bkp',
	field_attrs = {
		start_time = {mysql_to_lua = timeago},
	},
	parent_col = 'parent_bkp',
	insert_row = function(self, row)
		local machine = checkarg(first_row('select machine from deploy where deploy = ?', row.deploy))
 		row.bkp = self:insert_into('bkp', row, 'parent_bkp deploy name')
		row.start_time = time()
		query('update bkp set start_time = from_unixtime(?) where bkp = ?', row.start_time, row.bkp)
		resume(thread(function()
			mm.ssh_mm('backup', machine, [[
				xbkp_backup "$deploy" "$bkp" "$parent_bkp"
			]], {deploy = row.deploy, bkp = row.bkp, parent_bkp = parent_bkp})
			update_row('bkp', {['bkp:old'] = row.bkp, duration = time() - row.start_time}, 'duration')
			rowset_changed'backups'
		end))
	end,
	update_row = function(self, row)
		self:update_into('bkp', row, 'name')
	end,
	delete_row = function(self, row)
		local bkp = row['bkp:old']
		local deploy = checkarg(first_row('select deploy from bkp where bkp = ?', bkp))
 		local machine = checkarg(first_row('select machine from deploy where deploy = ?', deploy))
		mm.ssh_mm('backup_remove '..bkp, machine, [[
			must xbkp_remove "$deploy" "$bkp"
		]], {deploy = deploy, bkp = bkp})
		self:delete_from('bkp', row)
	end,
}

--remote access tools --------------------------------------------------------

cmd_ssh('ssh MACHINE|DEPLOY [CMD ...]', 'SSH into machine', function(md, cmd, ...)
	local ip, m = mm.ip(md)
	mm.sshi(md, cmd and {'bash', '-c', "'"..catargs(' ', cmd, ...).."'"})
end)

--TIP: make a putty session called `mm` where you set the window size,
--uncheck "warn on close" and whatever else you need to make worrking
--with putty comfortable for you.
cmd_ssh(Windows, 'putty MACHINE|DEPLOY', 'SSH into machine with putty', function(md)
	local ip, m = mm.ip(md)
	local deploy = m ~= md and md or nil
	local cmdfile = tmppath'puttycmd.txt'
	local cmd = indir(mm.bindir, 'putty')..' -load mm -t -i '..mm.ppkfile(m)
		..' root@'..ip..' -m '..cmdfile
	local script = [[
	#use deploy
	]]
	local script_env = update({
		DEBUG   = env'DEBUG' or '',
		VERBOSE = env'VERBOSE' or '',
	}, git_hosting_vars(), deploy and deploy_vars(deploy))
	local s = mm.sh_script(script:outdent(), script_env)
	local s = catargs('\n',
		'export MM_TMP_SH=/root/.mm.$$.sh',
		'cat << \'EOFFF\' > $MM_TMP_SH',
		'trap "rm -f -- $MM_TMP_SH" EXIT',
		s,
		deploy and 'must cd /home/$DEPLOY/$APP',
		deploy and 'VARS="DEBUG VERBOSE" run_as $DEPLOY bash',
		--deploy and 'sudo -iu '..deploy..' bash',
		'EOFFF',
		'exec bash --init-file $MM_TMP_SH'
	)
	save(cmdfile, s)
	runafter(.5, function()
		rm(cmdfile)
	end)
	proc.exec(cmd):forget()
end)

cmd_ssh('ssh-all CMD', 'Execute command on all machines', function(command)
	command = checkarg(str_arg(command), 'command expected')
	for _, machine in each_row_vals'select machine from machine' do
		resume(thread(function()
			say('Executing on '..machine..'...')
			mm.ssh(machine, command and {'bash', '-c', (command:gsub(' ', '\\ '))})
		end))
	end
end)

function mm.tunnel(machine, ports, opt, rev)
	local args = {'-N'}
	if logging.debug then add(args, '-v') end
	ports = checkarg(str_arg(ports), 'ports expected')
	local lports = {}
	for ports in ports:gmatch'([^,]+)' do
		local rport, lport = ports:match'(.-):(.*)'
		rport = rport or ports
		lport = lport or ports
		add(args, rev and '-R' or '-L')
		add(args, '127.0.0.1:'..lport..':127.0.0.1:'..rport)
		note('mm', 'tunnel', '%s:%s %s %s', machine, lport, rev and '->' or '<-', rport)
		add(lports, lport)
	end
	local action = (rev and 'r' or '')..'tunnel'
	opt = update({
		task = action..' '..machine..' '..cat(lports, ','),
		action = action, args = {machine, ports},
		run_every = 0,
	}, opt)
	if opt.interactive then
		opt.capture_stdout = false
		opt.allocate_tty = true
	end
	return mm.ssh(machine, args, opt)
end
function mm.rtunnel(machine, ports, opt)
	return mm.tunnel(machine, ports, opt, true)
end

cmd_ssh_tunnels('tunnel MACHINE RPORT1[:LPORT1],...', 'Create SSH tunnel(s) to machine', function(machine, ports)
	return mm.tunnel(machine, ports, {interactive = true})
end)

cmd_ssh_tunnels('rtunnel MACHINE RPORT1[:LPORT1],...', 'Create reverse SSH tunnel(s) to machine', function(machine, ports)
	return mm.rtunnel(machine, ports, {interactive = true})
end)

local function censor_mysql_pwd(s)
	return s:gsub('MYSQL_PWD=[^%s]+', 'MYSQL_PWD=censored')
end
cmd_mysql('mysql MACHINE [SQL]', 'Execute MySQL command or remote REPL', function(machine, sql)
	local args = {'MYSQL_PWD='..mm.mysql_root_pass(machine),
		'mysql', '-u', 'root', '-h', 'localhost'}
	if sql then append(args, '-e', proc.quote_arg_unix(sql)) end
	logging.censor.mysql_pwd = censor_mysql_pwd
	mm.sshi(machine, args)
	logging.censor.mysql_pwd = nil
end)

--TODO: `sshfs.exe` is buggy in background mode: it kills itself when parent cmd is closed.
function mm.mount(machine, rem_path, drive, bg)
	if win then
		drive = drive or 'S'
		rem_path = rem_path or '/'
		machine = str_arg(machine)
		local cmd =
			'"'..indir(mm.sshfsdir, 'sshfs.exe')..'"'..
			' root@'..mm.ip(machine)..':'..rem_path..' '..drive..':'..
			(bg and '' or ' -f')..
			--' -odebug'.. --good stuff (implies -f)
			--these were copy-pasted from sshfs-win manager.
			' -oidmap=user -ouid=-1 -ogid=-1 -oumask=000 -ocreate_umask=000'..
			' -omax_readahead=1GB -oallow_other -olarge_read -okernel_cache -ofollow_symlinks'..
			--only cygwin ssh works. the builtin Windows ssh doesn't, nor does our msys version.
			' -ossh_command='..path.sep(indir(mm.sshfsdir, 'ssh'), nil, '/')..
			' -oBatchMode=yes'..
			' -oRequestTTY=no'..
			' -oPreferredAuthentications=publickey'..
			' -oUserKnownHostsFile='..path.sep(mm.known_hosts_file(), nil, '/')..
			' -oIdentityFile='..path.sep(mm.keyfile(machine), nil, '/')
		if bg then
			exec(cmd)
		else
			local opt = {task = 'mount '..drive, action = 'mount', args = {rem_path, drive}}
			mm.exec(cmd, opt)
		end
	else
		NYI'mount'
	end
end
cmd_ssh_mounts('mount MACHINE PATH [DRIVE]', 'Mount remote path to drive', mm.mount)

cmd_ssh_mounts('mount-bg MACHINE PATH [DRIVE]', 'Mount remote path to drive in background',
function(machine, drive, rem_path)
	return mm.mount(machine, drive, rem_path, true)
end)

cmd_ssh_mounts('mount-kill-all', 'Kill all background mounts', function()
	if win then
		exec'taskkill /f /im sshfs.exe'
	else
		NYI'mount_kill_all'
	end
end)

function action.live()
	setmime'txt'
	logging.printlive(outprint)
end

local run_server = mm.run_server
function mm:run_server()

	runevery(1, function()
		--rowset_changed'deploys'
	end, 'rowset-changed-deploys-every-second')

	runafter(0, run_tasks, 'run-tasks-first-time')
	runevery(60, run_tasks, 'run-tasks-every-60s')

	run_server(self)
end

return mm:run(...)
