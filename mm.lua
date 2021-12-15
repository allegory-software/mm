--[[

	Many Machines, the independent man's SAAS provisioning tool.
	Written by Cosmin Apreutesei. Public Domain.

	Many Machines is a bare-bones provisioning and administration tool
	for web apps deployed on dedicated machines or VPS, as opposed to cloud
	services as it's customary these days (unless you count VPS as cloud).

	Highlights:
	- Lua API, web UI & cmdline for everything.
	- Windows-native sysadmin tools (sshfs, putty, etc.).
	- agentless.

	Features:
	- keep a database of machines and deployments.
	- maintain secure access to all services via bulk key updates:
		- ssh root access.
		- MySQL root access.
		- github access.
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

	Limitations:
	- the machines need to run Linux (Debian 10) and have a public IP.
	- all deployments connect to the same MySQL server instance.
	- each deployment is given a single MySQL db.
	- code has to be on github (in a public or private repo).
	- single github key for github access.
	- apps have to be able to self-install and self-upgrade/downgrade.

	TODO: make mm portable by using file rowsets instead of mysql.
	TODO: make mm even more portable by saving the var dir to git-hosted encrypted zip files.

	TODO: one-command-multiple-hosts: both web and cmdline.
	TODO: use plink linux binary to gen the ppk on linux.
	TODO: convert cmdline to posting mm tasks (via http?) if mm server is running.
	TODO: bind libssh2 or see what is needed to implement ssh2 protocol in Lua.

]]

require'webb'
local S = S

local function mm_schema()

	import'schema_std'
	import'webb_lang'
	import'webb_auth'

	types.ctime.text = S('ctime_text', 'Created At')
	types.mtime.text = S('mtime_text', 'Last Modified At')
	types.atime.text = S('atime_text', 'Last Accessed At')

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
		last_seen   , timestamp,
		os_ver      , name,
		mysql_ver   , name,
		cpu         , name,
		cores       , smallint,
		ram_gb      , double,
		ram_free_gb , double,
		hdd_gb      , double,
		hdd_free_gb , double,
		log_port    , int,
		pos         , pos,
		ctime       , ctime,
	}

	tables.deploy = {
		deploy           , strpk,
		machine          , strid, not_null, fk,
		master_deploy    , strid, fk(deploy),
		repo             , url, not_null,
		wanted_version   , strid,
		deployed_version , strid,
		env              , strid, not_null,
		secret           , b64key, not_null, --multi-purpose
		mysql_pass       , hash, not_null,
		status           , strid,
		ctime            , ctime,
		pos              , pos,
	}

	tables.bkp = {
		bkp         , pk,
		parent_bkp  , id, child_fk(bkp),
		deploy      , strid, not_null, child_fk,
		start_time  , time,
		duration    , uint,
		size        , uint52,
		checksum    , hash,
		name        , name,
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

require'$daemon'
require'xmodule'

local b64 = require'base64'.encode
local proc = require'proc'
local sock = require'sock'
local xapp = require'xapp'
local mustache = require'mustache'
local queue = require'queue'
local schema = require'schema'

local sshfs_dir = [[C:\PROGRA~1\SSHFS-Win\bin]] --no spaces!

config('http_port', 8080)
local mm = xapp(daemon'mm')
mm.use_plink = false

--tools ----------------------------------------------------------------------

local function NYI(event)
	logerror('mm', event, 'NYI')
end

function sshcmd(cmd)
	return win and indir(exedir, cmd) or cmd
end

function mm.keyfile(machine, suffix, ext)
	machine = machine and machine:trim()
	local file = 'mm'..(machine and '-'..machine or '')
		..(suffix and '.'..suffix or '')..'.'..(ext or 'key')
	return indir(var_dir, file)
end

function mm.ppkfile(machine, suffix)
	return mm.keyfile(machine, suffix, 'ppk')
end

function mm.pubkey(machine, suffix)
	return readpipe(sshcmd'ssh-keygen'..' -y -f "'..mm.keyfile(machine, suffix)..'"'):trim()..' mm'
end

--TODO: `plink -hostkey` doesn't work when the server has multiple fingerprints.
function mm.ssh_hostkey(machine)
	machine = checkarg(str_arg(machine))
	local key = first_row('select fingerprint from machine where machine = ?', machine):trim()
	return mm.exec('hostkey', {sshcmd'ssh-keygen', '-E', 'sha256', '-lf', '-'}, {stdin = key})
		:stdout():trim():match'%s([^%s]+)'
end
function action.ssh_hostkey(machine)
	setmime'txt'
	out(mm.ssh_hostkey(machine))
end
cmd.ssh_hostkey = action.ssh_hostkey

--run this to avoid getting the incredibly stupid "perms are too open" error from ssh.
function mm.ssh_key_fix_perms(machine)
	if not win then return end
	local s = mm.keyfile(machine)
	readpipe('icacls %s /c /t /Inheritance:d', s)
	readpipe('icacls %s /c /t /Grant %s:F', s, env'UserName')
	readpipe('takeown /F %s', s)
	readpipe('icacls %s /c /t /Grant:r %s:F', s, env'UserName')
	readpipe('icacls %s /c /t /Remove:g "Authenticated Users" BUILTIN\\Administrators BUILTIN Everyone System Users', s)
	readpipe('icacls %s', s)
end

function mm.ssh_key_gen_ppk(machine, suffix)
	local key = mm.keyfile(machine, suffix)
	local ppk = mm.ppkfile(machine, suffix)
	if win then
		exec(indir(exedir, 'winscp.com')..' /keygen %s /output=%s', key, ppk)
	else
		--TODO: use plink linux binary to gen the ppk.
		NYI'ssh_key_gen_ppk'
	end
end
cmd.ssh_key_gen_ppk = mm.ssh_key_gen_ppk

function mm.mysql_root_pass(machine) --last line of the private key
	local s = load(mm.keyfile(machine))
		:gsub('%-+.-PRIVATE%s+KEY%-+', ''):gsub('[\r\n]', ''):trim():sub(-32)
	assert(#s == 32)
	return s
end
function action.mysql_root_pass(machine)
	setmime'txt'
	out(mm.mysql_root_pass(machine))
end
cmd.mysql_root_pass = action.mysql_root_pass

--config ---------------------------------------------------------------------

mm.known_hosts_file  = indir(var_dir, 'known_hosts')
mm.github_key_file   = indir(var_dir, 'mm_github.key')
mm.github_key        = readfile(mm.github_key_file, trim)

config('http_addr', '*')

--logging.filter[''] = true
require'http'.logging = logging
require'http_server'.logging = logging
require'mysql_client'.logging = logging

config('db_host', '10.0.0.5')
config('db_port', 3307)
config('db_pass', 'root')
config('secret' , '!xpAi$^!@#)fas!`5@cXiOZ{!9fdsjdkfh7zk')

--https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/githubs-ssh-key-fingerprints
mm.github_fingerprint = ([[
github.com ssh-rsa AAAAB3NzaC1yc2EAAAABIwAAAQEAq2A7hRGmdnm9tUDbO9IDSwBK6TbQa+PXYPCPy6rbTrTtw7PHkccKrpp0yVhp5HdEIcKr6pLlVDBfOLX9QUsyCOV0wzfjIJNlGEYsdlLJizHhbn2mUjvSAHQqZETYP81eFzLQNnPHt4EVVUh7VfDESU84KezmD5QlWpXLmvU31/yMf+Se8xhHTvKSCZIFImWwoG6mbUoWf9nzpIoaSjB+weqqUUmpaaasXVal72J+UX2B+2RPW3RcT0eOzQgqlJL3RKrTJvdsjE3JEAvGq3lGHSZXy28G3skua2SmVi/w4yCE6gbODqnTWlg7+wC604ydGXA8VJiS5ap43JXiUFFAaQ==
]]):trim()

--database -------------------------------------------------------------------


function mm.install()

	import(mm_schema)

end

cmd.install = mm.install

--admin web UI ---------------------------------------------------------------

mm.title = 'Many Machines'
--mm.font = 'opensans'

css[[
body {
	/* layout content: center limited-width body to window */
	display: flex;
	flex-flow: column;
}

body { font-family: sans-serif; font-size: 13px; }
.x-grid-header-cell { font-size: 13px; }

/*
body { font-family: monospace; font-size: 12px; }
.x-grid-header-cell { font-size: 13px; }
*/

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

.x-textarea[console] {
	opacity: 1;
	white-space: pre;
	overflow-wrap: normal;
	overflow-x: scroll;
}

#mm_config_form.maxcols1 {
	max-width: 400px;
	grid-template-areas:
		"h1"
		"mm_"
		"ssh_key_gen_button"
		"ssh_key_updates_button"
		"h2"
		"mys"
	;
}

]]

js[[
sign_in_options = {
	logo: 'sign-in-logo.png',
}
]]

html[[
<x-split>
	<div theme=dark vflex class="x-flex">
		<div class=header>
			<div b><span class="fa fa-server"></span> MANY MACHINES</div>
			<x-settings-button></x-settings-button>
		</div>
		<x-listbox id=mm_actions_listbox>
			<div action=providers>Providers</div>
			<div action=machines>Machines</div>
			<div action=deploys>Deployments</div>
			<div action=config>Configuration</div>
		</x-listbox>
	</div>
	<x-vsplit fixed_side=second>
		<x-switcher nav_id=mm_actions_listbox>
			<x-grid action=providers id=mm_providers_grid rowset_name=providers></x-grid>
			<x-vsplit action=machines>
				<x-grid id=mm_machines_grid rowset_name=machines></x-grid>
			</x-vsplit>
			<x-vsplit action=deploys>
				<x-grid id=mm_deploys_grid rowset_name=deploys></x-grid>
				<x-split>
					<div>
						<x-button action_name=deploy_button_action text="Deploy"></x-button>
						<x-button action_name=deploy_remove_button_action text="Remove Deploy"></x-button>
					</div>
					<x-pagelist>
						<x-grid id=mm_deploy_log_grid rowset_name=deploy_log param_nav_id=mm_deploys_grid params=deploy title="Live Log"></x-grid>
						<x-grid id=mm_backups rowset_name=backups param_nav_id=mm_deploys_grid params=deploy title="Backups"></x-grid>
					</x-pagelist>
				</x-split>
			</x-vsplit>
			<div action=config class="x-container x-flex x-stretched" style="justify-content: center">
				<x-bare-nav id=mm_config_nav rowset_name=config></x-bare-nav>
				<x-form nav_id=mm_config_nav id=mm_config_form>
					<h2 area=h1>SSH</h2>
					<x-textarea rows=12 col=mm_pubkey infomode=under
						info="This is the SSH key used to log in as root on all machines.">
					</x-textarea>
					<x-button danger action_name=ssh_key_gen_button_action style="grid-area: ssh_key_gen_button"
						text="Generate new key" icon="fa fa-key">
					</x-button>
					<x-button danger action_name=ssh_key_updates_button_action style="grid-area: ssh_key_updates_button"
						text="Upload key to all machines" icon="fa fa-upload">
					</x-button>
					<div area=h2><hr><h2>MySQL</h2></div>
					<x-passedit col=mysql_root_pass copy_to_clipboard_button></x-passedit>
				</x-form>
			</div>
		</x-switcher>
		<x-split action=tasks fixed_side=second fixed_size=600>
			<x-grid id=mm_tasks_grid rowset_name=tasks save_row_on=input></x-grid>
			<x-pagelist>
				<x-textarea mono console class=x-stretched title="OUT/ERR" id=mm_task_out_textarea nav_id=mm_tasks_grid col=out></x-textarea>
				<x-textarea mono console class=x-stretched title="STDIN" id=mm_task_stdin_textarea nav_id=mm_tasks_grid col=stdin></x-textarea>
			</x-pagelist>
		</x-split>
	</x-vsplit>
</x-split>
]]

js[[

init_xmodule({
	modules: {
		user: {icon: 'user'},
	},
	slots: {
		user: {color: '#99f', icon: 'user'},
	},
	layers: [],
})

// machines gre / refresh button field attrs & action
rowset_field_attrs['machines.refresh'] = {
	type: 'button',
	w: 40,
	button_options: {icon: 'fa fa-sync', bare: true, text: '', load_spin: true},
	action: function(machine) {
		this.load(['', 'machine-info-update', machine])
	},
}

// output textarea auto-scroll.
document.on('mm_task_out_textarea.init', function(e) {
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
document.on('mm_machines_grid.init', function(e) {

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
			text: 'Update github key',
			action: function() {
				let machine = e.focused_row_cell_val('machine')
				if (machine)
					get(['', 'github-key-update', machine], check_notify)
			},
		})

		items.push({
			text: 'Start log server',
			action: function() {
				let machine = e.focused_row_cell_val('machine')
				if (machine)
					get(['', 'log-server-start', machine], check_notify)
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

function ssh_key_gen_button_action() {
	this.load(['', 'ssh-key-gen'], check_notify)
}

function ssh_key_updates_button_action() {
	this.load(['', 'ssh-key-update'], check_notify)
}

function deploy_button_action() {
	let deploy = mm_deploys_grid.focused_row_cell_val('deploy')
	this.load(['', 'deploy', deploy], check_notify)
}

function deploy_remove_button_action() {
	let deploy = mm_deploys_grid.focused_row_cell_val('deploy')
	this.load(['', 'deploy-remove', deploy], check_notify)
}
]]

rowset.providers = sql_rowset{
	select = [[
		select
			provider,
			website,
			note,
			pos,
			unix_timestamp(ctime) as ctime
		from
			provider
	]],
	pk = 'provider',
	field_attrs = {
		website = {type = 'url'},
	},
	insert_row = function(self, row)
		insert_row('provider', row, 'provider website note pos')
	end,
	update_row = function(self, row)
		update_row('provider', row, 'provider website note pos')
	end,
	delete_row = function(self, row)
		delete_row('provider', row)
	end,
}

rowset.machines = sql_rowset{
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
			unix_timestamp(last_seen) as last_seen,
			cpu,
			cores,
			ram_gb,
			ram_free_gb,
			hdd_gb,
			hdd_free_gb,
			os_ver,
			mysql_ver,
			unix_timestamp(ctime) as ctime
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
		last_seen   = {readonly = true, type = 'timestamp'},
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
		insert_row('machine', row, 'machine provider location public_ip local_ip admin_page pos')
		cp(mm.keyfile(), mm.keyfile(row.machine))
		cp(mm.ppkfile(), mm.ppkfile(row.machine))
	end,
	update_row = function(self, row)
		update_row('machine', row, 'machine provider location public_ip local_ip admin_page pos')
		local m1 = row.machine
		local m0 = row['machine:old']
		if m1 and m1 ~= m0 then
			if exists(mm.keyfile(m0)) then mv(mm.keyfile(m0), mm.keyfile(m1)) end
			if exists(mm.ppkfile(m0)) then mv(mm.ppkfile(m0), mm.ppkfile(m1)) end
		end
	end,
	delete_row = function(self, row)
		delete_row('machine', row)
		local m0 = row['machine:old']
		rm(mm.keyfile(m0))
		rm(mm.ppkfile(m0))
	end,
}

rowset.deploys = sql_rowset{
	select = [[
		select
			pos,
			deploy,
			master_deploy,
			machine,
			repo,
			wanted_version,
			deployed_version,
			env,
			status
		from
			deploy
	]],
	pk = 'deploy',
	parent_col = 'master_deploy',
	name_col = 'deploy',
	field_attrs = {
	},
	insert_row = function(self, row)
		row.secret = b64(random_string(46)) --results in a 64 byte string
 		row.mysql_pass = b64(random_string(23)) --results in a 32 byte string
 		insert_row('deploy', row, 'deploy master_deploy machine repo wanted_version env secret mysql_pass pos')
	end,
	update_row = function(self, row)
		update_row('deploy', row, 'deploy master_deploy machine repo wanted_version env pos')
	end,
	delete_row = function(self, row)
		delete_row('deploy', row)
	end,
}

rowset.config = virtual_rowset(function(self, ...)

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

function mm.exec(task_name, cmd, opt)
	opt = opt or empty

	local capture_stdout = opt.capture_stdout ~= false
	local capture_stderr = opt.capture_stderr ~= false and not cx().fake

	local task = mm.task(task_name, opt)

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
			thread(function()
				dbg('mm', 'execin', '%s', opt.stdin)
				local ok, err = p.stdin:write(opt.stdin)
				if not ok then
					task:logerror('stdinwr', '%s', err)
				end
				p.stdin:close() --signal eof
			end)
		end

		if p.stdout then
			thread(function()
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
			end)
		end

		if p.stderr then
			thread(function()
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
			end)
		end

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

	if opt and cx().fake then
		task:free()
	else
		thread(function()
			sleep(10)
			while task.pinned do
				sleep(1)
			end
			task:free()
		end)
	end

	if #task.errors > 0 then
		error(concat(task.errors, '\n'))
	end
	assertf(task.exit_code == 0, 'Task finished with exit code %d', task.exit_code)

	return task
end

--ssh ------------------------------------------------------------------------

function mm.ip(machine)
	local machine = checkarg(str_arg(machine), 'machine required')
	local ip = first_row('select public_ip from machine where machine = ?', machine)
	return checkfound(ip, 'machine not found')
end

--NOTE: the only reason for wanting to use plink on Windows is because ssh's
--`ControlMaster` option (less laggy tasks) doesn't work on Windows but putty
--has an option to share an already-open ssh connection for a new session
--and we could use that maybe (needs some refactoring though).
function mm.ssh(task_name, machine, args, opt)
	opt = opt or {}
	opt.affects = machine
	if Windows and (opt.use_plink or mm.use_plink) then
		--TODO: plink is missing a timeout option (look for a putty fork which has it?).
		return mm.exec(task_name, extend({
			indir(exedir, 'plink'),
			'-ssh',
			'-load', 'mm',
			opt.allocate_tty and '-t' or '-T',
			'-hostkey', mm.ssh_hostkey(machine),
			'-i', mm.ppkfile(machine),
			'-batch',
			'root@'..mm.ip(machine),
		}, args), opt)
	else
		return mm.exec(task_name, extend({
			sshcmd'ssh',
			opt.allocate_tty and '-t' or '-T',
			'-o', 'BatchMode=yes',
			'-o', 'ConnectTimeout=5',
			'-o', 'PreferredAuthentications=publickey',
			'-o', 'UserKnownHostsFile='..mm.known_hosts_file,
			'-i', mm.keyfile(machine),
			'root@'..mm.ip(machine),
		}, args), opt)
	end
end

function mm.sshi(machine, args, opt)
	return mm.ssh(nil, machine, args, update({capture_stdout = false, allocate_tty = true}, opt))
end

--remote bash scripts --------------------------------------------------------

mm.script = {} --{name->script}

mm.script.mm = load(indir(app_dir, 'mm.sh'))

function mm.bash_preprocess(vars)
	return mustache.render(s, vars, nil, nil, nil, nil, proc.esc_unix)
end

function mm.bash_script(s, env, pp_env, included)
	if type(s) == 'function' then
		s = s(env)
	end
	s = s:gsub('\r\n', '\n')
	local function include_force(s, included)
		local s = assertf(mm.script[s], 'no script: %s', s)
		return mm.bash_script(s, nil, mustache_vars, included)
	end
	local function include_force_lf(s, included)
		return '\n'..include_force(s, included)
	end
	local function include(s)
		if included[s] then return '' end
		included[s] = true
		return include_force(s, included)
	end
	local function include_lf(s)
		return '\n'..include(s)
	end
	s = s:gsub( '^[ \t]*#include ([_%w]+)', include)
	s = s:gsub('\n[ \t]*#include ([_%w]+)', include_lf)
	s = s:gsub( '^[ \t]*#include! ([_%w]+)', include_force)
	s = s:gsub('\n[ \t]*#include! ([_%w]+)', include_force_lf)
	if env then
		local t = {}
		for k,v in sortedpairs(env) do
			t[#t+1] = k..'='..proc.quote_arg_unix(tostring(v))
		end
		s = concat(t, '\n')..'\n\n'..s
	end
	if pp_env then
		return mm.bash_preprocess(s, pp_env)
	else
		return s
	end
end

--passing both the script and the script's expected stdin contents through
--ssh's stdin at the same time is only possible due to a ridiculous behavior
--that only bash could have: bash reads its input one-byte-at-a-time and
--stops reading exactly after the `exit` command, not one byte more, so we can
--feed in stdin right after that. worse-is-better at its finest.
function mm.ssh_bash(task_name, machine, script, script_env, opt)
	opt = opt or {}
	local script_env = update({
		DEBUG   = env'DEBUG',
		VERBOSE = env'VERBOSE',
	}, script_env)
	local s = mm.bash_script(script:outdent(), script_env, opt.pp_env, {})
	opt.stdin = '{\n'..s..'\n}; exit'..(opt.stdin or '')
	return mm.ssh(task_name, machine, {'bash', '-s'}, opt)
end

function mm.ssh_mm(task_name, machine, script, ...)
	return mm.ssh_bash(task_name, machine, '#include mm\n\n'..script:outdent(), ...)
end

--tasks ----------------------------------------------------------------------

mm.tasks = {}
mm.tasks_by_id = {}
local last_task_id = 0
local task_events_thread

local task = {}

function mm.task(task_name, opt)
	last_task_id = last_task_id + 1
	local self = inherit({
		id = last_task_id,
		name = task_name,
		affects = opt.affects,
		cmd = cmd,
		start_time = time(),
		duration = 0,
		status = 'new',
		errors = {},
		stdin = opt.stdin,
		_out = {},
		_err = {},
		_outerr = {},
	}, task)
	mm.tasks[self] = true
	mm.tasks_by_id[self.id] = self
	return self
end

function task:free()
	mm.tasks[self] = nil
	mm.tasks_by_id[self.id] = nil
	rowset_changed'tasks'
end

function task:changed()
	self.duration = (self.end_time or time()) - self.start_time
	rowset_changed'tasks'
end

function task:setstatus(s, exit_code)
	self.status = s
	self:changed()
end

function task:finish(exit_code)
	self.end_time = time()
	self.exit_code = exit_code
	self:setstatus'finished'
	local s = self:stdouterr()
	if s ~= '' then
		dbg('mm', 'taskout', '%d,%s\n%s', self.id, self.name, s)
	end
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

function task:stdout    () return concat(self._out) end
function task:stderr    () return concat(self._err) end
function task:stdouterr () return concat(self._outerr) end

rowset.tasks = virtual_rowset(function(self, ...)

	self.fields = {
		{name = 'id'        , type = 'number', w = 20},
		{name = 'pinned'    , type = 'bool'},
		{name = 'name'      , },
		{name = 'affects'   , hint = 'Entities that this task affects'},
		{name = 'status'    , },
		{name = 'start_time', type = 'timestamp'},
		{name = 'duration'  , type = 'number', decimals = 2,  w = 20,
			hint = 'Duration till last change in input, output or status'},
		{name = 'command'   , hidden = true},
		{name = 'stdin'     , hidden = true, maxlen = 16*1024^2},
		{name = 'out'       , hidden = true, maxlen = 16*1024^2},
		{name = 'exit_code' , type = 'number', w = 20},
		{name = 'errors'    , },
	}
	self.pk = 'id'

	local function task_row(task)
		return {
			task.id,
			task.pinned or false,
			task.name,
			task.affects,
			task.status,
			task.start_time,
			task.duration,
			concat(task.cmd, ' '),
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

	function self:load_row(vals)
		local task = mm.tasks_by_id[vals['id:old']]
		return task and task_row(task)
	end

	function self:update_row(vals)
		local task = mm.tasks_by_id[vals['id:old']]
		if not task then return end
		task.pinned = vals.pinned
	end

end)

--command helpers ------------------------------------------------------------

local function checknostderr(task)
	local stderr = task:stderr()
	check500(stderr == '', stderr)
	return task
end

--command: machine-info-update -----------------------------------------------

function mm.machine_info(machine)
	local stdout = mm.ssh_mm('machine_info', machine, [=[

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

	]=]):stdout()
	local t = {last_seen = time()}
	for s in stdout:trim():lines() do
		local k,v = assert(s:match'^%s*(.-)%s+(.*)')
		add(t, k)
		t[k] = v
	end
	return t
end

function cmd.machine_info(machine)
	local t = mm.machine_info(machine)
	for i,k in ipairs(t) do
		print(_('%20s %s', k, t[k]))
	end
end

function mm.machine_info_update(machine)
	t = assert(mm.machine_info(machine))
	t['machine:old'] = machine
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
		machine = :machine:old
	]], t).affected_rows == 1)
	rowset_changed'machines'
end
action.machine_info_update = mm.machine_info_update
cmd.machine_info_update = action.machine_info_update

--command: ssh-hostkey-update ---------------------------------------

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
	save(mm.known_hosts_file, concat(t, '\n'))
end

function mm.ssh_hostkey_update(machine)
	local fp = mm.exec('get_host_fingerprint',
		{sshcmd'ssh-keyscan', '-4', '-T', '2', '-t', 'rsa', mm.ip(machine)}):stdout()
	assert(update_row('machine', {fingerprint = fp, ['machine:old'] = machine}, 'fingerprint').affected_rows == 1)
	mm.gen_known_hosts_file()
end

function action.ssh_hostkey_update(machine)
	mm.ssh_hostkey_update(machine)
	out_json{machine = machine, notify = 'Host fingerprint updated for '..machine}
end
cmd.ssh_hostkey_update = action.ssh_hostkey_update

--command: ssh-key-gen -------------------------------------------------------

function mm.ssh_key_gen()
	rm(mm.keyfile())
	exec(sshcmd'ssh-keygen'..' -f %s -t rsa -b 2048 -C "mm" -q -N ""', mm.keyfile())
	rm(mm.keyfile()..'.pub') --we'll compute it every time.
	mm.ssh_key_fix_perms()
	mm.ssh_key_gen_ppk()
	rowset_changed'config'
	query'update machine set ssh_key_ok = 0'
	rowset_changed'machine'
end

function action.ssh_key_gen()
	mm.ssh_key_gen()
	out_json{notify = 'SSH key generated'}
end
cmd.ssh_key_gen = action.ssh_key_gen

--command: pubkey ------------------------------------------------------------

--for manual updating via `curl mm.allegory.ro/pubkey/MACHINE >> authroized_keys`.
function action.ssh_pubkey(machine)
	setmime'txt'
	out(mm.pubkey(machine)..'\n')
end
cmd.ssh_pubkey = action.ssh_pubkey

--command: ssh-key-update ----------------------------------------------------

function mm.each_machine(f)
	for _, machine in each_row_vals'select machine from machine' do
		thread(f, machine)
	end
end

function mm.ssh_key_update(machine)
	if not machine then
		mm.each_machine(mm.ssh_key_update)
		return true
	end

	note('mm', 'upd-key', '%s', machine)
	local pubkey = mm.pubkey()
	local stored_pubkey = mm.ssh_mm('ssh_key_update', machine, [=[
		has_mysql && mysql_update_root_pass "$mysql_root_pass"
		ssh_update_pubkey mm "$pubkey"
		user_lock_pass root
		ssh_pubkey mm
	]=], {
		pubkey = pubkey,
		mysql_root_pass = mm.mysql_root_pass(),
	}):stdout():trim()

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
	check500(mm.ssh_key_update(machine))
	out_json{machine = machine,
		notify = machine
			and 'SSH key updated for '..machine
			or 'SSH key update tasks created',
	}
end
cmd.ssh_key_update = action.ssh_key_update

function mm.ssh_key_check(machine)
	local host_pubkey = mm.ssh_mm('ssh_key_check', machine, [[
		ssh_pubkey mm
	]]):stdout():trim()
	return host_pubkey == mm.pubkey()
end

function action.ssh_key_check(machine)
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
cmd.ssh_key_check = action.ssh_key_check

--command: github-key-update -------------------------------------------------

function mm.github_key_update(machine)
	mm.ssh_mm('github_key_update', machine, [[
		ssh_hostkey_update github.com "$github_fingerprint"
		ssh_host_key_update github.com mm_github "$github_key" moving_ip
		must cd /home
		for user in *; do
			[ -d /home/$user/.ssh ] && \
				HOME=/home/$user USER=$user ssh_host_key_update github.com mm_github "$github_key" moving_ip
		done
	]], {
		github_fingerprint = mm.github_fingerprint,
		github_key = mm.github_key,
	})
end

function action.github_key_update(machine)
	if not machine then
		mm.each_machine(mm.github_key_update)
		return true
	end
	mm.github_key_update(machine)
	out_json{machine = machine, notify = 'Github key updated'}
end
cmd.github_key_update = action.github_key_update

--command: machine-prepare ---------------------------------------------------

function mm.machine_prepare(machine)
	mm.ssh_mm('machine_prepare', machine, [=[

		apt_get_install sudo htop mc git gnupg2 curl lsb-release

		# ---------------------------------------------------------------------

		git_install_git_up

		git_config_user mm@allegory.ro "Many Machines"

		ssh_hostkey_update github.com "$github_fingerprint"
		ssh_host_key_update github.com mm_github "$github_key" moving_ip

		mgit_install

		# ---------------------------------------------------------------------

		percona_pxc_install

		cat << 'EOF' > /etc/mysql/mysql.conf.d/z.cnf
[mysqld]
log_bin_trust_function_creators = 1
EOF

		must service mysql start

		mysql_update_root_pass "$mysql_root_pass"

		say "All done."

	]=], {
		github_fingerprint = mm.github_fingerprint,
		github_key = mm.github_key,
		mysql_root_pass = mm.mysql_root_pass(),
	})
end

function action.machine_prepare(machine)
	mm.machine_prepare(machine)
	out_json{machine = machine, notify = 'Machine prepared: '..machine}
end
cmd.machine_prepare = action.machine_prepare

--command: deploy ------------------------------------------------------------

function mm.repo_app_name(repo)
	return repo:gsub('%.git$', ''):match'/(.-)$'
end

function mm.deploy(deploy)

	deploy = checkarg(str_arg(deploy), 'deploy required')

	local d = first_row([[
		select
			d.machine,
			d.repo,
			d.wanted_version,
			d.env,
			d.mysql_pass,
			d.secret
		from
			deploy d
		where
			deploy = ?
	]], deploy)

	local app = mm.repo_app_name(d.repo)

	mm.ssh_mm('deploy', d.machine, [[

		if [ ! -d "/home/$deploy" ]; then

			must user_create $deploy
			must user_lock_pass $deploy

			HOME=/home/$deploy USER=$deploy ssh_host_key_update \
				github.com mm_github "$github_key" moving_ip

			must mysql_create_db $deploy
			must mysql_create_user localhost $deploy "$mysql_pass"
			must mysql_grant_user  localhost $deploy $deploy

			must run_as "$deploy" << EOF

cd /home/$deploy || exit
opt=; [ "$version" ] && opt="-b $version"
git clone $opt $repo $app

EOF

		else

			must run_as "$deploy" << EOF

cd /home/$deploy/$app || { echo "Could not cd to $app dir" >&2; exit 1; }

if [ -d .mgit ]; then # repo converted itself to mgit
	mgit clone "$app=$version"
else
	git fetch || exit
	if [ "$version" ]; then
		git -c advice.detachedHead=false checkout "$version"
	else
		git checkout -B master origin/master
	fi
fi

EOF
		fi

		must sudo -u "$deploy" \
			DEBUG="$DEBUG" \
			VERBOSE="$VERBOSE" \
			DEPLOY="$deploy" \
			ENV="$env" \
			VERSION="$version" \
			MYSQL_DB="$deploy" \
			MYSQL_USER="$deploy" \
			MYSQL_PASS="$mysql_pass" \
			SECRET="$secret" \
			-s -- << EOF

cd /home/$deploy/$app || exit
./$app deploy

EOF

	]], {
		deploy = deploy,
		repo = d.repo,
		app = app,
		version = d.wanted_version,
		env = d.env or 'dev',
		secret = d.secret,
		mysql_pass = d.mysql_pass,
		github_key = mm.github_key,
	})

	update_row('deploy', {
		deployed_version = d.wanted_version,
		['deploy:old'] = deploy,
	}, 'deployed_version')

end

action.deploy = mm.deploy
cmd.deploy = action.deploy

function mm.deploy_remove(deploy)
	deploy = checkarg(str_arg(deploy), 'deploy required')
	local d = first_row('select repo, machine from deploy where deploy = ?', deploy)
	local app = mm.repo_app_name(d.repo)

	mm.ssh_mm('deploy_remove', d.machine, [[

		[ -d /home/$deploy/$app ] && (
			must cd /home/$deploy/$app
			run ./$app stop
		)

		mysql_drop_db $deploy
		mysql_drop_user localhost $deploy

		user_remove $deploy

		say "All done."

	]], {
		app = app,
		deploy = deploy,
	})
end
action.deploy_remove = mm.deploy_remove
cmd.deploy_remove = action.deploy_remove

--remote logging -------------------------------------------------------------

mm.log_port = 5555
mm.log_local_port1 = 6000
mm.log_queue_size = 10000

function mm.alloc_log_tunnel_ports()
	local lport1 = mm.log_local_port1
	local lport2 = first_row'select max(log_port) from machine where log_port is not null' or lport1-1
	for i, machine in each_row_vals'select machine from machine where log_port is null' do
		update_row('machine', {
			log_port = lport2 + i,
			['machine:old'] = machine,
		}, 'log_port')
	end
end

function mm.logport(machine)
	machine = checkarg(str_arg(machine))
	return first_row('select log_port from machine where machine = ?', machine)
end

mm.log_server_tasks = {}
mm.deploy_logs = {}

function mm.log_server_start(machine)
	machine = checkarg(str_arg(machine))
	if not mm.log_server_tasks[machine] then
		local lport = mm.logport(machine)
		if not lport then
			mm.alloc_log_tunnel_ports()
			lport = assert(mm.logport(machine))
		end
		thread(function()
			mm.tunnel('log_tunnel', machine,
				lport..':'..mm.log_port, {reverse_tunnel = true})
			note('mm', 'TUNNEL', '%d <- %s:%d', lport, machine, mm.logport)
		end)
		local task = mm.task('log_server', {affects = machine})
		thread(function()
			local tcp = assert(sock.tcp())
			assert(tcp:setopt('reuseaddr', true))
			assert(tcp:listen('127.0.0.1', lport))
			note('mm', 'LISTEN', '127.0.0.1:%d', lport)
			task:setstatus'running'
			while not task.stop do
				local ctcp = assert(tcp:accept())
				thread(function()
					note('mm', 'ACCEPT', '%d <- %s', lport, machine)
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
					ctcp:close()
				end)
			end
			task:free()
		end)
		mm.log_server_tasks[machine] = task
	end
end

action.log_server_start = mm.log_server_start

rowset.deploy_log = virtual_rowset(function(self)
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

function action.testlog(machine)
	mm.ssh_mm('testlog', machine, [[
		must run_as sp1 << EOF
cd /home/sp1/sp || exit 1
./sp testlog || exit 1
EOF
	]])
	--for _, machine, lport in ech_row_vals'select machine, log_port from machine' do
	--end
end

cmd.log_server = mm.log_server

--backups --------------------------------------------------------------------

function cmd.schema_version(deploy)
	deploy = checkarg(str_arg(deploy))
	local machine = checkarg((first_row('select machine from deploy where deploy = ?', deploy)))
	local ver = tonumber(mm.ssh_mm('schema_version', machine, [[
		schema_version ]]..deploy):stdout():trim())
	print(ver)
end

rowset.backups = sql_rowset{
	select = [[
		select
			b.bkp        ,
			b.parent_bkp ,
			b.deploy     ,
			unix_timestamp(b.start_time) as start_time,
			b.duration   ,
			b.size       ,
			b.checksum   ,
			b.name
		from bkp b
	]],
	where_all = 'b.deploy in (:param:filter)',
	pk = 'bkp',
	field_attrs = {
		start_time = {type = 'timestamp', to_lua = timeago},
	},
	parent_col = 'parent_bkp',
	insert_row = function(self, row)
		local machine = checkarg(first_row('select machine from deploy where deploy = ?', row.deploy))
 		row.bkp = insert_row('bkp', row, 'parent_bkp deploy name')
		row.start_time = time()
		query('update bkp set start_time = from_unixtime(?) where bkp = ?', row.start_time, row.bkp)
		thread(function()
			mm.ssh_mm('backup', machine, [[
				xbkp_backup "$deploy" "$bkp" "$parent_bkp"
			]], {deploy = row.deploy, bkp = row.bkp, parent_bkp = parent_bkp})
			update_row('bkp', {['bkp:old'] = row.bkp, duration = time() - row.start_time}, 'duration')
			rowset_changed'backups'
		end)
	end,
	update_row = function(self, row)
		update_row('bkp', row, 'name')
	end,
	delete_row = function(self, row)
		local bkp = row['bkp:old']
		local deploy = checkarg(first_row('select deploy from bkp where bkp = ?', bkp))
 		local machine = checkarg(first_row('select machine from deploy where deploy = ?', deploy))
		mm.ssh_mm('backup_remove '..bkp, machine, [[
			must xbkp_remove "$deploy" "$bkp"
		]], {deploy = deploy, bkp = bkp})
		delete_row('bkp', row)
	end,
}

--remote access tools --------------------------------------------------------

function cmd.machines()
	local to_lua = require'mysql_client'.to_lua
	pqr(query({
		compact=1,
		field_attrs = {last_seen = {to_lua = glue.timeago}},
	}, [[
		select
			machine,
			public_ip,
			unix_timestamp(last_seen) as last_seen,
			cores,
			ram_gb, ram_free_gb,
			hdd_gb, hdd_free_gb,
			cpu,
			os_ver,
			mysql_ver,
			unix_timestamp(ctime) as ctime
		from machine
		order by pos, ctime
]]))
end
cmd.ls = cmd.machines

function cmd.ssh(machine, cmd)
	mm.sshi(machine, cmd and {'bash', '-c', proc.quote_arg_unix(cmd)})
end

function wincmd.plink(machine, cmd)
	mm.sshi(machine, cmd and {'bash', '-c', proc.quote_arg_unix(cmd)}, {use_plink = true})
end

function cmd.ssh_all(command)
	command = checkarg(str_arg(command), 'command expected')
	for _, machine in each_row_vals'select machine from machine' do
		thread(function()
			print('Executing on '..machine..'...')
			mm.ssh(nil, machine, command and {'bash', '-c', (command:gsub(' ', '\\ '))})
		end)
	end
end

--TIP: make a putty session called `mm` where you set the window size,
--uncheck "warn on close" and whatever else you need to make putty comfortable.
function wincmd.putty(machine)
	local ip = mm.ip(machine)
	proc.exec(indir(exedir, 'putty')..' -load mm -i '..mm.ppkfile(machine)..' root@'..ip):forget()
end

function mm.tunnel(task_name, machine, ports, opt)
	local args = {'-N'}
	ports = checkarg(str_arg(ports), 'Usage: mm tunnel MACHINE LPORT1[:RPORT1],...')
	for ports in ports:gmatch'([^,]+)' do
		local rport, lport = ports:match'(.-):(.*)'
		add(args, opt and opt.reverse_tunnel and '-R' or '-L')
		add(args, '127.0.0.1:'..(lport or ports)..':127.0.0.1:'..(rport or ports))
	end
	return mm.ssh(task_name, machine, args,
		opt and opt.interactive and update({capture_stdout = false, allocate_tty = true}, opt))
end

function cmd.tunnel(machine, ports)
	return mm.tunnel(nil, machine, ports, {interactive = true})
end
function cmd.rtunnel(machine, ports)
	return mm.tunnel(nil, machine, ports, {interactive = true, reverse_tunnel = true})
end

local function censor_mysql_pwd(s)
	return s:gsub('MYSQL_PWD=[^%s]+', 'MYSQL_PWD=censored')
end
function cmd.mysql(machine, sql)
	local args = {'MYSQL_PWD='..mm.mysql_root_pass(machine),
		'mysql', '-u', 'root', '-h', 'localhost'}
	if sql then append(args, '-e', proc.quote_arg_unix(sql)) end
	logging.censor.mysql_pwd = censor_mysql_pwd
	mm.sshi(machine, args)
	logging.censor.mysql_pwd = nil
end

--TODO: `sshfs.exe` is buggy in background mode: it kills itself when parent cmd is closed.
function mm.mount(machine, rem_path, drive, bg)
	if win then
		drive = drive or 'S'
		rem_path = rem_path or '/'
		machine = str_arg(machine)
		local cmd =
			'"'..indir(sshfs_dir, 'sshfs.exe')..'"'..
			' root@'..mm.ip(machine)..':'..rem_path..' '..drive..':'..
			(bg and '' or ' -f')..
			--' -odebug'.. --good stuff (implies -f)
			--these were copy-pasted from sshfs-win manager.
			' -oidmap=user -ouid=-1 -ogid=-1 -oumask=000 -ocreate_umask=000'..
			' -omax_readahead=1GB -oallow_other -olarge_read -okernel_cache -ofollow_symlinks'..
			--only cygwin ssh works. the builtin Windows ssh doesn't, nor does our msys version.
			' -ossh_command='..path.sep(indir(sshfs_dir, 'ssh'), nil, '/')..
			' -oBatchMode=yes'..
			' -oRequestTTY=no'..
			' -oPreferredAuthentications=publickey'..
			' -oUserKnownHostsFile='..path.sep(mm.known_hosts_file, nil, '/')..
			' -oIdentityFile='..path.sep(mm.keyfile(machine), nil, '/')
		if bg then
			exec(cmd)
		else
			mm.exec('sshfs '..drive..':', cmd)
		end
	else
		NYI'mount'
	end
end

cmd.mount = mm.mount

function cmd.mount_bg(machine, drive, rem_path)
	return mm.mount(machine, drive, rem_path, true)
end

function cmd.mount_kill_all()
	if win then
		exec'taskkill /f /im sshfs.exe'
	else
		NYI'mount_kill_all'
	end
end

function cmd.deploys()
	local to_lua = require'mysql_client'.to_lua
	pqr(query({
		compact=1,
		field_attrs = {},
	}, [[
		select
			deploy,
			machine,
			repo,
			wanted_version,
			deployed_version,
			env,
			status,
			unix_timestamp(ctime) as ctime
		from deploy
		order by pos, ctime
	]]))
end

webb.run(function()
	--add_column('machine', 'log_port', 'int after hdd_free_gb')
end)

return mm:run(...)
