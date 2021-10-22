
require'$daemon'

local proc = require'proc'
local sock = require'sock'
local xapp = require'xapp'

local mm = xapp(daemon(...))

--config ---------------------------------------------------------------------

mm.known_hosts_file  = indir(var_dir, 'known_hosts')
mm.mm_key_file       = indir(var_dir, 'mm.key')
mm.github_key_file   = indir(var_dir, 'mm-github.key')

mm.mm_key            = checkexists(mm.mm_key_file)
mm.mm_key_pub        = load(mm.mm_key_file..'.pub')
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

if not ffi.abi'win' then
	--because stupid ssh wants 0600 on mm.key and we can't do that with vboxfs.
	local f = '/root/mm.key'
	cp(mm.mm_key_file, f)
	mm.mm_key_file = f
	chmod(f, '0600')
end

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
					<x-textedit col=mm_key_pub infomode=under
						info="This is the SSH key used to log in as root on all machines."></x-textedit>
					<x-button danger action_name=gen_mm_key_button_action style="grid-area: regen"
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

function gen_mm_key_button_action() {
	this.load(['', 'gen_mm_key'])
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
		{name = 'mm_key_pub', text = 'MM\'s Public Key'},
	}
	self.pk = 'config_id'

	function self:load_rows(rs, params)
		local row = {1, mm.mm_key_pub}
		rs.rows = {row}
	end

end)

--async exec -----------------------------------------------------------------

mm.tasks = {}
mm.tasks_by_id = {}
local last_task_id = 0
local task_events_thread

function mm.exec(cmd, stdin_contents, opt)
	opt = opt or empty

	last_task_id = last_task_id + 1
	local task = {
		id = last_task_id,
		cmd = cmd,
		start_time = time(),
		duration = 0,
		status = 'new',
		errors = {},
		stdin = stdin_contents,
		script = opt.script,
	}
	mm.tasks[task] = true
	mm.tasks_by_id[task.id] = task

	local function task_changed()
		task.duration = time() - task.start_time
		rowset_changed'tasks'
	end

	local capture_stdout = opt.capture_stdout ~= false
	local capture_stderr = opt.capture_stderr ~= false

	local p, err = proc.exec{
		cmd = cmd,
		async = true,
		stdout = capture_stdout,
		stderr = capture_stderr,
		stdin = stdin_contents and true or false,
	}

	if not p then
		add(task.errors, 'exec error: '..err)
		logerror('mm', 'exec', err)
		task_changed()
		return
	end

	task.status = 'running'
	task.p = p

	if p.stdin then
		thread(function()
			dbg('mm', 'execin', '%s', stdin_contents)
			local ok, err = p.stdin:write(stdin_contents)
			if not ok then
				add(task.errors, 'stdin write error: '..err)
				task_changed()
			end
			p.stdin:close() --signal eof
		end)
	end

	task.out = {} --combined stdout & stderr

	task.stdout = {}
	if p.stdout then
		thread(function()
			local buf, sz = u8a(4096), 4096
			while true do
				local len, err = p.stdout:read(buf, sz)
				if not len then
					add(task.errors, 'stdout read error: '..err)
					break
				elseif len == 0 then
					break
				end
				local s = ffi.string(buf, len)
				add(task.stdout, s)
				add(task.out, s)
				task_changed()
			end
			p.stdout:close()
			task_changed()
		end)
	end

	task.stderr = {}
	if p.stderr then
		thread(function()
			local buf, sz = u8a(4096), 4096
			while true do
				local len, err = p.stderr:read(buf, sz)
				if not len then
					add(task.errors, 'stderr read error: '..err)
					break
				elseif len == 0 then
					break
				end
				local s = ffi.string(buf, len)
				add(task.stderr, s)
				add(task.out, s)
				task_changed()
			end
			p.stderr:close()
			task_changed()
		end)
	end

	task_changed()
	local exit_code, err = p:wait()
	if exit_code then
		task.exit_code = exit_code
	else
		add(task.errors, 'wait error: '..err)
	end
	task.end_time = time()
	task.status = 'finished'
	task_changed()
	while not (
		    (not p.stdin or p.stdin:closed())
		and (not p.stdout or p.stdout:closed())
		and (not p.stderr or p.stderr:closed())
	) do
		sleep(.1)
	end
	p:forget()
	if #task.out > 0 then
		dbg('mm', 'execout', '%s', concat(task.out))
	end
	local function free_task()
		mm.tasks[task] = nil
		mm.tasks_by_id[task.id] = nil
		task_changed()
	end
	if opt and opt.nowait then
		free_task()
	else
		thread(function()
			task_changed()
			sleep(10)
			while task.pinned do
				sleep(1)
			end
			free_task()
		end)
	end

	return task
end

function machine_ip(machine)
	if not machine then return nil, 'Machine required' end
	local ip = first_row('select public_ip from machine where machine = ?', machine)
	if ip then return ip end
	return nil, 'Machine not found: '..machine
end

function mm.ssh(ip, args, stdin_contents, opt)
	return mm.exec(extend({
			'ssh',
			'-o', 'BatchMode=yes',
			'-o', 'UserKnownHostsFile='..mm.known_hosts_file,
			'-o', 'ConnectTimeout=2',
			'-i', mm.mm_key_file,
			'root@'..ip,
		}, args), stdin_contents, opt)
end

--passing both the script and the script's expected stdin contents through
--ssh's stdin at the same time is only possible due to a ridiculous behavior
--that only bash can muster: bash reads its input one-byte-at-a-time and
--stops reading exactly after the `exit` command, not one byte more, so we can
--feed in stdin_contents right after that. worse-is-better at its finest.
function mm.ssh_bash(ip, script, stdin_contents, opt)
	local s = '{\n'..script..'\n}; exit'..(stdin_contents or '')
	return mm.ssh(ip, {'bash', '-s'}, s, opt)
end

rowset.tasks = virtual_rowset(function(self, ...)

	self.fields = {
		{name = 'id'        , type = 'number', w = 20},
		{name = 'pinned'    , type = 'bool'},
		{name = 'status'    , },
		{name = 'start_time', type = 'timestamp'},
		{name = 'duration'  , type = 'number', decimals = 2, hint = 'Duration till last change in input, output or status'},
		{name = 'script'    , },
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
			task.status,
			task.start_time,
			task.duration,
			task.script,
			concat(task.cmd, ' '),
			task.stdin,
			concat(task.out),
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

--commands -------------------------------------------------------------------

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
	save(concat(t, '\n'), mm.known_hosts_file)
end

local function checknostderr(task)
	assert(task.status == 'finished', concat(task.errors, '\n'))
	local stderr = concat(task.stderr)
	local stdout = concat(task.stdout)
	check500(stderr == '', stderr)
	return stdout
end

local function checkout(task)
	assert(task.status == 'finished', concat(task.errors, '\n'))
	return concat(task.out)
end

function mm.update_host_fingerprint(ip, machine)
	local fp = checknostderr(mm.exec({'ssh-keyscan', '-H', ip}, nil, {capture_stderr = false}))
	assert(update_row('machine', {fingerprint = fp, ['machine:old'] = machine}, 'fingerprint').affected_rows == 1)
	mm.gen_known_hosts_file()
end

function action.update_host_fingerprint(machine)
	local machine = str_arg(machine)
	local ip = checkfound(machine_ip(machine), 'machine not found')
	mm.update_host_fingerprint(ip, machine)
	out'Fingerprint updated for '; out(machine)
end

function cmd.update_host_fingerprint(machine)
	webb.run(function()
		local machine = str_arg(machine)
		local ip = cmdcheck(machine_ip(machine), 'update-host-fingerprint MACHINE')
		mm.update_host_fingerprint(ip, machine)
	end)
end

function mm.get_machine_info(ip)
		local stdout = checknostderr(mm.ssh_bash(ip, [=[

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

]=]))
	local t = {last_seen = time()}
	for s in stdout:trim():lines() do
		local k,v = assert(s:match'^(.-)%s+(.*)')
		t[k] = v
	end
	return t
end

function action.update_machine_info(machine)
	local ip = checkfound(machine_ip(str_arg(machine)))
	t = assert(mm.get_machine_info(ip))
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

function cmd.machine_info(machine)
	webb.run(function()
		mm.get_machine_info(cmdcheck(machine_ip(str_arg(machine)), 'info MACHINE'))
	end)
end

function mm.prepare_machine(machine, opt)
	return checkout(mm.ssh_bash(machine, [=[
say() { echo -e "\n# $@\n" >&2; }

say "Installing SSH public key for passwordless access"
mkdir -p /root/.ssh
cat << 'EOF' > /root/.ssh/authorized_keys
]=]..mm.mm_key_pub..[=[

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

]=], nil, opt))
end

function action.prepare_machine(machine)
	local ip = checkfound(machine_ip(str_arg(machine)))
	mm.prepare_machine(ip)
	out(_('Machine %s prepared', machine))
end

function cmd.prepare_machine(machine)
	webb.run(function()
		local ip = cmdcheck(machine_ip(str_arg(machine)), 'prepare-machine MACHINE')
		mm.prepare_machine(ip, {capture_stdout = false, capture_stderr = false})
	end)
end

--command: gen & update keys -------------------------------------------------

function mm.update_keys(ip)
	mm.ssh_bash(ip, [=[
say() { echo "# $1." >&2; }

say "Adding mm public key to /root/.ssh/authorized_keys (for SSH access)"
mkdir -p /root/.ssh
sed -i '/ mm/d' /root/.ssh/authorized_keys
cat << 'EOF' >> /root/.ssh/authorized_keys
]=]..load(mm.mm_key_file..'.new.pub')..[=[

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

]=])
end

function mm.gen_mm_key()
	rm(mm.mm_key_file..'.new')
	rm(mm.mm_key_file..'.new.pub')
	os.execute(_('ssh-keygen -f %s -t rsa -b 2048 -C "mm" -q -N ""', mm.mm_key_file..'.new'))
	for _, ip, machine in each_row_vals'select public_ip, machine from machine' do
		thread(function()
			print('Updating keys for '..machine..'...')
			mm.update_keys(ip)
		end)
	end
	mv(mm.mm_key_file..'.new'    , mm.mm_key_file)
	mv(mm.mm_key_file..'.new.pub', mm.mm_key_file..'.pub')
	mm.mm_key_pub = load(mm.mm_key_file..'.pub')
end

function cmd.update_keys()
	webb.run(function()
		mm.gen_mm_key()
	end)
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

cmd.deploy = function(ip, deploy)
	webb.run(function()
		ip = machine_ip(ip)
		mm.ssh_bash(ip, [=[

]=])
	end)
end

--cmdline --------------------------------------------------------------------

function cmd.ls()
	webb.run(function()
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
	end)
end

function cmd.ssh(machine, command)
	webb.run(function()
		local ip = cmdcheck(machine_ip(str_arg(machine)), 'ssh MACHINE')
		mm.ssh(ip, command and {'bash', '-c', (command:gsub(' ', '\\ '))},
			nil, {capture_stdout = false, capture_stderr = false, nowait = true})
	end)
end

function cmd.ssh_all(command)
	webb.run(function()
		for _, ip, machine in each_row_vals'select public_ip, machine from machine' do
			thread(function()
				print('Executing on '..machine..'...')
				mm.ssh(ip, command and {'bash', '-c', (command:gsub(' ', '\\ '))},
					nil, {capture_stdout = false, capture_stderr = false, nowait = true})
			end)
		end
	end)
end

function cmd.update()
	webb.run(function()
		add_column('deploy', 'pos', '$pos')
	end)
end

return mm:run(...)
