
require'$daemon'
require'xmodule'

local b64 = require'libb64'
local proc = require'proc'
local sock = require'sock'
local xapp = require'xapp'
local mustache = require'mustache'

local ssh_dir = exedir

if Linux then
	var_dir = '/root/mm-var'
end
local mm = xapp(daemon'mm')

--tools ----------------------------------------------------------------------

function mm.keyfile(machine, suffix, ext)
	local file = 'mm'..(machine and '-'..machine or '')
		..(suffix and '.'..suffix or '')..'.'..(ext or 'key')
	return indir(var_dir, file)
end

function mm.ppkfile(machine, suffix)
	return mm.keyfile(machine, suffix, 'ppk')
end

function mm.pubkey(machine, prefix)
	return readpipe(indir(ssh_dir, 'ssh-keygen')..' -y -f "'..mm.keyfile(machine, prefix)..'"'):trim()
end

--NOTE: this is a `fix-perms.cmd` script to put in your var dir and run
--in case you get the incredibly stupid "perms are too open" error from ssh.
--[[
@echo off
for %%f in (.\*.key) do (
	Icacls %%f /c /t /Inheritance:d
	Icacls %%f /c /t /Grant %UserName%:F
	TakeOwn /F %%f
	Icacls %%f /c /t /Grant:r %UserName%:F
	Icacls %%f /c /t /Remove:g "Authenticated Users" BUILTIN\Administrators BUILTIN Everyone System Users
	Icacls %%f
)
]]

function mm.ssh_gen_ppk(machine, suffix)
	local key = mm.keyfile(machine, suffix)
	local ppk = mm.ppkfile(machine, suffix)
	exec(indir(exedir, 'winscp.com')..' /keygen %s /output=%s', key, ppk)
end
cmd.ssh_gen_ppk = mm.ssh_gen_ppk

function mm.mysql_root_pass(machine) --last line of the private key
	local s = load(mm.keyfile(machine))
		:gsub('%-+.-PRIVATE%s+KEY%-+', ''):gsub('[\r\n]', ''):trim():sub(-32)
	assert(#s == 32)
	return s
end

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

	create_schema()

	auth_create_tables()

	query[[
	$table machine (
		machine     $strpk,
		public_ip   $strid,
		local_ip    $strid,
		fingerprint $b64key,
		ssh_key_ok  $bool,
		admin_page  $url,
		last_seen   timestamp,
		os_ver      $name,
		mysql_ver   $name,
		cpu         $name,
		cores       smallint,
		ram_gb      double,
		ram_free_gb double,
		hdd_gb      double,
		hdd_free_gb double,
		pos         $pos,
		ctime       $ctime
	);
	]]

	query[[
	$table deploy (
		deploy      $strpk,
		machine     $strid not null, $fk(deploy, machine),
		repo        $url not null,
		version     $strid,
		env         $strid not null,
		secret      $b64key, --multi-purpose
		status      $strid,
		pos         $pos
	);
	]]

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

#config_form.maxcols1 {
	max-width: 400px;
	grid-template-areas:
		"h1"
		"mm_"
		"ssh_gen_key_button"
		"ssh_update_keys_button"
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
		<x-listbox id=actions_listbox>
			<div action=machines>Machines</div>
			<div action=deploys>Deployments</div>
			<div action=config>Configuration</div>
		</x-listbox>
	</div>
	<x-vsplit fixed_side=second>
		<x-switcher nav_id=actions_listbox>
			<x-vsplit action=machines>
				<x-grid id=machines_grid rowset_name=machines></x-grid>
			</x-vsplit>
			<x-vsplit action=deploys>
				<x-grid id=deploys_grid rowset_name=deploys></x-grid>
				<div>
					<x-button action_name=deploy_button_action text="Deploy"></x-button>
				</div>
			</x-vsplit>
			<div action=config class="x-container x-flex x-stretched" style="justify-content: center">
				<x-bare-nav id=config_nav rowset_name=config></x-bare-nav>
				<x-form nav_id=config_nav id=config_form>
					<h2 area=h1>SSH</h2>
					<x-textarea rows=12 col=mm_pubkey infomode=under
						info="This is the SSH key used to log in as root on all machines.">
					</x-textarea>
					<x-button danger action_name=ssh_gen_key_button_action style="grid-area: ssh_gen_key_button"
						text="Generate new key" icon="fa fa-key">
					</x-button>
					<x-button danger action_name=ssh_update_keys_button_action style="grid-area: ssh_update_keys_button"
						text="Upload key to all machines" icon="fa fa-upload">
					</x-button>
					<div area=h2><hr><h2>MySQL</h2></div>
					<x-passedit col=mysql_root_pass copy_to_clipboard_button></x-passedit>
				</x-form>
			</div>
		</x-switcher>
		<x-split action=tasks fixed_side=second fixed_size=600>
			<x-grid id=tasks_grid rowset_name=tasks save_row_on=input></x-grid>
			<x-pagelist>
				<x-textarea mono console class=x-stretched title="OUT/ERR" id=task_out_textarea nav_id=tasks_grid col=out></x-textarea>
				<x-textarea mono console class=x-stretched title="STDIN" id=task_stdin_textarea nav_id=tasks_grid col=stdin></x-textarea>
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
		this.load(['', 'machine-update-info', machine])
	},
}

// output textarea auto-scroll.
document.on('task_out_textarea.init', function(e) {
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
document.on('machines_grid.init', function(e) {

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
					get(['', 'ssh-update-host-fingerprint', machine], check_notify)
			},
		})

		ssh_items.push({
			text: 'Update key',
			action: function() {
				let machine = e.focused_row_cell_val('machine')
				if (machine)get(['', 'ssh-update-key', machine], check_notify)
			},
		})

		ssh_items.push({
			text: 'Check key',
			action: function() {
				let machine = e.focused_row_cell_val('machine')
				if (machine)get(['', 'ssh-check-key', machine], check_notify)
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
			text: 'Update Github key',
			action: function() {
				let machine = e.focused_row_cell_val('machine')
				if (machine)
					get(['', 'github-update-key', machine], check_notify)
			},
		})

	})

})

function ssh_gen_key_button_action() {
	this.load(['', 'ssh-gen-key'], check_notify)
}

function ssh_update_keys_button_action() {
	this.load(['', 'ssh-update-key'], check_notify)
}

function deploy_button_action() {
	let deploy = deploys_grid.focused_row_cell_val('deploy')
	this.load(['', 'deploy', deploy], check_notify)
}
]]

rowset.machines = sql_rowset{
	select = [[
		select
			pos,
			machine as refresh,
			machine,
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
			mysql_ver
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
		insert_row('machine', row, 'machine public_ip local_ip admin_page pos')
	end,
	update_row = function(self, row)
		update_row('machine', row, 'machine public_ip local_ip admin_page pos')
		local m1 = row.machine
		local m0 = row['machine:old']
		if m1 and m1 ~= m0 then
			if exists(mm.keyfile(m0)) then mv(mm.keyfile(m0), mm.keyfile(m1)) end
			if exists(mm.ppkfile(m0)) then mv(mm.ppkfile(m0), mm.ppkfile(m1)) end
		end
	end,
	delete_row = function(self, row)
		delete_row('machine', row, 'machine')
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
			machine,
			repo,
			version,
			env,
			status
		from
			deploy
	]],
	pk = 'deploy',
	field_attrs = {
	},
	insert_row = function(self, row)
		row.secret = b64.encode(random_string(46)) --results in a 64 byte string
 		insert_row('deploy', row, 'deploy machine repo version env secret pos')
	end,
	update_row = function(self, row)
		update_row('deploy', row, 'deploy machine repo version env pos')
	end,
	delete_row = function(self, row)
		delete_row('deploy', row, 'deploy')
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
		env = opt.env,
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

	return task
end

--ssh ------------------------------------------------------------------------

function mm.ip(machine)
	local machine = checkarg(str_arg(machine), 'machine required')
	local ip = first_row('select public_ip from machine where machine = ?', machine)
	return checkfound(ip, 'machine not found')
end

function mm.ssh(task_name, machine, args, opt)
	return mm.exec(task_name, extend({
			indir(ssh_dir, 'ssh'),
			opt.allocate_tty and '-t' or '-T',
			'-o', 'BatchMode=yes',
			'-o', 'UserKnownHostsFile='..mm.known_hosts_file,
			'-o', 'ConnectTimeout=2',
			'-i', mm.keyfile(machine),
			'root@'..mm.ip(machine),
		}, args), opt)
end

function mm.sshi(task_name, machine, args, opt)
	return mm.ssh(task_name, machine, args, update({capture_stdout = false, allocate_tty = true}, opt))
end

--remote bash scripts --------------------------------------------------------

mm.script = {} --{name->script}

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
function mm.ssh_bash(task_name, machine, script, env, opt)
	opt = opt or {}
	local env = update({
		MACHINE = machine, --for any script that wants to know
		DEBUG = logging.debug or nil, --for die script
	}, env)
	local s = mm.bash_script(script:outdent(), env, opt.pp, {})
	opt.stdin = '{\n'..s..'\n}; exit'..(opt.stdin or '')
	return mm.ssh(task_name, machine, {'bash', '-s'}, opt)
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

--bash utils -----------------------------------------------------------------

--die: basic vocabulary for flow control and progress/error reporting for bash.
--these functions are influenced by QUIET and DEBUG env vars.
--see https://github.com/capr/die for how to use.
mm.script.die = [[
say()   { [ "$QUIET" ] || echo "$@" >&2; }
error() { say -n "ERROR: "; say "$@"; return 1; }
die()   { echo -n "EXIT: " >&2; echo "$@" >&2; exit 1; }
debug() { [ -z "$DEBUG" ] || echo "$@" >&2; }
run()   { debug -n "EXEC: $@ "; "$@"; local ret=$?; debug "[$ret]"; return $ret; }
must()  { debug -n "MUST: $@ "; "$@"; local ret=$?; debug "[$ret]"; [ $ret == 0 ] || die "$@ [$ret]"; }
]]

mm.script.utils = [[

#include die

ssh_update_host_fingerprint() { # host fingerprint
	say "Updating SSH host fingerprint for host '$1' (/etc/ssh)..."
	local kh=/etc/ssh/ssh_known_hosts
	run ssh-keygen -R "$1" -f $kh
	must printf "%s\n" "$2" >> $kh
	must chmod 400 $kh
}

ssh_update_host() { # host keyname
	say "Assigning SSH key '$2' to host '$1' ($HOME)..."
	local CONFIG=$HOME/.ssh/config
	sed < $CONFIG "/^$/d;s/Host /$NL&/" | sed '/^Host '"$1"'$/,/^$/d;' > $CONFIG
	cat << EOF >> $CONFIG
Host $1
	HostName $1
	IdentityFile $HOME/.ssh/${2}.id_rsa
EOF
}

ssh_update_key() { # keyname key
	say "Updating SSH key '$1' ($HOME)..."
	local idf=$HOME/.ssh/${1}.id_rsa
	must printf "%s" "$2" > $idf
	must chmod 400 $idf
}

ssh_update_host_key() { # host keyname key
	ssh_update_key "$2" "$3"
	ssh_update_host "$1" "$2"
}

ssh_update_pubkey() { # keyname key
	say "Updating SSH public key '$1'..."
	local ak=$HOME/.ssh/authorized_keys
	must mkdir -p $HOME/.ssh
	[ -f $ak ] && must sed -i "/ $1/d" $ak
	must printf "%s" "$2" >> $ak
	must chmod 400 $ak
}

ssh_pubkey() { # keyname
	cat $HOME/.ssh/authorized_keys | grep " $1\$"
}

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

user_create() { # user
	say "Creating user '$1'..."
	must useradd -m $1
}

user_lock_pass() { # user
	say "Locking password for user '$1'..."
	must passwd -l $1 >&2
}

query() {
	[ "$MYSQL_ROOT_PASS" ] || die "\$MYSQL_ROOT_PASS not set."
	MYSQL_PWD="$MYSQL_ROOT_PASS" must mysql -N -B -u root -e "$1"
}

mysql_create_user() { # host user pass
	say "Creating mysql user '$2@$1'..."
	must query "
		create user '$2'@'$1' identified with mysql_native_password by '$3';
		flush privileges;
	"
}

mysql_update_pass() { # host user pass
	say "Updating MySQL password for user '$2@$1'..."
	must query "
		alter user '$2'@'$1' identified with mysql_native_password by '$3';
		flush privileges;
	"
}

mysql_create_schema() { # schema
	say "Creating mysql schema '$1'..."
	must query "
		create database if not exists $1
		character set utf8mb4 collate utf8mb4_unicode_ci;
	"
}

mysql_grant_user() { # host user schema
	must query "
		grant all privileges on $3.* to '$2'@'$1';
		flush privileges;
	"
}

ubuntu_install_packages() { # packages
	say "Installing Ubuntu packages '$1'..."
	run apt-get -y update
	run apt-get -y install $1
}

mgit_install() {
	must mkdir -p /opt
	must cd /opt
	must git clone git@github.com:capr/multigit.git mgit
	must ln -sf /opt/mgit/mgit /usr/local/bin/mgit
}

]]

--command: machine-update-info -----------------------------------------------

function mm.machine_get_info(machine)
	local stdout = mm.ssh_bash('machine_get_info', machine, [=[

		#include utils

		echo "os_ver        $(lsb_release -sd)"
		echo "mysql_ver     $(which mysql >/dev/null && query 'select version();')"
		echo "cpu           $(lscpu | sed -n 's/^Model name:\s*\(.*\)/\1/p')"
							cps="$(lscpu | sed -n 's/^Core(s) per socket:\s*\(.*\)/\1/p')"
					  sockets="$(lscpu | sed -n 's/^Socket(s):\s*\(.*\)/\1/p')"
		echo "cores         $(expr $sockets \* $cps)"
		echo "ram_gb        $(cat /proc/meminfo | awk '/MemTotal/ {$2/=1024*1024; printf "%.2f",$2}')"
		echo "ram_free_gb   $(cat /proc/meminfo | awk '/MemAvailable/ {$2/=1024*1024; printf "%.2f",$2}')"
		echo "hdd_gb        $(df -l | awk '$6=="/" {printf "%.2f",$2/(1024*1024)}')"
		echo "hdd_free_gb   $(df -l | awk '$6=="/" {printf "%.2f",$4/(1024*1024)}')"

	]=], {
		MYSQL_ROOT_PASS = mm.mysql_root_pass(machine),
	}):stdout()
	local t = {last_seen = time()}
	for s in stdout:trim():lines() do
		local k,v = assert(s:match'^(.-)%s+(.*)')
		t[k] = v
	end
	return t
end

function mm.machine_update_info(machine)
	t = assert(mm.machine_get_info(machine))
	t['machine:old'] = machine
	assert(update_row('machine', t, [[
		os_ver
		mysql_ver
		cpu
		cores
		ram_gb
		ram_free_gb
		hdd_gb
		hdd_free_gb
		last_seen
	]]).affected_rows == 1)
	rowset_changed'machines'
end

action.machine_update_info = mm.machine_update_info
cmd.machine_update_info = action.machine_update_info

--command: ssh-update-host-fingerprint ---------------------------------------

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

function mm.ssh_update_host_fingerprint(machine)
	local fp = mm.exec('get_host_fingerprint',
		{indir(ssh_dir, 'ssh-keyscan'), '-4', '-t', 'rsa', '-H', mm.ip(machine)}):stdout()
	assert(update_row('machine', {fingerprint = fp, ['machine:old'] = machine}, 'fingerprint').affected_rows == 1)
	mm.gen_known_hosts_file()
end

function action.ssh_update_host_fingerprint(machine)
	mm.ssh_update_host_fingerprint(machine)
	out_json{machine = machine, notify = 'Host fingerprint updated for '..machine}
end
cmd.ssh_update_host_fingerprint = action.ssh_update_host_fingerprint

--command: ssh-gen-key -------------------------------------------------------

function mm.ssh_gen_key()
	rm(mm.keyfile())
	exec(indir(ssh_dir, 'ssh-keygen')..' -f %s -t rsa -b 2048 -C "mm" -q -N ""', mm.keyfile())
	rm(mm.keyfile()..'.pub') --we'll compute it every time.
	mm.ssh_gen_ppk()
	rowset_changed'config'
	query'update machine set ssh_key_ok = 0'
	rowset_changed'machine'
end

function action.ssh_gen_key()
	mm.ssh_gen_key()
	out_json{notify = 'SSH key generated'}
end
cmd.ssh_gen_key = action.ssh_gen_key

--command: pubkey ------------------------------------------------------------

--for manual updating via `curl mm.allegory.ro/pubkey/MACHINE >> authroized_keys`.
function action.ssh_pubkey(machine)
	setmime'txt'
	out(mm.pubkey(machine)..'\n')
end
cmd.ssh_pubkey = action.ssh_pubkey

--command: ssh-update-key ----------------------------------------------------

function mm.each_machine(f)
	for _, machine in each_row_vals'select machine from machine' do
		thread(f, machine)
	end
end

function mm.ssh_update_key(machine)
	if not machine then
		mm.each_machine(mm.ssh_update_key)
		return true
	end

	note('mm', 'upd-key', '%s', machine)
	local pubkey = mm.pubkey()
	local old_mysql_root_pass = mm.mysql_root_pass(machine)
	local stored_pubkey = mm.ssh_bash('ssh_update_key', machine, [=[
		#include utils
		which mysql >/dev/null && \
			mysql_update_pass localhost root "$mysql_root_pass"
		ssh_update_pubkey mm "$pubkey"
		user_lock_pass root
		ssh_pubkey mm
	]=], {
		pubkey = pubkey,
		mysql_root_pass = mm.mysql_root_pass(),
		MYSQL_ROOT_PASS = old_mysql_root_pass,
	}):stdout():trim()

	if stored_pubkey ~= pubkey then
		return nil, 'Public key NOT updated'
	end

	cp(mm.keyfile(), mm.keyfile(machine))
	cp(mm.ppkfile(), mm.ppkfile(machine))

	update_row('machine', {ssh_key_ok = true, ['machine:old'] = machine}, 'ssh_key_ok')
	rowset_changed'machines'

	return true
end

function action.ssh_update_key(machine)
	check500(mm.ssh_update_key(machine))
	out_json{machine = machine,
		notify = machine
			and 'SSH key updated for '..machine
			or 'SSH key update tasks created',
	}
end
cmd.ssh_update_key = action.ssh_update_key

function mm.ssh_check_key(machine)
	local host_pubkey = mm.ssh_bash('ssh_check_key', machine, [[
		#include utils
		ssh_pubkey mm
	]]):stdout():trim()
	return host_pubkey == mm.pubkey()
end

function action.ssh_check_key(machine)
	local ok = mm.ssh_check_key(machine)

	update_row('machine', {ssh_key_ok = ok, ['machine:old'] = machine}, 'ssh_key_ok')
	rowset_changed'machines'

	out_json{
		notify = 'SSH key is'..(ok and '' or ' NOT')..' up-to-date for '..machine,
		notify_kind = ok and 'info' or 'warn',
		machine = machine,
		ssh_key_ok = ok,
	}
end
cmd.ssh_check_key = action.ssh_check_key

--command: github-update-key -------------------------------------------------

function mm.github_update_key(machine)
	mm.ssh_bash('github_update_key', machine, [[
		#include utils
		ssh_update_host_fingerprint github.com "$github_fingerprint"
		ssh_update_host_key github.com mm_github "$github_key"
		for d in /home/*; do
			[ -d $d.ssh ] && \
				HOME=$d ssh_update_host_key github.com mm_github "$github_key"
		done
	]], {
		github_fingerprint = mm.github_fingerprint,
		github_key = mm.github_key,
	})
end

function action.github_update_key(machine)
	if not machine then
		mm.each_machine(mm.github_update_key)
		return true
	end
	mm.github_update_key(machine)
	out_json{machine = machine, notify = 'Github key updated'}
end
cmd.github_update_key = action.github_update_key

--command: machine-prepare ---------------------------------------------------

function mm.machine_prepare(machine)
	mm.ssh_bash('machine_prepare', machine, [=[

		#include utils

		ubuntu_install_packages htop mc mysql-server

		git_install_git_up
		git_config_user mm@allegory.ro "Many Machines"
		ssh_update_host_fingerprint github.com "$github_fingerprint"
		ssh_update_host_key github.com mm_github "$github_key"

		mgit_install

		mysql_update_pass localhost root "$mysql_root_pass"

	]=], {
		github_fingerprint = mm.github_fingerprint,
		github_key = mm.github_key,
		mysql_root_pass = mm.mysql_root_pass()
	})
end

function action.machine_prepare(machine)
	mm.machine_prepare(machine)
	out_json{machine = machine, notify = 'Machine prepared: '..machine}
end
cmd.machine_prepare = action.machine_prepare

--command: deploy ------------------------------------------------------------

function mm.deploy(deploy)

	checkarg(str_arg(deploy), 'deploy required')

	local d = first_row([[
		select
			d.machine,
			d.repo,
			d.version,
			d.env,
			d.secret
		from
			deploy d
		where
			deploy = ?
	]], deploy)

	local app = d.repo:gsub('%.git$', ''):match'/(.-)$'

	local mysql_pass = d.secret:sub(1, 32)
	assert(#mysql_pass == 32)

	mm.ssh_bash('deploy', d.machine, [[

		#include utils

		must user_create $deploy
		must user_lock_pass $deploy

		HOME=/home/$deploy ssh_update_host_key github.com mm_github "$github_key"

		must mysql_create_schema $deploy
		must mysql_create_user localhost $deploy "$mysql_pass"
		must mysql_grant_user  localhost $deploy $deploy

		must cd /home/$deploy
		must sudo -u $deploy git clone -b $version $repo $app
		must cd $app
		must sudo -u $deploy \
			MACHINE="$MACHINE" \
			DEPLOY="$deploy" \
			MYSQL_SCHEMA="$deploy" \
			MYSQL_USER="$deploy" \
			MYSQL_PASS="$mysql_pass" \
			SECRET="$secret" \
				-- ./$app install $env

	]], {
		MYSQL_ROOT_PASS = mm.mysql_root_pass(),
		deploy = deploy,
		repo = d.repo,
		app = app,
		version = d.version or 'master',
		env = d.env,
		mysql_pass = mysql_pass,
		secret = d.secret,
		github_key = mm.github_key,
	})

end

action.deploy = mm.deploy
cmd.deploy = action.deploy

function mm.undeploy(deploy)
	checkarg(str_arg(deploy), 'deploy required')
	mm.ssh_bash('deploy', d.machine, [[

		#include utils

		mut cd $app
		./$app

	]], {
		app = app,
	})
end
action.undeploy = mm.undeploy
cmd.undeploy = action.undeploy

--cmdline tools --------------------------------------------------------------

function cmd.ls()
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
			mysql_ver
		from machine
		order by pos, ctime
]]))
end

function cmd.ssh(machine, command)
	mm.sshi(nil, machine, command and {'bash', '-c', (command:gsub(' ', '\\ '))})
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
function cmd.putty(machine)
	local ip = mm.ip(machine)
	proc.exec(indir(exedir, 'putty')..' -load mm -i '..mm.keyfile(machine):gsub('%.key$', '.ppk')..' root@'..ip):forget()
end

function cmd.tunnel(machine, ports)
	local args = {'-N'}
	ports = checkarg(str_arg(ports), 'Usage: mm tunnel MACHINE LPORT1[:RPORT1],...')
	for ports in ports:gmatch'([^,]+)' do
		local rport, lport = ports:match'(.-):(.*)'
		add(args, '-L')
		add(args, '127.0.0.1:'..(lport or ports)..':127.0.0.1:'..(rport or ports))
	end
	mm.sshi(nil, machine, args)
end

function cmd.mysql(machine, ...)
	mm.sshi(nil, machine, {
		'MYSQL_PWD='..proc.quote_arg_unix(mm.mysql_root_pass(machine)),
			'mysql', '-u', 'root', '-h', 'localhost', ...})

end

return mm:run(...)
