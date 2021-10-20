
require'$daemon'

local proc = require'proc'
local sock = require'sock'
local xapp = require'xapp'

local mm = xapp(daemon(...))

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

if ffi.abi'win' then
	--
else
	--because stupid ssh wants 0600 on home.key and we can't do that with vboxfs.
	mm.home_key = '/root/home.key'
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
		version     $name not null,
		status      $name
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
mm.font = 'opensans'

css[[
body {
	/* layout content: center limited-width body to window */
	display: flex;
	flex-flow: column;
}

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
			<div action=tasks>Tasks</div>
		</x-listbox>
	</div>
	<x-switcher id=main_switcher nav_id=actions_listbox>
		<x-vsplit action=machines>
			<x-grid id=machines_grid rowset_name=machines></x-grid>
		</x-vsplit>
		<x-vsplit action=deploys>
			<x-grid id=ee rowset_name=deploys></x-grid>
			<x-textedit nav_id=ee col=deploy></x-textedit>
		</x-vsplit>
		<x-vsplit action=tasks>
			<x-grid id=tasks_grid rowset_name=tasks></x-grid>
			<x-textarea mono nav_id=tasks_grid col=stdout></x-textarea>
		</x-vsplit>
	</x-switcher>
</x-split>
]]

js[[

function task_grid_init_cmenu_items(e, items) {
	let row = e.focused_row
	items.push({
		text: S('ping', 'Ping'),
		disabled: !row,
		action: function(item) {
			let machine = e.cell_val(row, 'machine')
			get(['', 'update_machine_info', machine])
		},
	})
}
document.on('machines_grid.bind', function(e, on) {
	e.on('init_context_menu_items', task_grid_init_cmenu_items, on)
})

rowset_field_attrs['machines.refresh'] = {
	type: 'button',
	w: 40,
	button_options: {icon: 'fa fa-sync', bare: true, text: '', load_spin: true},
	action: function(machine) {
		this.load(['', 'update_machine_info', machine])
	},
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
		last_seen   = {type = 'timestamp', editable = false},
		cpu         = {editable = false, text = 'CPU'},
		cores       = {editable = false, w = 20},
		ram_gb      = {editable = false, w = 40, decimals = 1, text = 'RAM (GB)'},
		ram_free_gb = {editable = false, w = 40, decimals = 1, text = 'RAM/free (GB)'},
		hdd_gb      = {editable = false, w = 40, decimals = 1, text = 'HDD (GB)'},
		hdd_free_gb = {editable = false, w = 40, decimals = 1, text = 'HDD/free (GB)'},
		os_ver      = {editable = false, text = 'Operating System'},
		mysql_ver   = {editable = false, text = 'MySQL Version'},
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
		insert_row('deploy', row, 'deploy machine repo version')
	end,
	update_row = function(self, row)
		update_row('deploy', row, 'machine repo version')
	end,
	delete_row = function(self, row)
		delete_row('deploy', row, 'deploy')
	end,
}

--async exec -----------------------------------------------------------------

mm.tasks = {}
local last_task_id = 0
local task_events_thread

local function exec(cmd, stdin_contents, capture_stdout, capture_stderr)

	last_task_id = last_task_id + 1
	local task = {
		id = last_task_id,
		cmd = cmd,
		start_time = time(),
		duration = 0,
		status = 'new',
		errors = {},
	}
	mm.tasks[task] = true

	local function task_changed()
		task.duration = time() - task.start_time
		rowset_changed'tasks'
	end

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
			local ok, err = p.stdin:write(stdin_contents)
			if not ok then
				add(task.errors, 'stdin write error: '..err)
				task_changed()
			end
			p.stdin:close() --signal eof
		end)
	end

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
				add(task.stdout, ffi.string(buf, len))
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
				add(task.stderr, ffi.string(buf, len))
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
	while not (p.stdin:closed() and p.stdout:closed() and p.stderr:closed()) do
		sleep(.1)
	end
	p:forget()
	thread(function()
		task_changed()
		sleep(1)
		mm.tasks[task] = nil
		task_changed()
	end)

	return task
end

function machine_ip(ip)
	return first_row('select public_ip from machine where machine = ?', ip) or ip
end

local function ssh(ip, args, stdin_contents, capture_stdout, capture_stderr)
	local ip = machine_ip(ip)
	return exec(extend({
			'ssh',
			'-o', 'BatchMode=yes',
			'-o', 'ConnectTimeout=2',
			'-i', mm.home_key or 'home.key',
			'root@'..ip,
		}, args), stdin_contents, capture_stdout, capture_stderr)
end

--passing both the script and the script's expected stdin contents through
--ssh's stdin at the same time is only possible due to a ridiculous behavior
--that only bash can muster: bash reads its input one-byte-at-a-time and
--stops reading exactly after the `exit` command, not one byte more, so we can
--feed in stdin_contents right after that. worse-is-better at its finest.
function ssh_bash(ip, script, stdin_contents, capture_stdout, capture_stderr)
	local s = '{\n'..script..'\n}; exit'..(stdin_contents or '')
	return ssh(ip, {'bash', '-s'}, s, capture_stdout, capture_stderr)
end

rowset.tasks = virtual_rowset(function(self, ...)

	self.fields = {
		{name = 'id', type = 'number'},
		{name = 'status'},
		{name = 'start_time', type = 'timestamp'},
		{name = 'duration', type = 'number', decimals = 2, hint = 'Duration till last change in input, output or status'},
		{name = 'command'},
		{name = 'stdout', hidden = true},
		{name = 'stderr', hidden = true},
		{name = 'exit_code', type = 'number', w = 20},
		{name = 'errors'},
	}
	self.pk = 'id'

	function self:load_rows(rs, params)
		rs.rows = {}
		for task in sortedpairs(mm.tasks, function(t1, t2) return t1.start_time < t2.start_time end) do
			local row = {
				task.id,
				task.status,
				task.start_time,
				task.duration,
				concat(task.cmd, ' '),
				concat(task.stdout),
				concat(task.stderr),
				task.exit_code,
				concat(task.errors, '\n'),
			}
			add(rs.rows, row)
		end
	end

end)

------------------------------------------------------------------------------

local function get_machine_info(machine)
	local ip = machine_ip(machine)
	local task = ssh_bash(ip, [=[

query() { mysql -u root -N -B -e "$@"; }

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

]=], nil, true, true)
	assert(task.status == 'finished', concat(task.errors, '\n'))
	local stderr = concat(task.stderr)
	local stdout = concat(task.stdout)
	local t = {['machine:old'] = machine, last_seen = time()}
	dbg('mm', 'infoerr', stderr)
	dbg('mm', 'infoout', stdout)
	assert(stderr == '', stderr)
	for s in stdout:trim():lines() do
		local k,v = assert(s:match'^(.-)%s+(.*)')
		t[k] = v
	end
	return t
end

function action.update_machine_info(ip)
	t = assert(get_machine_info(ip))
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

action.test_tasks = function()

	setmime'txt'
	local task = ssh_bash('sp-prod', [[

		for i in {1..5}; do

			echo sleeping $i ...
			sleep 1

		done

		echo Exiting now...

	]], nil, true, true)

	outpp(task)

end

-- commands ------------------------------------------------------------------

function cmd.info(ip)
	webb.run()
end

local github_keyscan = [[
github.com ssh-rsa AAAAB3NzaC1yc2EAAAABIwAAAQEAq2A7hRGmdnm9tUDbO9IDSwBK6TbQa+PXYPCPy6rbTrTtw7PHkccKrpp0yVhp5HdEIcKr6pLlVDBfOLX9QUsyCOV0wzfjIJNlGEYsdlLJizHhbn2mUjvSAHQqZETYP81eFzLQNnPHt4EVVUh7VfDESU84KezmD5QlWpXLmvU31/yMf+Se8xhHTvKSCZIFImWwoG6mbUoWf9nzpIoaSjB+weqqUUmpaaasXVal72J+UX2B+2RPW3RcT0eOzQgqlJL3RKrTJvdsjE3JEAvGq3lGHSZXy28G3skua2SmVi/w4yCE6gbODqnTWlg7+wC604ydGXA8VJiS5ap43JXiUFFAaQ==
]]

function cmd.install_machine(ip)
	webb.run(function()
		ip = machine_ip(ip)
		ssh_bash(ip, [=[
say() { echo -e "\n# $@\n" >&2; }

say "Installing ssh public key for passwordless access"
mkdir -p /root/.ssh
cat << 'EOF' > /root/.ssh/authorized_keys
]=]..assert(readfile('home.key.pub'))..[=[

EOF
chmod 400 /root/.ssh/authorized_keys

say "Locking root password"
passwd -l root

say "Installing ubuntu packages"
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

say "Adding github.com's public key"
cat << 'EOF' > /root/.ssh/known_hosts
]=]..github_keyscan..[=[

EOF
chmod 400 /root/.ssh/known_hosts

say "Installing mgit"
git clone git@github.com:capr/multigit.git
ln -sf /root/multigit/mgit /usr/local/bin/mgit

say "Adding private key for pulling and pushing on github"
git config --global user.email "cosmin@allegory.ro"
git config --global user.name "Cosmin Apreutesei"
cat << 'EOF' > /root/.ssh/id_rsa
]=]..assert(readfile('mm-github.key'))..[=[

EOF
chmod 400 /root/.ssh/id_rsa

say "Resetting mysql root password"
mysql -e "alter user 'root'@'localhost' identified by 'root';"

]=])
	end)
end

function cmd.update_keys()
	webb.run(function()
		os.execute('ssh-keygen')
		os.execute('ssh-keygen -f home.key -t rsa -b 2048 -C "home" -q -N ""')

		ip = machine_ip(ip)
		ssh_bash(ip, [=[
say() { echo "# $1." >&2; }

say "Setting up ssh access"
mkdir -p /root/.ssh
cat << 'EOF' > /root/.ssh/authorized_keys
]=]..assert(readfile('home.key.pub'))..[=[

EOF
chmod 400 /root/.ssh/authorized_keys

say "Setting up github access"
cat << 'EOF' > /root/.ssh/known_hosts
]=]..github_keyscan..[=[

EOF
chmod 400 /root/.ssh/known_hosts

cat << 'EOF' > /root/.ssh/id_rsa
]=]..assert(readfile('mm-github.key'))..[=[

EOF
chmod 400 /root/.ssh/id_rsa

]=])
	end)
end

cmd.deploy = function(ip, deploy)
	webb.run(function()
		ip = machine_ip(ip)
		ssh_bash(ip, [=[

]=])
	end)
end

function cmd.ssh(ip)
	ip = webb.run(function() return machine_ip(ip) end)
	return os.execute('ssh -i home.key root@'..ip)
end

--return mm.run('on', '10.0.0.20', 'install')
--return mm.run('install-machine', '45.13.136.150')
--return mm.run('update-keys', '45.13.136.150')
--return mm:run('info', '45.13.136.150')
return mm:run('start')
--mm:run'install'
--return mm.run(...)
