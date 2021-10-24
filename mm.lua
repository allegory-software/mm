
require'$daemon'
require'xmodule'

local proc = require'proc'
local sock = require'sock'
local xapp = require'xapp'

local mm = daemon(...)
if Linux then
	var_dir = _('/root/%s-var', app_name)
end
mm:init()
xapp(mm)

--tools ----------------------------------------------------------------------

function mm.keyfile(machine, suffix, ext)
	local file = 'mm'..(machine and '-'..machine or '')
		..(suffix and '.'..suffix or '')..'.'..(ext or 'key')
	return indir(var_dir, file)
end

function mm.pubkey(machine, prefix)
	return exec('ssh-keygen -y -f "'..mm.keyfile(machine, prefix)..'"')
end

function mm.gen_ppk(machine, suffix)
	local key = mm.keyfile(machine, suffix)
	local ppk = mm.keyfile(machine, suffix, 'ppk')
	os.execute(_('winscp.com /keygen %s /output=%s', key, ppk))
end

function cmd.gen_ppk()
	mm.gen_ppk()
end

--config ---------------------------------------------------------------------

mm.known_hosts_file  = indir(var_dir, 'known_hosts')
mm.github_key_file   = indir(var_dir, 'mm_github.key')
mm.github_key        = load(mm.github_key_file, false)

config('http_addr', '*')

--logging.filter[''] = true
require'http'.logging = logging
require'http_server'.logging = logging
require'mysql_client'.logging = logging

config('db_host', '10.0.0.5')
config('db_port', 3307)
config('db_pass', 'root')
config('var_dir', '.')
config('session_secret', '!xpAi$^!@#)fas!`5@cXiOZ{!9fdsjdkfh7zk')
config('pass_salt'     , 'is9v09z-@^%@s!0~ckl0827ScZpx92kldsufy')

mm.github_fingerprint = [[
github.com ssh-rsa AAAAB3NzaC1yc2EAAAABIwAAAQEAq2A7hRGmdnm9tUDbO9IDSwBK6TbQa+PXYPCPy6rbTrTtw7PHkccKrpp0yVhp5HdEIcKr6pLlVDBfOLX9QUsyCOV0wzfjIJNlGEYsdlLJizHhbn2mUjvSAHQqZETYP81eFzLQNnPHt4EVVUh7VfDESU84KezmD5QlWpXLmvU31/yMf+Se8xhHTvKSCZIFImWwoG6mbUoWf9nzpIoaSjB+weqqUUmpaaasXVal72J+UX2B+2RPW3RcT0eOzQgqlJL3RKrTJvdsjE3JEAvGq3lGHSZXy28G3skua2SmVi/w4yCE6gbODqnTWlg7+wC604ydGXA8VJiS5ap43JXiUFFAaQ==
]]

--database -------------------------------------------------------------------

local function cmdcheck(s, usage)
	if not s then
		cmd.help(usage)
		os.exit(1)
	end
	return s
end

function mm.install()

	auth_create_tables()

	drop_table'deploy'
	drop_table'machine'

	query[[
	$table machine (
		machine     $strpk,
		public_ip   $name,
		local_ip    $name,
		fingerprint $b64key,
		ssh_key     $b64key,
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
	$table repo (

	);
	]]

	query[[
	$table deploy (
		deploy      $strpk,
		machine     $strid not null, $fk(deploy, machine),
		repo        $url not null,
		version     $name not null,
		status      $name,
		pos         $pos
	);
	]]

	insert_row('machine', {
		machine = 'sp-test',
		local_ip = '10.0.0.20',
	}, 'machine local_ip')

	insert_row('machine', {
		machine = 'sp-prod',
		public_ip = '45.13.136.150',
	}, 'machine public_ip')

end

--admin ui -------------------------------------------------------------------

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
}

#config_form.maxcols1 {
	max-width: 400px;
	grid-template-areas:
		"mm_"
		"regen"
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
					<x-textarea rows=8 col=mm_pub infomode=under
						info="This is the SSH key used to log in as root on all machines.">
					</x-textarea>
					<x-button danger action_name=update_keys_button_action style="grid-area: regen"
						text="Generate new key & upload it to all machines" icon="fa fa-key">
					</x-button>
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
		this.load(['', 'update_machine_info', machine])
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

// machines grid context menu items.
document.on('machines_grid.init', function(e) {

	e.on('init_context_menu_items', function(items) {

		items.last.separator = true

		items.push({
			text: S('update_host_fingerprint', 'Update host fingerprint'),
			action: function() {
				let machine = e.focused_row_cell_val('machine')
				if (machine)
					get(['', 'update_host_fingerprint', machine], function(s) {
						notify(s, 'info')
					})
			},
		})

		items.push({
			text: S('prepare_machine', 'Prepare machine'),
			action: function() {
				let machine = e.focused_row_cell_val('machine')
				if (machine)
					get(['', 'prepare_machine', machine], function(s) {
						notify(s, 'info')
					})
			},
		})

	})

})

function deploy_button_action() {
	let deploy = deploys_grid.focused_row_cell_val('deploy')
	this.load(['', 'deploy', deploy])
}

function update_keys_button_action() {
	this.load(['', 'update-keys'])
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
		local_ip    = {text = 'Local IP Address'},
		last_seen   = {type = 'timestamp', readonly = true},
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
		insert_row('machine', row, 'machine public_ip local_ip pos')
	end,
	update_row = function(self, row)
		update_row('machine', row, 'machine public_ip local_ip pos')
	end,
	delete_row = function(self, row)
		delete_row('machine', row, 'machine')
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
			status
		from
			deploy
	]],
	pk = 'deploy',
	field_attrs = {
		machine = {
			--lookup_rowset_name = 'machines',
			--lookup_col = 'machine',
			--display_col = 'machine',
		},
	},
	insert_row = function(self, row)
		insert_row('deploy', row, 'deploy machine repo version pos')
	end,
	update_row = function(self, row)
		update_row('deploy', row, 'deploy machine repo version pos')
	end,
	delete_row = function(self, row)
		delete_row('deploy', row, 'deploy')
	end,
}

rowset.config = virtual_rowset(function(self, ...)

	self.fields = {
		{name = 'config_id', type = 'number'},
		{name = 'mm_pub', text = 'MM\'s Public Key'},
	}
	self.pk = 'config_id'

	function self:load_rows(rs, params)
		local row = {1, mm.pubkey()}
		rs.rows = {row}
	end

end)

--async exec -----------------------------------------------------------------

function mm.exec(cmd, opt)
	opt = opt or empty

	local capture_stdout = opt.capture_stdout ~= false
	local capture_stderr = opt.capture_stderr ~= false

	local task = mm.task(opt)

	local p, err = proc.exec{
		cmd = cmd,
		async = true,
		autokill = true,
		stdout = capture_stdout,
		stderr = capture_stderr,
		stdin = opt.stdin and true or false,
	}

	if not p then
		task:logerror('exec', '%s', err)
		return
	end

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

	return task
end

function mm.ip(machine)
	local machine = checkarg(str_arg(machine), 'machine required')
	local ip = first_row('select public_ip from machine where machine = ?', machine)
	return checkfound(ip, 'machine not found')
end

function mm.ssh(machine, args, opt)
	return mm.exec(extend({
			'ssh',
			'-o', 'BatchMode=yes',
			'-o', 'UserKnownHostsFile='..mm.known_hosts_file,
			'-o', 'ConnectTimeout=2',
			'-i', mm.keyfile(machine),
			'root@'..mm.ip(machine),
		}, args), opt)
end

--passing both the script and the script's expected stdin contents through
--ssh's stdin at the same time is only possible due to a ridiculous behavior
--that only bash can muster: bash reads its input one-byte-at-a-time and
--stops reading exactly after the `exit` command, not one byte more, so we can
--feed in stdin right after that. worse-is-better at its finest.
function mm.ssh_bash(machine, script, opt)
	opt = opt or {}
	opt.stdin = '{\n'..script..'\n}; exit'..(opt.stdin or '')
	return mm.ssh(machine, {'bash', '-s'}, opt)
end

--tasks ----------------------------------------------------------------------

mm.tasks = {}
mm.tasks_by_id = {}
local last_task_id = 0
local task_events_thread

local task = {}

function mm.task(opt)
	last_task_id = last_task_id + 1
	local self = inherit({
		id = last_task_id,
		cmd = cmd,
		start_time = time(),
		duration = 0,
		status = 'new',
		errors = {},
		stdin = opt.stdin,
		script = opt.script,
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
		dbg('mm', 'taskout', '%d,%s\n%s', self.id, self.script, s)
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
		{name = 'script'    , },
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
			task.script,
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
	assert(task.status == 'finished', concat(task.errors, '\n'))
	local stderr = task:stderr()
	local stdout = task:stdout()
	check500(stderr == '', stderr)
	return stdout
end

local function checkout(task)
	assert(task.status == 'finished', concat(task.errors, '\n'))
	return task:stdouterr()
end

--command: update_host_fingerprint -------------------------------------------

function mm.gen_known_hosts_file()
	local t = {}
	for i, ip, fp in each_row_vals[[
		select public_ip, fingerprint
		from machine
		where fingerprint is not null
		order by pos, ctime
	]] do
		add(t, fp)
	end
	save(mm.known_hosts_file, concat(t, '\n'))
end

function mm.update_host_fingerprint(machine)
	local fp = checknostderr(mm.exec({'ssh-keyscan', '-H', mm.ip(machine)},
		{script = 'get_host_fingerprint', capture_stderr = false}))
	assert(update_row('machine', {fingerprint = fp, ['machine:old'] = machine}, 'fingerprint').affected_rows == 1)
	mm.gen_known_hosts_file()
end

function action.update_host_fingerprint(machine)
	mm.update_host_fingerprint(machine)
	out'Fingerprint updated for '; out(machine)
end

function cmd.update_host_fingerprint(machine)
	mm.update_host_fingerprint(machine)
	out'Fingerprint updated for '; out(machine)
end

--command: update_machine_info -----------------------------------------------

function mm.get_machine_info(machine)
		local stdout = checknostderr(mm.ssh_bash(machine, [=[

query() { which mysql >/dev/null && MYSQL_PWD=root mysql -u root -N -B -e "$@"; }

echo "os_ver        $(lsb_release -sd)"
echo "mysql_ver     $(query 'select version();')"
echo "cpu           $(lscpu | sed -n 's/^Model name:\s*\(.*\)/\1/p')"
               cps="$(lscpu | sed -n 's/^Core(s) per socket:\s*\(.*\)/\1/p')"
           sockets="$(lscpu | sed -n 's/^Socket(s):\s*\(.*\)/\1/p')"
echo "cores         $(expr $sockets \* $cps)"
echo "ram_gb        $(cat /proc/meminfo | awk '/MemTotal/ {$2/=1024*1024; printf "%.2f",$2}')"
echo "ram_free_gb   $(cat /proc/meminfo | awk '/MemAvailable/ {$2/=1024*1024; printf "%.2f",$2}')"
echo "hdd_gb        $(df -l | awk '$6=="/" {printf "%.2f",$2/(1024*1024)}')"
echo "hdd_free_gb   $(df -l | awk '$6=="/" {printf "%.2f",$4/(1024*1024)}')"

]=], {script = 'get_machine_info'}))
	local t = {last_seen = time()}
	for s in stdout:trim():lines() do
		local k,v = assert(s:match'^(.-)%s+(.*)')
		t[k] = v
	end
	return t
end

function mm.update_machine_info(machine)
	t = assert(mm.get_machine_info(machine))
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

function action.update_machine_info(machine)
	mm.update_machine_info(machine)
end

function cmd.update_machine_info(machine)
	mm.update_machine_info(machine)
end

--command: prepare_machine ---------------------------------------------------

function mm.prepare_machine(machine, opt)
	cp(mm.keyfile(), mm.keyfile(machine))
	checkout(mm.ssh_bash(machine, [=[
say() { echo -e "\n# $@\n" >&2; }

say "Installing SSH public key for passwordless access"
mkdir -p /root/.ssh
cat << 'EOF' > /root/.ssh/authorized_keys
]=]..mm.pubkey()..[=[

EOF
chmod 400 /root/.ssh/authorized_keys

say "Locking root password"
passwd -l root

say "Installing Ubuntu packages"
apt-get -y update
apt-get -y install htop mc mysql-server

say "Installing 'git up' command"
git_up=/usr/lib/git-core/git-up
cat << 'EOF' > $git_up
msg="$1"; [ "$msg" ] || msg="unimportant"
git add -A .
git commit -m "$msg"
git push -u origin master
EOF
chmod +x $git_up

say "Adding github.com fingerprint to /root/.ssh/known_hosts (for pulling)"
ssh-keygen -R github.com
cat << 'EOF' >> /root/.ssh/known_hosts
]=]..mm.github_fingerprint..[=[

EOF
chmod 400 /root/.ssh/known_hosts

say "Installing mgit"
git clone git@github.com:capr/multigit.git
ln -sf /root/multigit/mgit /usr/local/bin/mgit

]=]..(mm.github_key and [=[
say "Putting github.com private key in /root/.ssh/id_rsa (for pushing)"
git config --global user.email "cosmin@allegory.ro"
git config --global user.name "Cosmin Apreutesei"
cat << 'EOF' > /root/.ssh/id_rsa
]=]..mm.github_key..[=[

EOF
chmod 400 /root/.ssh/id_rsa
]=])..[=[

say "Resetting mysql root password"
mysql -e "alter user 'root'@'localhost' identified by 'root'; flush privileges;"

]=], update({script = 'prepare_machine'}, opt)))
end

function action.prepare_machine(machine)
	mm.prepare_machine(machine)
	out(_('Machine %s prepared', machine))
end

function cmd.prepare_machine(machine)
	mm.prepare_machine(machine, {capture_stdout = false, capture_stderr = false})
end

--command: gen & update keys -------------------------------------------------

function mm.update_keys_on(machine)
	note('mm', 'updkeys', '%s', machine)
	local pubkey = mm.pubkey()
	local stored_pubkey = mm.ssh_bash(machine, [=[
say() { echo "# $1." >&2; }

say "Adding mm public key to /root/.ssh/authorized_keys (for SSH access)"
mkdir -p /root/.ssh
sed -i '/ mm/d' /root/.ssh/authorized_keys
cat << 'EOF' >> /root/.ssh/authorized_keys
]=]..pubkey..[=[

EOF
chmod 400 /root/.ssh/authorized_keys

say "Adding github.com fingerprint to /root/.ssh/known_hosts (for pulling)"
ssh-keygen -R github.com
cat << 'EOF' >> /root/.ssh/known_hosts
]=]..mm.github_fingerprint..[=[

EOF
chmod 400 /root/.ssh/known_hosts

]=]..(mm.github_key and [=[
say "Putting github.com private key in /root/.ssh/id_rsa (for pushing)"
cat << 'EOF' > /root/.ssh/id_rsa
]=]..mm.github_key..[=[

EOF
chmod 400 /root/.ssh/id_rsa
]=])..[=[

cat /root/.ssh/authorized_keys | grep 'mm$'

]=], {script = 'update_keys'})
	if stored_pubkey:trim() ~= pubkey then
		--TODO:
		error'public key not updated'
		return
	end
	cp(mm.keyfile(), mm.keyfile(machine))
end

function mm.update_keys()
	rm(mm.keyfile())
	os.execute(_('ssh-keygen -f %s -t rsa -b 2048 -C "mm" -q -N ""', mm.keyfile()))
	rm(mm.keyfile()..'.pub') --we'll compute it every time.
	mm.gen_ppk()
	rowset_changed'config'
	for _, machine in each_row_vals'select machine from machine' do
		thread(function()
			mm.update_keys_on(machine)
		end)
	end
end

function action.update_keys()
	mm.update_keys()
end

function cmd.update_keys()
	mm.update_keys()
end

--command: deploy ------------------------------------------------------------

function mm.deploy(deploy)
	local d = first_row([[
		select
			d.repo,
			d.version,
			m.public_ip
		from
			deploy d
			inner join machine m on d.machine = m.machine
		where
			deploy = ?
	]], deploy)
end

function action.deploy(deploy)
	mm.deploy(deploy)
end

cmd.deploy = function(machine, deploy)
	mm.ssh_bash(machine, [=[

]=], {script = 'deploy'})
end

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
	mm.ssh(machine, command and {'bash', '-c', (command:gsub(' ', '\\ '))},
		{capture_stdout = false, capture_stderr = false})
end

function cmd.ssh_all(command)
	for _, machine in each_row_vals'select machine from machine' do
		thread(function()
			print('Executing on '..machine..'...')
			mm.ssh(machine, command and {'bash', '-c', (command:gsub(' ', '\\ '))},
				{capture_stdout = false, capture_stderr = false})
		end)
	end
end

--NOTE: make a putty sessin called `mm` where you set the window size,
--uncheck "warn on close" and whatever else you need to make putty comfortable.
function cmd.putty(machine)
	local ip = cmdcheck(mm.ip(str_arg(machine)), 'ssh MACHINE')
	proc.exec('putty -load mm -i '..mm.keyfile():gsub('%.key$', '.ppk')..' root@'..ip):forget()
end

return mm:run(...)
