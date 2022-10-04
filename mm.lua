--go@ plink d10 -t -batch mm/sdk/bin/linux/luajit mm/mm.lua -v run
--go@ plink mm-prod -t -batch mm/sdk/bin/linux/luajit mm/mm.lua -vv run
--go@ x:\sdk\bin\windows\luajit x:\apps\mm\mm.lua -vv run
--[[

	Many Machines, the independent man's SAAS provisioning tool.
	Written by Cosmin Apreutesei. Public Domain.

	Many Machines is a bare-bones provisioning and administration tool
	for web apps deployed on dedicated machines or VPS, as opposed to cloud
	services as it's customary these days (unless you count VPS as cloud).

FEATURES
	- Lua API, HTTP API, web UI & cmdline UI for every operation.
	- Windows-native sysadmin tools (sshfs, putty, etc.).
	- agentless: all relevant bash scripts are uploaded with each command.
	- keeps all data in a relational database (machines, deployments, etc.).
	- all processes are tracked by a task system with output capturing and autokill.
	- maintains secure access to all services via bulk updating of:
		- SSH root keys.
		- MySQL root password.
		- SSH git hosting (github, etc.) keys.
	- quick-launch of ssh, putty and mysql shells.
	- quick remote commands: ssh, mysql, rsync, deployed app commands.
	- remote fs mounts via sshfs (Windows & Linux).
	- machine prepare script (one-time install script for a new machine).
	- scheduled tasks.
	- app control: deploy, start, stop, restart.
	- remote logging with:
		- log capturing,
		- live objects list,
		- CPU/RAM monitoring.
	- db & file backups:
		- MySQL: incremental, per-server, with xtrabackup.
		- MySQL: non-incremental, per-db, with mysqldump.
		- files: always incremental, with hardlinking via rsync.
		- backup copies kept on multiple machines.
		- machine restore: create new deploys and/or override existing.
		- deployment restore: create new or override existing.
	- https proxy with automatic SSL certificate issuing and updating.

LIMITATIONS
	- the machines need to run Linux (Debian 10) and have a public IP.
	- single shared MySQL server instance for all deployments on a machine.
	- one MySQL DB per deployment.
	- one global SSH key for root access on all machines.
	- one global SSH key for git access.

]]

--db schema ------------------------------------------------------------------

local function mm_schema()

	types.git_version = {strid, null_text = 'master'}

	tables.git_hosting = {
		name        , strpk,
		host        , strid, not_null,
		ssh_hostkey , public_key, not_null,
		ssh_key     , private_key, not_null,
		pos         , pos,
	}

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
		cost_per_month, money,
		cost_per_year , money,
		active      , bool1, --enable/disable all automation
		ssh_hostkey , public_key,
		ssh_key     , private_key,
		ssh_key_ok  , bool,
		admin_page  , url,
		os_ver      , name,
		mysql_ver   , name,
		mysql_local_port , uint16,
		log_local_port   , uint16,
		cpu         , name,
		cores       , uint16,
		ram         , filesize,
		hdd         , filesize,

		--backup task scheduling
		full_backup_active      , bool,
		full_backup_start_hours , timeofday,
		full_backup_run_every   , duration, {duration_format = 'long'},
		incr_backup_active      , bool,
		incr_backup_start_hours , timeofday,
		incr_backup_run_every   , duration, {duration_format = 'long'},
		backup_remove_older_than, duration, {duration_format = 'long'},

		pos         , pos,
		ctime       , ctime,
	}

	tables.machine_backup_copy_machine = {
		machine      , strid, not_null, child_fk,
		dest_machine , strid, not_null, child_fk(machine), pk,
		synced       , bool0,
	}

	tables.deploy = {
		deploy           , strpk,
		machine          , strid, weak_fk,
		repo             , url, not_null,
		app              , strid, not_null,
		domain           , strid,
		http_port        , uint16,
		wanted_app_version   , git_version,
		wanted_sdk_version   , git_version,
		deployed_app_version , git_version,
		deployed_sdk_version , git_version,
		deployed_app_commit  , strid,
		deployed_sdk_commit  , strid,
		deployed_at          , timeago,
		started_at           , timeago,
		env              , strid, not_null,
		secret           , secret_key, not_null, --multi-purpose
		mysql_pass       , hash, not_null,

		restored_from_dbk, id, weak_fk(dbk),
		restored_from_mbk, id, weak_fk(mbk),

		active, bool1, --enable/disable all automation

		--backup task scheduling
		backup_active      , bool,
		backup_start_hours , timeofday,
		backup_run_every   , duration, {duration_format = 'long'},
		backup_remove_older_than, duration, {duration_format = 'long'},

		ctime            , ctime,
		mtime            , mtime,
		pos              , pos,
	}

	tables.deploy_backup_copy_machine = {
		deploy       , strid, not_null, child_fk,
		dest_machine , strid, not_null, child_fk(machine), pk,
		synced       , bool0,
	}

	tables.deploy_vars = {
		deploy , strid, not_null,
		name   , strid, not_null, pk,
		val    , text, not_null,
	}

	tables.deploy_log = {
		deploy   , strid, not_null, child_fk,
		ctime    , ctime, pk,
		severity , strid,
		module   , strid,
		event    , strid,
		message  , text,
	}

	--machine backups: ideally backups should be per-deployment, not per-machine.
	--but mysql only supports incremental backups for the entire server instance
	--not per schema, so the idea of "machine backups" come from this limitation.
	tables.mbk = {
		mbk         , idpk,
		machine     , strid, fk(machine),
		parent_mbk  , id, fk(mbk),
		start_time  , timeago,
		duration    , duration,
		checksum    , hash,
		note        , text, aka'name',
		stdouterr   , text,
	}

	tables.mbk_deploy = {
		mbk         , id   , not_null, child_fk,
		deploy      , strid, not_null, fk, pk,
		app_version , git_version,
		sdk_version , git_version,
		app_commit  , strid,
		sdk_commit  , strid,
	}

	tables.mbk_copy = {
		mbk_copy   , idpk,
		parent_mbk_copy, id, fk(mbk_copy),
		mbk         , id, not_null, fk,
		machine     , strid, not_null, child_fk, uk(mbk, machine),
		start_time  , timeago,
		duration    , duration,
		size        , filesize,
	}

	--deploy backups: done with mysqldump so they are slow and non-incremental,
	--but they're the only way to backup & restore a single schema out of many
	--on a mysql server.
	tables.dbk = {
		dbk        , idpk,
		deploy      , strid, not_null, fk,
		app_version , git_version,
		sdk_version , git_version,
		app_commit  , strid,
		sdk_commit  , strid,
		start_time  , timeago,
		duration    , duration,
		checksum    , hash,
		note        , text, aka'name',
		stdouterr   , text,
	}

	tables.dbk_copy = {
		dbk_copy   , idpk,
		dbk        , id, not_null, fk,
		machine     , strid, not_null, child_fk, uk(dbk, machine),
		start_time  , timeago,
		duration    , duration,
		size        , filesize,
	}

	tables.task_last_run = {
		sched_name  , longstrpk,
		last_run    , time,
	}

	tables.task_run = {
		task_run   , idpk,
		start_time , timeago, not_null,
		name       , longstrid,
		duration   , duration,
		stdin      , text,
		stdouterr  , text,
		exit_code  , int,
	}

end

--modules, config, tools, install --------------------------------------------

--debug.traceback = require'stacktraceplus'.stacktrace

local xapp = require'xapp'

require'base64'
require'mustache'
require'queue'
require'mess'
require'tasks'
require'mysql_print'
require'http_client'

if win then
	winapi = require'winapi'
	require'winapi.registry'
end

config('multilang', false)
config('allow_create_user', false)
config('auto_create_user', false)

local mm = xapp(...)

--logging.filter.mysql = true

mm.sshfsdir = [[C:\PROGRA~1\SSHFS-Win\bin]] --no spaces!
mm.bindir   = indir(scriptdir(), 'bin', win and 'windows' or 'linux')
mm.sshdir   = mm.bindir

config('page_title_suffix', 'Many Machines')
config('sign_in_logo', '/sign-in-logo.png')
config('favicon_href', '/favicon1.ico')
config('dev_email', 'cosmin.apreutesei@gmail.com')

config('secret', '!xpAi$^!@#)fas!`5@cXiOZ{!9fdsjdkfh7zk')
config('smtp_host', 'mail.bpnpart.com')
config('smtp_user', 'admin@bpnpart.com')
config('noreply_email', 'admin@bpnpart.com')

config('mm_host', 'mm.allegory.ro')

--logging.filter[''] = true
--config('http_debug', 'protocol')
--config('getpage_debug', 'stream')

--load_opensans()

mm.schema:import(mm_schema)

local function NYI(event)
	log('ERROR', 'mm', event, 'NYI')
	error('NYI: '..event)
end

local function split(sep, s)
	if not s then return nil, nil end
	local s1, s2 = s:match('^(.-)'..esc(sep)..'(.*)')
	return repl(s1, ''), repl(s2, '')
end

--web api / server -----------------------------------------------------------

local mm_api = {} --{action->fn}

local out_term = streaming_terminal{send = out}

action['api.txt'] = function(action, ...)
	setcompress(false)
	--^^required so that each out() call is a HTTP chunk and there's no buffering.
	setheader('content-type', 'application/octet-stream')
	--^^the only way to make chrome fire onreadystatechange() for each chunk.
	allow(usr'roles'.admin)
	checkarg(method'post', 'try POST')
	local handler = checkfound(mm_api[action:gsub('-', '_')], 'action not found: %s', action)
	local post = repl(post(), '')
	checkarg(post == nil or istab(post))
	--Args are passed to the API handler as `getarg1, ..., postarg1, ...`
	--so you can pass args as GET or POST or a combination, the API won't know.
	--GET args come from the URI path so they're all strings. POST args come
	--as a JSON array so you can pass in structured data in them. That said,
	--args from cmdline can only be strings so better assume all args untyped.
	--String args and options coming from the command line are trimmed and
	--empty strings are passed as `nil`. Empty GET args (as in `/foo//bar`)
	--are also passed as `nil` but not trimmed. POST args and options are
	--JSON-decoded with all `null` values transformed into `nil`.
	--To make the API scriptable, errors are caught and sent to the client to
	--be re-raised in the Lua client (the JS client calls notify() for them).
	--Because the API is for both JS and Lua to consume, we don't support
	--multiple return values (you have to return arrays instead).
	local args = extend(pack(...), post and post.args)
	local opt = post and post.options or empty
	ownthreadenv().debug   = opt.debug
	ownthreadenv().verbose = opt.verbose
	local prev_term = set_current_terminal(out_term)
	local ok, ret = pcall(handler, opt, unpack(args))
	if not ok then
		local ret = tostring(ret)
		log('ERROR', 'mm', 'api', '%s', ret)
		out_term:notify_error('%s', ret)
	elseif ret ~= nil then
		out_term:send_on('r', json_encode(ret))
	end
	set_current_terminal(prev_term)
end

--web api / client for cmdline API -------------------------------------------

local function call_api(action, opt, ...)
	local retval
	local term = null_terminal():pipe(current_terminal())
	function term:receive_on(chan, s)
		if chan == 'e' then
			raise('mm', '%s', s) --no stacktrace
		elseif chan == 'r' then
			retval = json_decode(s)
		else
			assertf(false, 'invalid channel: "%s"', chan)
		end
	end
	local write = streaming_terminal_reader(term)
	local function receive_content(req, in_buf, sz)
		if not in_buf then --eof
			--
		else
			write(in_buf, sz)
		end
	end
	local function headers_received(res)
		check('mm', 'api-call', res.status == 200,
			'http error: %d %s', res.status, res.status_message) --bug?
	end
	local opt = update({ --pass verbosity to server
		debug   = repl(logging.debug  , false),
		verbose = repl(logging.verbose, false),
	}, opt)
	local ret, res = getpage{
		host  = config'mm_host',
		port  = config'mm_port',
		https = config'mm_https',
		uri = url_format{segments = {'', 'api.txt', action}},
		headers = {
			cookie = {
				session = config'session_cookie',
			},
		},
		method = 'POST',
		upload = {options = opt, args = json_pack(...)},
		receive_content = receive_content,
		headers_received = headers_received,
	}
	assertf(ret ~= nil, '%s', res)
	return retval
end

local function call_json_api(opt, action, ...)

	if opt ~= nil and not istab(opt) then --action, ...
		return call_json_api(empty, opt, action, ...)
	end
	opt = repl(opt, nil, empty)

	local ret, res = getpage{
		host  = config'mm_host',
		port  = config'mm_port',
		https = config'mm_https',
		uri = url_format{
			segments = {n = select('#', ...) + 2, '', action, ...},
			args = opt.args,
		},
		headers = {
			cookie = {
				session = config'session_cookie',
			},
		},
		upload = opt.upload,
	}
	assertf(ret ~= nil, '%s', res)
	assertf(res.status == 200, 'http error: %d %s', res.status, res.status_message)
	assertf(istab(ret), 'invalid JSON rsponse: %s', res.rawcontent)

	return ret
end

--Lua+web+cmdline api generator ----------------------------------------------

local function from_server()
	return config'mm_host' and not server_running
end

local function pass_opt(opt, ...) --pass an optional options table at arg#1
	if opt ~= nil and not istab(opt) then
		return empty, opt, ...
	else
		return repl(opt, nil, empty), ...
	end
end
local api = setmetatable({}, {__newindex = function(_, name, fn)
	local api_name = name:gsub('_', '-')
	mm[name] = function(opt, ...)
		if from_server() then
			return call_api(api_name, pass_opt(opt, ...))
		end
		return fn(pass_opt(opt, ...))
	end
	mm_api[name] = fn
end})

local function wrap(fn)
	return function(...)
		local ok, ret = pcall(fn, ...)
		if ok then return ret end --handlers can return an explicit exit code.
		die('%s', ret)
	end
end
local cmd_ssh_keys    = cmdsection('SSH KEY MANAGEMENT', wrap)
local cmd_ssh         = cmdsection('SSH TERMINALS'     , wrap)
local cmd_ssh_tunnels = cmdsection('SSH TUNNELS'       , wrap)
local cmd_ssh_mounts  = cmdsection('SSH-FS MOUNTS'     , wrap)
local cmd_files       = cmdsection('FILES'             , wrap)
local cmd_mysql       = cmdsection('MYSQL'             , wrap)
local cmd_machines    = cmdsection('MACHINES'          , wrap)
local cmd_deploys     = cmdsection('DEPLOYMENTS'       , wrap)
local cmd_mbk         = cmdsection('MACHINE-LEVEL BACKUP & RESTORE', wrap)
local cmd_dbk         = cmdsection('DEPLOYMENT-LEVEL BACKUP & RESTORE', wrap)
local cmd_tasks       = cmdsection('TASKS'             , wrap)

--task system ----------------------------------------------------------------

local function mm_task_init(self)
	if self.visible then
		rowset_changed'running_tasks'
		self:on('event', function(self, ev, source, ...)
			if source ~= self then return end
			rowset_changed'running_tasks'
		end)
		self.terminal:on('event', function(self, ev, source, ...)
			if source ~= self then return end
			rowset_changed'running_tasks'
		end)
		self:on('setstatus', function(self, ev, source_task, status)
			if source_task ~= self then return end
			if status == 'finished' then
				if not self.nolog then
					if not self.task_run then
						self.task_run = insert_row('task_run', {
							start_time = self.start_time,
							name = self.name,
							duration = self.duration,
							stdin = self.stdin,
							stdouterr = self:stdouterr(),
							exit_code = self.exit_code,
						}, nil, {quiet = true})
					else
						update_row('task_run', {
							self.task_run,
							duration = self.duration,
							stdouterr = self:stdouterr(),
							exit_code = self.exit_code,
						}, nil, nil, {quiet = true})
					end
				end
			end
		end)
	end
	if not self.bg then
		--release all db connections now in case this is a long running task.
		release_dbs()
	end
end

mm.task = task:subclass()
mm.exec = exec_task:subclass()

mm.task:after('init', mm_task_init)
mm.exec:after('init', mm_task_init)

local function cmp_start_time(t1, t2)
	return (t1.start_time or 0) < (t2.start_time or 0)
end

rowset.running_tasks = virtual_rowset(function(self)

	self.allow = 'admin'
	self.fields = {
		{name = 'id'        , 'id'},
		{name = 'pinned'    , 'bool'},
		{name = 'type'      , },
		{name = 'name'      , w = 200},
		{name = 'machine'   , hint = 'Machine(s) that this task affects'},
		{name = 'status'    , },
		{name = 'start_time', 'time_timeago'},
		{name = 'duration'  , 'duration', w = 20,
			hint = 'Duration till last change in input, output or status'},
		{name = 'stdin'     , hidden = true, maxlen = 16*1024^2},
		{name = 'out'       , hidden = true, maxlen = 16*1024^2},
		{name = 'exit_code' , 'double', w = 20},
		{name = 'notif'     , hidden = true, maxlen = 16*1024^2},
		{name = 'cmd'       , hidden = true, maxlen = 16*1024^2},
	}
	self.pk = 'id'
	self.rw_cols = 'pinned'

	local function task_row(task)
		return {
			task.id,
			task.pinned or false,
			task.type,
			task.name,
			task.machine,
			task.status,
			task.start_time,
			task.duration,
			task.stdin,
			task:stdouterr(),
			task.exit_code,
			cat(imap(task:notifications(), 'message'), '\n\n'),
			istab(task.cmd)
				and cmdline_quote_args(nil, unpack(task.cmd))
				or task.cmd,
		}
	end

	function self:load_rows(rs, params)
		local filter = params['param:filter']
		rs.rows = {}
		for task in sortedpairs(tasks, cmp_start_time) do
			if task.visible then
				add(rs.rows, task_row(task))
			end
		end
	end

	function self:load_row(row)
		local task = tasks_by_id[row['id:old']]
		return task and task_row(task)
	end

	function self:update_row(row)
		local task = tasks_by_id[row['id:old']]
		if not task then return end
		task.pinned = row.pinned
	end

	function self:delete_row(row)
		local task = tasks_by_id[row['id:old']]
		assert(task:kill())
	end

end)

function mm.print_running_tasks()
	mm.print_rowset('running_tasks', [[
		id
		type
		name
		machine
		deploy
		status
		start_time
		duration
		exit_code
		errors
	]])
end

function api.tail_running_task(opt, task_id)
	local task = checkarg(tasks_by_id[id_arg(task_id)], 'invalid task id: %s', task_id)
	NYI'tail'
end

cmd_tasks('t|tasks [ID]', 'Show running tasks', function(opt, task_id)
	if task_id then
		mm.tail_running_task(task_id)
	else
		mm.print_running_tasks()
	end
end)

rowset.task_runs = sql_rowset{
	allow = 'admin',
	select = [[
		select
			task_run   ,
			start_time ,
			name       ,
			duration   ,
			stdin      ,
			stdouterr  ,
			exit_code
		from
			task_run
	]],
	pk = 'task_run',
	hide_cols = 'stdin stdouterr',
}

--scheduled tasks ------------------------------------------------------------

rowset.scheduled_tasks = virtual_rowset(function(self)

	self.allow = 'admin'
	self.fields = {
		{name = 'sched_name'   , 'longstrid'},
		{name = 'task_name'    , 'longstrid'},
		{name = 'ctime'        , 'time_ctime'},
		--sched
		{name = 'start_hours'  , 'timeofday_in_seconds'},
		{name = 'run_every'    , 'duration', duration_format = 'long'},
		{name = 'active'       , 'bool1'},
		--stats
		{name = 'last_run'     , 'time_timeago'},
		{name = 'last_duration', 'duration'},
		{name = 'last_status'  , 'strid'},
		--child fks for cascade removal.
		{name = 'machine'      , 'strid'},
		{name = 'deploy'       , 'strid'},
	}
	self.pk = 'sched_name'

	local function sched_row(t)
		return {
			t.sched_name,
			t.task_name,
			t.ctime,
			t.start_hours,
			t.run_every,
			t.active,
			t.last_run,
			t.last_duration,
			t.last_status,
			t.machine,
			t.deploy,
		}
	end

	local function load_rows()
		local rows = {}
		for name, sched in sortedpairs(scheduled_tasks, cmp_ctime) do
			add(rows, sched_row(sched))
		end
		return rows
	end

	local function cmp_ctime(t1, t2)
		return t1.ctime < t2.ctime
	end
	function self:load_rows(rs, params)
		local filter = params['param:filter']
		rs.rows = load_rows()
	end

	function self:load_row(row)
		local name = row['sched_name:old']
		local t = scheduled_tasks[name]
		return t and sched_row(t)
	end

	function self:update_row(row)
		local name = row['sched_name:old']
		local t = scheduled_tasks[name]
		if not t then return end
		t.active = row.active
	end

	function self:delete_row(row)
		local name = row['sched_name:old']
		local t = scheduled_tasks[name]
		if not t then return end
		t.active = false
	end

end)

function mm.print_scheduled_tasks()
	mm.print_rowset('scheduled_tasks')
end

cmd_tasks('ts|task-schedule', 'Show task schedule', mm.print_scheduled_tasks)

local function load_tasks_last_run()
	for _, sched_name, last_run in each_row_vals[[
		select sched_name, last_run from task_last_run
	]] do
		local t = scheduled_tasks[sched_name]
		if t then t.last_run = last_run end
	end
end

--client rowset API ----------------------------------------------------------

function mm.get_rowset(name, filter)
	if from_server() then
		local call_opt = filter and {args = {filter = json_encode(filter)}}
		t = call_json_api(call_opt, 'rowset.json', name)
	else
		NYI'get_rowset'
	end
	mm.schema:resolve_types(t.fields)
	return t
end

--filter: {k1v1,k1v2,...} or {{k1v1,k1v2},{k1v3,k2v4},...} for composite pks.
function mm.print_rowset(opt, name, cols, filter)
	if opt ~= nil and not istab(opt) then
		return mm.print_rowset(nil, opt, name, cols, filter)
	end
	local t = mm.get_rowset(name or 'rowsets', filter)
	mysql_print_result(update({
		rows = t.rows, fields = t.fields,
		showcols = cols and cols:gsub(',', ' '),
	}, opt))
end
cmd('r|rowset [-cols=col1,...] [NAME] [KEY]', 'Show a rowset', function(opt, name, key)
	mm.print_rowset(name, opt.cols, key and {tonumber(key) or key})
end)

--client info api ------------------------------------------------------------

function api.active_machines()
	return (query'select machine from machine where active = 1')
end

function mm.each_machine(f, fmt, ...)
	local machines = mm.active_machines()
	local threads = sock.threadset()
	for _,machine in ipairs(machines) do
		resume(threads:thread(f, fmt, machine, ...), machine)
	end
	threads:wait()
end

--for each machine run a Lua API on the client-side.
local function callm(cmd, machine)
	if not machine then
		mm.each_machine(function(m)
			mm[cmd](m)
		end, cmd..' %s')
		return
	end
	mm[cmd](machine)
end

function api.deploy_info(opt, deploy)
	return checkfound(first_row([[
		select
			deploy,
			machine,
			mysql_pass,
			domain,
			app
		from deploy where deploy = ?
	]], checkarg(deploy, 'deploy required')), 'deploy not found')
end

function api.ip_and_machine(opt, md)
	local md = checkarg(md, 'machine or deploy required')
	local m = first_row('select machine from deploy where deploy = ?', md) or md
	local t = first_row('select machine, public_ip from machine where machine = ?', m)
	checkfound(t, 'machine not found: %s', m)
	checkfound(t.public_ip, 'machine does not have a public ip: %s', m)
	return {t.public_ip, m}
end
function mm.ip(md)
	return unpack(mm.ip_and_machine(md))
end
cmd_machines('ip MACHINE|DEPLOY', 'Get the IP address of a machine or deployment',
	function(opt, md)
		print((mm.ip(md)))
	end)

--ssh / host keys ------------------------------------------------------------

function sshcmd(cmd)
	return win and indir(mm.sshdir, cmd) or cmd
end

local function known_hosts_file()
	return varpath'known_hosts'
end
function api.known_hosts_file_contents()
	return load(known_hosts_file())
end
function mm.known_hosts_file()
	local file = known_hosts_file()
	if from_server() then
		save(file, mm.known_hosts_file_contents(), nil, '0600')
	end
	return file
end

local function gen_known_hosts_file()
	local t = {}
	for i, ip, s in each_row_vals[[
		select public_ip, ssh_hostkey
		from machine
		where ssh_hostkey is not null
		order by pos, ctime
	]] do
		add(t, s)
	end
	save(mm.known_hosts_file(), concat(t, '\n'), nil, '0600')
end

function api.ssh_hostkey_update(opt, machine)
	local ip, machine = mm.ip(machine)
	local s = mm.exec({
		sshcmd'ssh-keyscan', '-4', '-T', '2', '-t', 'rsa', ip
	}, {
		name = 'ssh_hostkey_update '..machine,
		out_stdout = false,
		out_stderr = false,
	}):stdout()
	assert(update_row('machine', {machine, ssh_hostkey = s}).affected_rows == 1)
	gen_known_hosts_file()
	notify('Host key updated for %s.', machine)
end
cmd_ssh_keys('ssh-hostkey-update MACHINE', 'Make a machine known again to us',
	mm.ssh_hostkey_update)

function api.ssh_hostkey(opt, machine)
	return checkfound(first_row([[
		select ssh_hostkey from machine where machine = ?
	]], checkarg(machine, 'machine required')), 'hostkey not found for machine: %s', machine):trim()
end
cmd_ssh_keys('ssh-hostkey MACHINE', 'Show a SSH host key', function(...)
	print(mm.ssh_hostkey(...))
end)

function api.ssh_hostkey_sha(opt, machine)
	machine = checkarg(machine, 'machine required')
	local key = first_row([[
		select ssh_hostkey from machine where machine = ?
	]], machine)
	local key = checkfound(key, 'hostkey not found for machine: %s', machine):trim()
	local task = mm.exec(sshcmd'ssh-keygen'..' -E sha256 -lf -', {
		stdin = key,
		out_stdout = false,
		name = 'ssh_hostkey_sha '..machine,
		nolog = true,
	})
	return (task:stdout():trim():match'%s([^%s]+)')
end
cmd_ssh_keys('ssh-hostkey-sha MACHINE', 'Show a SSH host key SHA', function(...)
	print(mm.ssh_hostkey_sha(...))
end)

--ssh / private keys ---------------------------------------------------------

local function keyfile(machine, ext)
	return varpath('mm'..(machine and '-'..machine or '')..'.'..(ext or 'key'))
end
function api.keyfile_contents(opt, machine, ext)
	return load(keyfile(machine, ext), false)
end
function mm.keyfile(machine, ext) --`mm ssh ...` gets it from the server
	local file = keyfile(machine, ext)
	if from_server() then
		local s = checkfound(mm.keyfile_contents(machine, ext),
			'SSH key file not found: %s', file)
		save(file, s, nil, '0600')
	end
	return file
end
function mm.ppkfile(machine) --`mm putty ...` gets it from the server
	return mm.keyfile(machine, 'ppk')
end

--run this to avoid getting the incredibly stupid "perms are too open" error from ssh.
function mm.ssh_key_fix_perms(opt, machine)
	local s = mm.keyfile(machine)
	if win then
		local function readpipe(...)
			local p = exec(_(...))
			p:wait()
			p:forget()
		end
		readpipe('icacls %s /c /t /Inheritance:d', s)
		readpipe('icacls %s /c /t /Grant %s:F', s, env'UserName')
		readpipe('takeown /F %s', s)
		readpipe('icacls %s /c /t /Grant:r %s:F', s, env'UserName')
		readpipe('icacls %s /c /t /Remove:g "Authenticated Users" BUILTIN\\Administrators BUILTIN Everyone System Users', s)
		readpipe('icacls %s', s)
	else
		chmod(s, '0600')
	end
	say'Perms fixed.'
end
cmd_ssh_keys('ssh-key-fix-perms [MACHINE]', 'Fix SSH key perms for VBOX',
	mm.ssh_key_fix_perms)

function mm.ssh_key_gen_ppk(machine)
	local key = mm.keyfile(machine)
	local ppk = mm.ppkfile(machine)
	local p76 = ' --ppk-param version=2'
		--^^included putty 0.76 has this (debian's putty-tools which is 0.70 doesn't).
	local cmd = win
		and fmt('%s /keygen %s /output=%s', indir(mm.bindir, 'winscp.com'), key, ppk)
		or fmt('%s %s -O private -o %s%s', indir(mm.bindir, 'puttygen'), key, ppk, p76)
	mm.exec(cmd, {
		name = 'ssh_key_gen_ppk'..(machine and ' '..machine or ''),
	})
	notify('PPK file generated: %s', ppk)
end

function mm.putty_session_update(md)
	if not win then return end
	local ip, m = mm.ip(md)
	local ppk = mm.ppkfile(m)
	local deploy = m ~= md and md or nil
	local hk, created = winapi.RegCreateKey('HKEY_CURRENT_USER',
		[[SimonTatham\PuTTY\Sessions\\]]..md)
	hk:set('HostName', (deploy or 'root')..'@'..ip)
	hk:set('PublicKeyFile', ppk)
	hk:close()
	notify('Putty session %s: %s', created and 'created' or 'updated', md)
end

function mm.putty_session_deploy_update(deploy)
	if not win then return end
	local hk = winapi.RegCreateKey('HKEY_CURRENT_USER',
		[[SimonTatham\PuTTY\Sessions\\]]..deploy)
	hk:set('HostName', deploy..'@'..ip)
	hk:set('PublicKeyFile', ppk)
	hk:close()
	notify('Putty session updated: %s', machine)
end

function mm.putty_session_exists(name)
	if not win then return false end
	local k, err = winapi.RegOpenKey('HKEY_CURRENT_USER',
		[[SimonTatham\PuTTY\Sessions\\]]..name)
	if k then k:close(); return true end
	assert(err == 'not_found')
	return false
end

function mm.putty_session_rename(old_name, new_name)
	if not win then return end
	if not mm.putty_session_exists(old_name) then return end
	local hk = winapi.RegCreateKey('HKEY_CURRENT_USER',
		[[SimonTatham\PuTTY\Sessions\\]])
	hk:rename_key(old_name, new_name)
	hk:close()
	notify('Putty session renamed: %s -> %s', old_name, new_name)
end

function mm.putty_session_remove(machine)
	if not win then return end
	local hk = winapi.RegCreateKey('HKEY_CURRENT_USER',
		[[SimonTatham\PuTTY\Sessions\\]])
	hk:remve_key(machine)
	hk:close()
	notify('Putty session removed: %s', machine)
end

function api.ssh_key_gen()
	rm(mm.keyfile())
	mm.exec({
		sshcmd'ssh-keygen', '-f', mm.keyfile(),
		'-t', 'rsa',
		'-b', '2048',
		'-C', 'mm',
		'-q',
		'-N', '',
	}, {
		name = 'ssh_key_gen',
	})
	rm(mm.keyfile()..'.pub') --we'll compute it every time.
	mm.ssh_key_fix_perms()
	mm.ssh_key_gen_ppk()
	rowset_changed'config'
	query'update machine set ssh_key_ok = 0'
	rowset_changed'machines'
	notify'SSH key generated.'
end
cmd_ssh_keys('ssh-key-gen', 'Generate a new SSH key', mm.ssh_key_gen)

function api.ssh_key_update(opt, machine)
	log('note', 'mm', 'upd-key', '%s', machine)
	local pubkey = mm.ssh_pubkey()
	stored_pubkey = mm.ssh_sh(machine, [=[
		#use ssh mysql user
		has_mysql && {
			mysql_update_pass localhost root "$MYSQL_ROOT_PASS"
			mysql_gen_my_cnf  localhost root "$MYSQL_ROOT_PASS"
		}
		ssh_pubkey_update mm "$PUBKEY"
		user_lock_pass root
		ssh_pubkey_for_user root mm  # print it so we can check it
	]=], {
		PUBKEY = pubkey,
		MYSQL_ROOT_PASS = mm.mysql_root_pass(),
	}, {
		name = 'ssh_key_update '..machine,
		out_stdout = false,
	}):stdout():trim()
	check500(stored_pubkey == pubkey, 'SSH public key NOT updated for: %s.', machine)

	cp(mm.keyfile(), mm.keyfile(machine))
	cp(mm.ppkfile(), mm.ppkfile(machine))
	mm.ssh_key_fix_perms(machine)
	mm.putty_session_update(machine)

	update_row('machine', {machine, ssh_key_ok = true})
	rowset_changed'machines'

	notify('SSH key updated for %s.', machine)
end
cmd_ssh_keys('ssh-key-update [MACHINE]', 'Update SSH key(s)', function(opt, machine)
	callm('ssh_key_update', machine)
end)

function api.ssh_key_check(opt, machine)
	local host_pubkey = mm.ssh_sh(machine, [[
		#use ssh
		ssh_pubkey_for_user root mm
	]], nil, {
		name = 'ssh_key_check '..(machine or ''),
		nolog = true,
		out_stdout = false,
	}):stdout():trim()
	local ok = host_pubkey == mm.ssh_pubkey()
	update_row('machine', {machine, ssh_key_ok = ok})
	rowset_changed'machines'
	if ok then
		notify('SSH key is up-to-date for %s.', machine)
	else
		notify_error('SSH key is NOT up-to-date for %s.', machine)
	end
end
cmd_ssh_keys('ssh-key-check [MACHINE]', 'Check that SSH keys are up-to-date',
	function(opt, machine)
		callm('ssh_key_check', machine)
	end)

--ssh / mysql passwords derived from private keys ----------------------------

function api.mysql_root_pass(opt, machine) --last line of the private key
	local file = mm.keyfile(machine)
	local s = checkfound(load(file, false), 'SSH key file not found: %s', file)
		:gsub('%-+.-PRIVATE%s+KEY%-+', ''):gsub('[\r\n]', ''):trim():sub(-32)
	assert(#s == 32)
	return s
end
cmd_mysql('mysql-root-pass [MACHINE]', 'Show the MySQL root password', function(...)
	print(mm.mysql_root_pass(...))
end)

function mm.mysql_pass(opt, deploy)
	return mm.deploy_info(opt, deploy).mysql_pass
end
cmd_mysql('mysql-pass DEPLOY', 'Show the MySQL password for an app', function(...)
	print(mm.mysql_pass(...))
end)

--ssh / public keys ----------------------------------------------------------

function api.ssh_pubkey(opt, machine)
	--NOTE: Windows ssh-keygen puts the key name at the end, but the Linux one doesn't.
	local s = mm.exec({
		sshcmd'ssh-keygen', '-y', '-f', mm.keyfile(machine),
	}, {
		name = catany(' ', 'ssh_pubkey ', machine), visible = false,
		out_stdout = false,
	}):stdout():trim()
	return (s:match('^[^%s]+%s+[^%s]+')..' mm')
end
cmd_ssh_keys('ssh-pubkey [MACHINE]', 'Show a/the SSH public key', function(...)
	print(mm.ssh_pubkey(...))
end)

--for manual updating via `curl mm.allegory.ro/pubkey/MACHINE >> authroized_keys`.
function action.pubkey(machine)
	setmime'txt' --TODO: disable html filter
	outall(mm.ssh_pubkey(machine))
end

--ssh / finally... -----------------------------------------------------------

--make repeated SSH invocations faster by reusing connections.
local function ssh_control_opts(tty)
	if not Linux then return end
	if not tty then return end --doesn't work when mm is daemonized!
	return
		'-o', 'ControlMaster=auto',
		'-o', 'ControlPath=~/.ssh/control-%h-%p-%r'..(tty and '-tty' or ''),
		'-o', 'ControlPersist=10'
end
function mm.ssh(md, cmd_args, opt)
	opt = opt or {}
	local ip, machine = mm.ip(md)
	opt.machine = machine
	return mm.exec(extend({
		sshcmd'ssh',
		not opt.tty and '-n' or nil,
		--^^prevent reading from stdin which doesn't work when mm is daemonized.
		opt.tty and '-t' or '-T',
		'-o', 'BatchMode=yes',
		'-o', 'ConnectTimeout=3',
		'-o', 'PreferredAuthentications=publickey',
		'-o', 'UserKnownHostsFile='..mm.known_hosts_file(),
		}, {ssh_control_opts(opt.tty)}, {
		'-i', mm.keyfile(machine),
		'root@'..ip
		}, cmd_args
	), update({
		capture_stdout = not opt.tty,
		capture_stderr = not opt.tty,
	}, opt))
end

--shell scripts with preprocessor --------------------------------------------

local function load_shfile(self, name)
	local path = indir(scriptdir(), 'shlib', name..'.sh')
	return load(path)
end

mm.shlib = {} --{name->code}
setmetatable(mm.shlib, {__index = load_shfile})

function mm.sh_preprocess(vars)
	return mustache.render(s, vars, nil, nil, nil, nil, cmdline_escape_unix)
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
		for s in words(s) do
			include_one(s)
		end
		return cat(t, '\n')
	end
	local function use(s)
		local t = {}
		for s in words(s) do
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
	s = env and cmdline_quote_vars(env, nil, 'unix')..'\n'..s or s
	if pp_env then
		return mm.sh_preprocess(s, pp_env)
	else
		return s
	end
end

--remote sh scripts with stdin injection -------------------------------------

--passing both the script and the script's expected stdin contents through
--ssh's stdin at the same time is only possible due to a ridiculous behavior
--that only bash could have: sh reads its input one-byte-at-a-time and
--stops reading exactly after the `exit` command, not one byte later, so
--we can feed in stdin right after that. worse-is-better at its finest.
function mm.ssh_sh(machine, script, script_env, opt)
	opt = opt or {}
	local script_env = update({
		DEBUG   = repl(threadenv().debug   , false),
		VERBOSE = repl(threadenv().verbose , false),
	}, script_env)
	local script_s = script:outdent()
	local s = mm.sh_script(script_s, script_env, opt.pp_env)
	opt.stdin = '{\n'..s..'\n}; exit'..(opt.stdin or '')
	if logging.debug then
		log('', 'mm', 'ssh-sh', '%s %s %s', machine, script_s:trim(), script_env)
	end
	return mm.ssh(machine, {'bash', '-s'}, opt)
end

--machine git keys update ----------------------------------------------------

local function git_hosting_vars()
	local vars = {}
	local names = {}
	for _,t in each_row[[
		select name, host, ssh_hostkey, ssh_key
		from git_hosting
	]] do
		for k,v in pairs(t) do
			vars[(t.name..'_'..k):upper()] = v
			names[t.name] = true
		end
	end
	vars.GIT_HOSTS = cat(keys(names, true), ' ')
	return vars
end

function api.git_keys_update(opt, machine)
	local vars = git_hosting_vars()
	mm.ssh_sh(machine, [=[
		#use ssh
		ssh_git_keys_update
	]=], vars, {
		name = 'git_keys_update '..(machine or ''),
	})
	notify('Git keys updated for: %s.', machine)
end
cmd_ssh_keys('git-keys-update [MACHINE]', 'Updage Git SSH keys',
	function(opt, machine)
		callm('git_keys_update', machine)
	end)

--remote access tools --------------------------------------------------------

function mm.ssh_cli(opt, mds, cmd, ...)
	if opt ~= nil and not istab(opt) then
		return mm.ssh_cli(empty, opt, mds, cmd, ...)
	end
	opt = repl(opt, nil, empty)
	if mds == 'ALL' then
		mds = mm.active_machines()
		cmd = checkarg(cmd, 'command required')
	else
		mds = collect(words(checkarg(mds, 'machine or deploy required'):gsub(',', ' ')))
	end
	local last_exit_code
	local cmd = catany(' ', cmd, ...)
	local bash_cmd = cmd and {'bash', '-c', "'"..cmd.."'"}
	for _,md in ipairs(mds) do
			local ip, m = mm.ip(md)
		if #mds > 1 then say('%s: `%s`', m, cmd) end
		local task = mm.ssh(md, bash_cmd, {
			allow_fail = true,
			tty = not cmd or opt.tty,
			capture_stdout = false,
			capture_stderr = false,
		})
		if task.exit_code ~= 0 then
			say('%s: exit code: %d', m, task.exit_code)
		end
		last_exit_code = task.exit_code
	end
	return last_exit_code
end
cmd_ssh('ssh ALL|MACHINE|DEPLOY,... [- CMD ...]', 'SSH to machine(s)', function(opt, mds, ...)
	return mm.ssh_cli(opt, mds, ...)
end)

local deploy_vars --fw. decl.

--TIP: make a putty session called `mm` where you set the window size,
--uncheck "warn on close" and whatever else you need to make worrking
--with putty comfortable for you.
cmd_ssh(Windows, 'putty [-shlib] MACHINE|DEPLOY', 'SSH into machine with putty',
function(opt, md)
	local ip, m = mm.ip(md)
	local deploy = m ~= md and md or nil
	local cmd = _('%s -load %s -t -i %s %s@%s',
		indir(mm.bindir, 'putty'),
		mm.putty_session_exists(md) and md or 'mm',
		mm.ppkfile(m),
		deploy and md or 'root',
		ip
	)
	if opt.shlib or deploy then
		local script
		if opt.shlib then
			local s = catany('\n',
				'#use deploy backup',
				deploy and 'must cd /home/$DEPLOY/$APP',
				deploy and 'VARS="DEBUG VERBOSE" run_as $DEPLOY bash'
			)
			local script_env = update({
				DEBUG   = env'DEBUG'   or '',
				VERBOSE = env'VERBOSE' or '',
			}, git_hosting_vars(), deploy and deploy_vars(deploy))
			script = mm.sh_script(s:outdent(), script_env)
		else
			local d = mm.deploy_info(deploy)
			script = catany('\n',
				deploy and 'cd /home/'..deploy..'/'..d.app..' || exit 1',
				deploy and 'sudo -u '..deploy..' bash'
			)
		end
		local s = catany('\n',
			'export MM_TMP_SH=/root/.mm.$$.sh',
			'cat << \'EOFFF\' > $MM_TMP_SH',
			'rm -f $MM_TMP_SH',
			script,
			'EOFFF',
			'exec bash --init-file $MM_TMP_SH'
		)
		local cmdfile = tmppath'puttycmd.txt'
		save(cmdfile, s)
		runafter(.5, function()
			rm(cmdfile)
		end)
		cmd = cmd..' -m '..cmdfile
	end
	exec(cmd):forget()
end)

cmd_files('ls [-l] [-a] MACHINE:DIR', 'Run `ls` on machine',
	function(opt, md_dir)
		local md, dir = split(':', md_dir)
		checkarg(md and dir, 'machine:dir expected')
		local args = {'ls', dir}
		for k,v in pairs(opt) do
			add(args, '-'..k)
		end
		mm.ssh_cli(md, unpack(args))
	end)

cmd_files('cat MACHINE:FILE', 'Run `cat` on machine',
	function(opt, md_file)
		local md, file = split(':', md_file)
		checkarg(md and file, 'machine:file expected')
		mm.ssh_cli(md, 'cat', file)
	end)

cmd_files('mc MACHINE [DIR]', 'Run `mc` on machine',
	function(opt, md, dir)
		mm.ssh_cli({tty = true}, md, 'mc', dir)
	end)

cmd_files('mcedit MACHINE:DIR', 'Run `mcedit` on machine',
	function(opt, md_file)
		local md, file = split(':', md_file)
		checkarg(md and file, 'machine:file expected')
		mm.ssh_cli({tty = true}, md, 'mcedit', file)
	end)

--TODO: accept NAME as in `[LPORT|NAME:][RPORT|NAME]`
function mm.tunnel(machine, ports, opt, rev)
	local args = {'-N'}
	if logging.debug then add(args, '-v') end
	ports = checkarg(ports, 'ports expected')
	local ts = {}
	for ports in ports:gmatch'([^,]+)' do
		local lport, rport = split(':', ports)
		rport = rport or ports
		lport = lport or ports
		local s = _('%s:%s %s %s', machine, rport, rev and '->' or '<-', lport)
		add(ts, s)
		add(args, rev and '-R' or '-L')
		if rev then lport, rport = rport, lport end
		add(args, '127.0.0.1:'..lport..':127.0.0.1:'..rport)
		log('note', 'mm', 'tunnel', '%s', s)
	end
	mm.ssh(machine, args, update({
		name = _('tunnel %s', cat(ts)),
		type = 'long',
		out_stdout = false, --suppress copyright noise
		restart_after = 1,
	}, opt))
end
function mm.rtunnel(machine, ports, opt)
	return mm.tunnel(machine, ports, opt, true)
end

cmd_ssh_tunnels('tunnel MACHINE [LPORT1:]RPORT1,...',
	'Create SSH tunnel(s) to machine',
	function(opt, machine, ports)
		mm.tunnel(machine, ports, {tty = true})
	end)

cmd_ssh_tunnels('rtunnel MACHINE [LPORT1:]RPORT1,...',
	'Create reverse SSH tunnel(s) to machine',
	function(opt, machine, ports)
		return mm.rtunnel(machine, ports, {tty = true})
	end)

cmd_mysql('mysql DEPLOY|MACHINE [SQL]',
	'Execute MySQL command or remote REPL',
	function(opt, md, sql)
		local ip, machine = mm.ip(md)
		local deploy = machine ~= md and md
		local args = {'mysql', '-h', 'localhost', '-u', 'root', deploy}
		if sql then append(args, '-e', cmdline_quote_arg_unix(sql)) end
		return mm.ssh(machine, args, {
			tty = not sql,
			capture_stdout = false,
			capture_stderr = false,
		})
	end)

--TODO: `sshfs.exe` is buggy in background mode: it kills itself when parent cmd is closed.
function mm.mount(opt, machine, rem_path, drive)
	if win then
		drive = drive or 'S'
		rem_path = rem_path or '/'
		local cmd =
			'"'..indir(mm.sshfsdir, 'sshfs.exe')..'"'..
			' root@'..mm.ip(machine)..':'..rem_path..' '..drive..':'..
			(opt.bg and '' or ' -f')..
			--' -odebug'.. --good stuff (implies -f)
			--these were copy-pasted from sshfs-win manager.
			' -oidmap=user -ouid=-1 -ogid=-1 -oumask=000 -ocreate_umask=000'..
			' -omax_readahead=1GB -oallow_other -olarge_read -okernel_cache -ofollow_symlinks'..
			--only cygwin ssh works. the builtin Windows ssh doesn't, nor does our msys version.
			' -ossh_command='..path_sep(indir(mm.sshfsdir, 'ssh'), nil, '/')..
			' -oBatchMode=yes'..
			' -oRequestTTY=no'..
			' -oPreferredAuthentications=publickey'..
			' -oUserKnownHostsFile='..path_sep(mm.known_hosts_file(), nil, '/')..
			' -oIdentityFile='..path_sep(mm.keyfile(machine), nil, '/')
		if opt.bg then
			exec(cmd)
		else
			mm.exec(cmd, {
				name = 'mount '..drive,
			})
		end
	else
		NYI'mount'
	end
end
cmd_ssh_mounts('mount [-bg] MACHINE PATH [DRIVE]', 'Mount remote path to drive', mm.mount)
cmd_ssh_mounts('mount-kill-all', 'Kill all background mounts', function()
	if win then
		exec'taskkill /f /im sshfs.exe'
	else
		NYI'mount_kill_all'
	end
end)

local function rsync_vars(src_machine, dst_machine)
	return {
		HOST = mm.ip(dst_machine),
		SSH_KEY = load(mm.keyfile(dst_machine)),
		SSH_HOSTKEY = mm.ssh_hostkey(dst_machine),
		SRC_MACHINE = src_machine,
		DST_MACHINE = dst_machine,
	}
end

function mm.rsync(opt, md1, md2)
	if isstr(opt) then opt, md1, md2 = empty, opt, md1 end
	md1 = str_arg(md1)
	md2 = str_arg(md2)
	local m1, d1 = split(':', md1)
	local m2, d2 = split(':', md2)
	if not (m1 or d1) then d1 = md1 end -- [SRC_MACHINE:]DIR
	if not (m2 or d2) then m2 = md2 end -- DST_MACHINE[:DIR]
	d2 = d2 or d1
	checkarg(d1, '[source:]dir required')
	if m1 and m2 then --remote-to-remote
		mm.ssh_sh(m1, [[
			#use ssh
			rsync_dir
		]], update({
			SRC_DIR = d1,
			DST_DIR = d2,
			PROGRESS = opt.progress and 1 or nil,
		}, rsync_vars(m1, m2)), {
			name = 'rsync '..m1..' '..m2,
			tty = opt.tty,
		})
	else
		local function local_rsync_path(d, is_src_path)
			if path_type(d) == 'rel' then --make path absolute
				d = indir(startcwd(), d)
			end
			--tell rsync to not create the full source path in the dest. dir.
			if is_src_path and file_is(d, 'dir') then
				d = d .. '/./.'
			else
				d = path_dir(d) .. '/./' ..  path_file(d)
			end
			if win then --convert Windows path to cygwin path
				local _, d_path, d_drive = path_parse(d)
		 		assertf(d_drive, 'not a Windows path: %s', d)
				d = path_normalize('/cygdrive/' .. d_drive .. d_path, nil,
					{sep = '/', dot_dirs = 'leave'})
			end
			return d, is_dir
		end
		local ssh_cmd = 'ssh'
			..' -q -o BatchMode=yes'
			..' -o PreferredAuthentications=publickey'
			..' -o UserKnownHostsFile='..path_sep(mm.known_hosts_file(), nil, '/')
			..' -i '..mm.keyfile(m1 or m2)
			..' '..cmdline_quote_args_unix(ssh_control_opts(opt.tty))
		if m2 then --upload
			local ip = mm.ip(m2)
			d1 = local_rsync_path(d1, true)
			out_stderr(_('Uploading\n\tsrc: %s\n\tdst: %s:%s ... \n', d1, m2, d2))
			mm.exec({
				sshcmd'rsync', '--delete', '--timeout=5',
				opt.progress and '--info=progress2' or nil,
				'-e', ssh_cmd, '-aHR', d1, 'root@'..ip..':/'..d2,
			}, {
				name = 'rsync upload-to '..m2,
				capture_stdout = not opt.tty,
				capture_stderr = not opt.tty,
			})
		elseif m1 then --download
			local ip = mm.ip(m1)
			d2 = local_rsync_path(d2)
			out_stderr(_('Downloading %s:%s to %s ... \n', m1, d1, d2))
			mm.exec({
				sshcmd'rsync', '--delete', '--timeout=5',
				opt.progress and '--info=progress2' or nil,
				'-e', ssh_cmd, '-aHR', 'root@'..ip..':/'..d1..'/./.', d2,
			}, {
				name = 'rsync download-from '..m1,
				capture_stdout = not opt.tty,
				capture_stderr = not opt.tty,
			})
		else
			NYI'local-to-local rsync'
		end
	end
end
cmd_files('rsync [-q] [SRC_MACHINE:]DIR [DST_MACHINE][:DIR]',
	'Sync directories between machines',
	function(opt, ...)
		opt.progress = not opt.q
		opt.tty = true
		mm.rsync(opt, ...)
	end)

function api.sha(opt, machine, dir)
	return mm.ssh_sh(machine, [[
		#use fs
		sha_dir "$DIR"
		]], {
			DIR = dir
		}, {
			name = 'sha '..machine,
			out_stdout = false,
		}
	):stdout():trim()
end
cmd_ssh_mounts('sha MACHINE DIR', 'Compute SHA of dir contents', function(...)
	print(mm.sha(...))
end)

--machine listing ------------------------------------------------------------

cmd_machines('m|machines', 'Show the list of machines', function(opt)
	mm.print_rowset('machines', [[
		machine
		active
		public_ip
		cpu_max
		ram_free
		hdd_free
		cores
		ram
		hdd
		cpu
		os_ver
		mysql_ver
		ctime
	]])
end)

--machine rename -------------------------------------------------------------

function api.machine_rename(opt, old_machine, new_machine)

	checkarg(new_machine, 'new_machine required')

	checkarg(not first_row([[
		select 1 from machine where machine = ?
	]], new_machine), 'machine already exists: %s', new_machine)

	mm.ssh_sh(old_machine, [=[
		#use deploy
		machine_rename "$OLD_MACHINE" "$NEW_MACHINE"
	]=], {
		OLD_MACHINE = old_machine,
		NEW_MACHINE = new_machine,
	}, {
		name = 'machine_rename '..old_machine,
	})

	if exists(mm.keyfile(old_machine)) then
		mv(mm.keyfile(old_machine), mm.keyfile(new_machine))
	end
	if exists(mm.ppkfile(old_machine)) then
		mv(mm.ppkfile(old_machine), mm.ppkfile(new_machine))
	end
	mm.putty_session_rename(old_machine, new_machine)

	update_row('machine', {old_machine, machine = new_machine})

	notify('Machine renamed from %s to %s.', old_machine, new_machine)
end
local machine_rename = mm.machine_rename
function mm.machine_rename(opt, old_machine, new_machine)
	machine_rename(opt, old_machine, new_machine)
	if from_server() then --remove old key files from the client.
		rm(keyfile(old_machine))
		rm(keyfile(old_machine, 'ppk'))
	end
end
cmd_machines('machine-rename OLD_MACHINE NEW_MACHINE',
	'Rename a machine',
	mm.machine_rename)

function api.update_machine_info(opt, machine)
	local task = mm.ssh_sh(machine, [=[
		#use machine
		machine_info
	]=], nil, {
		name = 'update_machine_info '..(machine or ''),
		nolog = true,
		out_stdout = false,
	})
	local stdout = task:stdout()
	local t = {machine = machine}
	for s in stdout:trim():lines() do
		local k,v = assert(s:match'^%s*(.-)%s+(.*)')
		add(t, k)
		t[k] = v
	end

	assert(query([[
		update machine set
			os_ver    = :os_ver,
			mysql_ver = :mysql_ver,
			cpu       = :cpu,
			cores     = :cores,
			ram       = :ram,
			hdd       = :hdd
		where
			machine = :machine
		]], t).affected_rows == 1)
	rowset_changed'machines'

	t.ram = kbytes(t.ram, 1)
	t.hdd = kbytes(t.hdd, 1)
	for i,k in ipairs(t) do
		out_stdout(_('%20s %s\n', k, t[k]))
	end
	notify('Machine info updated for %s.', machine)
end
cmd_machines('i|machine-info MACHINE', 'Show machine info', mm.update_machine_info)

--machine reboot -------------------------------------------------------------

function api.machine_reboot(opt, machine)
	mm.ssh(machine, {'reboot'}, {
		name = 'machine_reboot '..(machine or ''),
	})
	notify('Machine rebooted: %s.', machine)
end

--machine prepare ------------------------------------------------------------

function api.prepare(opt, machine)
	mm.ip(machine)
	local vars = git_hosting_vars()
	vars.MACHINE = machine
	vars.MYSQL_ROOT_PASS = mm.mysql_root_pass(machine)
	vars.DHPARAM = load(varpath'dhparam.pem')
	mm.ssh_sh(machine, [=[
		#use deploy
		machine_prepare
	]=], vars, {
		name = 'prepare '..machine,
	})
	mm.rsync(varpath'.acme.sh.etc/ca', machine..':/root/.acme.sh.etc/ca')
	notify('Machine prepared: %s.', machine)
end
cmd_machines('prepare MACHINE', 'Prepare a new machine', mm.prepare)

--acme ssl cert provisioning -------------------------------------------------

function api.acme_check(opt, machine)
	mm.ssh_sh(machine, [[
		#use deploy
		acme_check
	]], {
		name = 'acme_check '..machine,
	})
	notify('ACME check done for machine: %s', machine)
end
cmd_deploys('acme-check [MACHINE]', 'ACME check/renew SSL certificates',
	function(opt, machine)
		callm('acme_check', machine)
	end)

function api.deploy_issue_cert(opt, deploy)
	local d = mm.deploy_info(deploy)
	checkarg(d.domain, 'Domain not set for deploy: %s', deploy)
	local task = mm.ssh_sh(d.machine, [[
		#use deploy
		deploy_issue_cert "$DOMAIN"
	]], {
		DOMAIN = d.domain,
	}, {
		name = 'deploy_issue_cert '..deploy,
	})
	if task.exit_code ~= 0 then return task.exit_code end

	--save the cert locally so we can deploy on a diff. machine later.
	mm.rsync(d.machine..':/root/.acme.sh.etc/'..d.domain,
		':'..varpath('.acme.sh.etc', d.domain))

end
cmd_deploys('issue-ssl-cert DEPLOY',
	'Issue SSL certificate for an app',
	mm.deploy_issue_cert)

--deploy listing -------------------------------------------------------------

cmd_deploys('d|deploys', 'Show the list of deployments', function()
	mm.print_rowset('deploys', [[
		deploy
		active
		status
		machine
		cpu_max
		rss
		lua_heap
		active
		app
		env
		deployed_at
		started_at
		wanted_app_version=app_want deployed_app_version=app_depv deployed_app_commit=app_depc
		wanted_sdk_version=sdk_want deployed_sdk_version=sdk_depv deployed_sdk_commit=sdk_depc
	]])
end)

--deploy deploy --------------------------------------------------------------

--[[local]] function deploy_vars(deploy, new_deploy)

	deploy = checkarg(deploy, 'deploy required')

	local vars = {}
	for k,v in pairs(checkfound(first_row([[
		select
			d.machine,
			d.repo,
			d.app,
			d.wanted_app_version app_version,
			d.wanted_sdk_version sdk_version,
			if(d.deployed_app_commit is not null, 1, 0) deployed,
			coalesce(d.env, 'dev') env,
			d.domain,
			d.http_port,
			d.mysql_pass,
			d.secret
		from
			deploy d
		where
			deploy = ?
	]], deploy), 'invalid deploy "%s"', deploy)) do
		vars[k:upper()] = v
	end

	new_deploy = new_deploy or deploy
	vars.DEPLOY = new_deploy

	checkarg(vars.MACHINE, 'Machine not set for deploy: %s', new_deploy)

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

function api.deploy(opt, deploy, app_ver, sdk_ver)

	if config'deploy' == deploy then
		notify_error'Cannot self-deploy'
		return
	end

	if app_ver or sdk_ver then
		update_row('deploy', {
			deploy,
			wanted_app_version = app_ver,
			wanted_sdk_version = sdk_ver,
		})
	end

	local vars = deploy_vars(deploy)
	update(vars, git_hosting_vars())

	if vars.DOMAIN then
		local cert_dir = varpath('.acme.sh.etc', vars.DOMAIN)
		if exists(cert_dir) then
			mm.rsync(cert_dir, vars.MACHINE..':/root/.acme.sh.etc/'..vars.DOMAIN)
		else
			mm.deploy_issue_cert(deploy)
		end
	end

	local s = mm.ssh_sh(vars.MACHINE, [[
		#use deploy
		deploy
	]], vars, {
		name = 'deploy '..deploy,
		out_stdout = false,
	}):stdout()

	mm.putty_session_update(deploy)

	local app_commit = s:match'app_commit=([^%s]+)'
	local sdk_commit = s:match'sdk_commit=([^%s]+)'
	local now = time()
	update_row('deploy', {
		vars.DEPLOY,
		deployed_app_version = vars.VERSION,
		deployed_sdk_version = vars.SDK_VERSION,
		deployed_app_commit = app_commit,
		deployed_sdk_commit = sdk_commit,
		deployed_at = now,
		started_at = now,
	})
	rowset_changed'deploys'

	notify('Deployed: %s.', deploy)
end
cmd_deploys('deploy DEPLOY [APP_VERSION] [SDK_VERSION]', 'Deploy an app',
	mm.deploy)

--deploy remove --------------------------------------------------------------

function api.deploy_remove(opt, deploy)

	local vars = deploy_vars(deploy)
	mm.ssh_sh(vars.MACHINE, [[
		#use deploy
		deploy_remove "$DEPLOY"
	]], {
		DEPLOY = vars.DEPLOY,
		DOMAIN = vars.DOMAIN,
	}, {
		name = 'deploy_remove '..deploy,
	})

	mm.putty_session_remove(deploy)

	update_row('deploy', {
		vars.DEPLOY,
		deployed_app_version = null,
		deployed_sdk_version = null,
		deployed_app_commit  = null,
		deployed_sdk_commit  = null,
		deployed_at = null,
		started_at  = null,
	})
	rowset_changed'deploys'

	notify('Deploy removed: %s.', deploy)
end
cmd_deploys('deploy-remove DEPLOY', 'Remove a deployment',
	mm.deploy_remove)

--deploy rename --------------------------------------------------------------

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

function api.deploy_rename(opt, old_deploy, new_deploy)

	checkarg(new_deploy, 'new_deploy required')
	if new_deploy == old_deploy then return end
	local err = validate_deploy(new_deploy)
	checkarg(not err, err)

	local t = checkfound(first_row([[
		select deploy, machine from deploy where deploy = ?
	]], old_deploy), 'unknown deploy: %s', old_deploy)
	local machine = t.machine

	checkarg(not first_row([[
		select 1 from deploy where deploy = ?
	]], new_deploy), 'deploy already exists: %s', new_deploy)

	if machine then
		local vars = deploy_vars(old_deploy, new_deploy)
		mm.ssh_sh(machine, [=[
			#use deploy
			deploy_rename "$OLD_DEPLOY" "$NEW_DEPLOY"
		]=], update({
			OLD_DEPLOY = old_deploy,
			NEW_DEPLOY = new_deploy,
		}, vars), {
			name = 'deploy_rename '..old_deploy,
		})
		mm.putty_session_rename(old_deploy, new_deploy)
	end

	update_row('deploy', {old_deploy, deploy = new_deploy})

	notify('Deploy renamed from %s to %s.', old_deploy, new_deploy)
end
cmd_deploys('deploy-rename OLD_DEPLOY NEW_DEPLOY',
	'Rename a deployment (requires app restart)',
	mm.deploy_rename)

--deploy app run -------------------------------------------------------------

local function find_cmd(...)
	for i=1,select('#',...) do
		local s = select(i, ...)
		if not s:starts'-' then return s end
	end
end

function api.app(opt, deploy, ...)
	local vars = deploy_vars(deploy)
	local args = cmdline_quote_args_unix(...)
	local task_name = 'app '..deploy..' '..args
	local task = mm.ssh_sh(vars.MACHINE, [[
		#use deploy
		app $args
		]], {
			DEPLOY = vars.DEPLOY,
			APP = vars.APP,
			args = args,
		}, {
			name = task_name,
			allow_fail = true,
		})
	local ok = task.exit_code == 0
	if ok then
		local cmd = find_cmd(...)
		if cmd == 'start' or cmd == 'restart' then
			update_row('deploy', {deploy, started_at = time()})
			rowset_changed'deploys'
		end
	end
	if ok then
		notify(task:stderr())
	else
		notify_error((task:stderr():gsub('^ABORT: ', '')))
	end
end
cmd_deploys('app DEPLOY ...', 'Run a deployed app', mm.app)

--remote logging -------------------------------------------------------------

mm.log_port = 5555
mm.mysql_port = 3306

mm.deploy_logs = {queue_size = 10000} --{deploy->queue}
mm.deploy_procinfo_logs = {queue_size = 100} --{deploy->queue}
mm.machine_procinfo_logs = {queue_size = 100} --{machine->queue}
mm.deploy_state_vars = {} --{deploy->{var->val}}
local log_server_chan = {} --{deploy->mess_channel}

function queue_push(queues, k, msg)
	local q = queues[k]
	if not q then
		q = queue(queues.queue_size)
		q.next_id = 1
		queues[k] = q
	end
	if q:full() then
		q:pop()
	end
	msg.id = q.next_id
	q.next_id = q.next_id + 1
	q:push(msg)
end

local function update_deploys_live_state()
	local changed
	local now = time()
	for deploy, vars in pairs(mm.deploy_state_vars) do
		local t = vars.live
		local dt = t and max(0, now - t)
		local live_now = dt and dt < 3
		if (vars.live_now or false) ~= live_now then
			vars.live_now = live_now
			changed = true
		end
	end
	return changed
end

function mm.log_server(machine)

	local lport = first_row([[
		select log_local_port from machine where machine = ?
	]], checkarg(machine, 'machine required'))
	checkfound(lport, 'log_local_port not set for machine '..machine)

	local log_server, action_thread
	local function action()

		log_server = mess_listen('127.0.0.1', lport, function(mess, chan)

			local deploy

			resume(thread(function()
				while not chan:closed() do
					if deploy then
						mm.log_server_rpc(deploy, 'get_procinfo')
					end
					chan:wait(1)
				end
			end, 'log-server-get-procinfo %s', machine))

			chan:recvall(function(chan, msg)

				if not deploy then --first message identifies the client.
					deploy = msg.deploy or '<unknown>'
					log_server_chan[deploy] = chan
					log('note', 'mm', 'log-accpt', '%s', deploy)
				end
				msg.machine = machine
				if msg.event == 'set' then
					attr(mm.deploy_state_vars, deploy)[msg.k] = msg.v
					if msg.k == 'livelist' then
						rowset_changed'deploy_livelist'
					elseif msg.k == 'procinfo' then
						msg.v.time = msg.time
						queue_push(mm.deploy_procinfo_logs, deploy, msg.v)
						queue_push(mm.machine_procinfo_logs, machine, msg.v)
						--TODO: filter this on deploy
						rowset_changed('deploy_procinfo_log')
						--TODO: filter this on machine
						rowset_changed('machine_procinfo_log')
					elseif msg.k == 'profiler_started' then
						rowset_changed'deploys'
					elseif msg.k == 'profiler_output' then
						--TODO: filter this on deploy
						rowset_changed'deploy_profiler_output'
					end
				else
					queue_push(mm.deploy_logs, deploy, msg)
					rowset_changed'deploy_log'
				end

			end)

			log_server_chan[deploy] = nil

		end, nil, 'log-server-'..machine)

		action_thread = currentthread()
		suspend()
	end

	local task = mm.task({
		name = 'log_server '..machine,
		machine = machine,
		editable = false,
		type = 'long',
		action = action,
	})

	function task:do_kill()
		if log_server then
			log_server:stop()
		end
		if action_thread then
			resume(action_thread)
		end
	end

	task:start()

	return task
end

function mm.log_server_rpc(deploy, cmd, ...)
	local chan = log_server_chan[deploy]
	if not chan then return end
	chan:send(pack(cmd, ...))
	return true
end

function action.poll_livelist(deploy)
	allow(usr'roles'.admin)
	mm.log_server_rpc(deploy, 'poll_livelist')
end

rowset.deploy_log = virtual_rowset(function(self)
	self.allow = 'admin'
	self.fields = {
		{name = 'id'      , hidden = true},
		{name = 'time'    , 'time', max_w = 100},
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
				local log_queue = mm.deploy_logs[deploy]
				if log_queue then
					for msg in log_queue:items() do
						add(rs.rows, {
							msg.id,
							msg.time,
							msg.deploy,
							msg.severity,
							msg.module,
							msg.event,
							msg.message,
							msg.env,
						})
					end
				end
			end
		end
	end
end)

rowset.deploy_livelist = virtual_rowset(function(self)
	self.allow = 'admin'
	self.fields = {
		{name = 'deploy'},
		{name = 'type'},
		{name = 'id'},
		{name = 'descr', w = 500},
	}
	self.pk = ''
	function self:load_rows(rs, params)
		rs.rows = {}
		local deploys = params['param:filter']
		if deploys then
			for _, deploy in ipairs(deploys) do
				local vars = mm.deploy_state_vars[deploy]
				local livelist = vars and vars.livelist
				if livelist then
					local o_type  = livelist.o_type
					local o_id    = livelist.o_id
					local o_descr = livelist.o_descr
					for i = 1, #livelist, livelist.cols do
						local type  = livelist[i+o_type]
						local id    = livelist[i+o_id]
						local descr = livelist[i+o_descr]
						add(rs.rows, {deploy, type, id, descr})
					end
				end
			end
		end
		sort(rs.rows, function(r1, r2)
			local d1, t1, id1 = r1[1], r1[2], r1[3]
			local d2, t2, id2 = r2[1], r2[2], r2[3]
			if d1 ~= d2 then return d1 < d2 end
			if t1 ~= t2 then return t1 < t2 end
			return tonumber(id1:sub(2)) < tonumber(id2:sub(2))
		end)
	end
end)

rowset.deploy_profiler_output = virtual_rowset(function(self)
	self.allow = 'admin'
	self.fields = {
		{name = 'deploy'},
		{name = 'output'},
	}
	self.pk = 'deploy'
	function self:load_rows(rs, params)
		rs.rows = {}
		local deploys = params['param:filter']
		if deploys then
			for _,deploy in ipairs(deploys) do
				local vars = mm.deploy_state_vars[deploy]
				local s = vars and vars.profiler_output
				add(rs.rows, {deploy, s or ''})
			end
		end
	end
end)

function action.start_profiler(deploy, mode)
	allow(usr'roles'.admin)
	mm.log_server_rpc(deploy, 'start_profiler', mode)
end

function action.stop_profiler(deploy)
	allow(usr'roles'.admin)
	mm.log_server_rpc(deploy, 'stop_profiler')
end

rowset.deploy_procinfo_log = virtual_rowset(function(self)
	self.allow = 'admin'
	self.fields = {
		{name = 'deploy'},
		{name = 'clock'    , 'double'     , },
		{name = 'cpu'      , 'percent_int', text = 'CPU'},
		{name = 'cpu_sys'  , 'percent_int', text = 'CPU (kernel)'},
		{name = 'rss'      , 'filesize'   , text = 'RSS (Resident Set Size)', filesize_magnitude = 'M'},
		{name = 'ram_free' , 'filesize'   , text = 'RAM free (total)', filesize_magnitude = 'M'},
		{name = 'ram_size' , 'filesize'   , text = 'RAM size', hidden = true},
	}
	self.pk = ''
	function self:load_rows(rs, params)
		rs.rows = {}
		local deploys = params['param:filter']
		if deploys then
			local now = time()
			for _, deploy in ipairs(deploys) do
				local log_queue = mm.deploy_procinfo_logs[deploy]
				if log_queue then
					local utime0
					local stime0
					local clock0
					for i = -80, 0 do
						local t = log_queue:item_at(log_queue:count() + i)
						if t then
							local clock = t.time - now
							if clock0 then
								local dt = (clock - clock0)
								local up = max(0, (t.utime - utime0) / dt)
								local sp = max(0, (t.stime - stime0) / dt)
								add(rs.rows, {
									deploy,
									clock,
									up + sp,
									up,
									t.rss,
									t.ram_free + t.rss,
									t.ram_size,
								})
							end
							utime0 = t.utime
							stime0 = t.stime
							clock0 = clock
						end
					end
				end
			end
		end
	end
end)

rowset.machine_procinfo_log = virtual_rowset(function(self)
	self.allow = 'admin'
	self.fields = {
		{name = 'machine'},
		{name = 'clock'        , 'double'     , },
		{name = 'max_cpu'      , 'percent_int', text = 'Max CPU'},
		{name = 'max_cpu_sys'  , 'percent_int', text = 'Max CPU (kernel)'},
		{name = 'avg_cpu'      , 'percent_int', text = 'Avg CPU'},
		{name = 'avg_cpu_sys'  , 'percent_int', text = 'Avg CPU (kernel)'},
		{name = 'ram_used'     , 'filesize'   , filesize_magnitude = 'M', text = 'RAM Used'},
		{name = 'hdd_used'     , 'filesize'   , filesize_magnitude = 'M', text = 'Disk Used'},
		{name = 'ram_size'     , 'filesize'   , filesize_magnitude = 'M', text = 'RAM Size'},
		{name = 'hdd_size'     , 'filesize'   , filesize_magnitude = 'M', text = 'Disk Size'},
	}
	self.pk = ''
	function self:load_rows(rs, params)
		rs.rows = {}
		local machines = params['param:filter']
		if machines then
			for _, machine in ipairs(machines) do
				local log_queue = mm.machine_procinfo_logs[machine]
				if log_queue then
					local max_ttime0
					local max_stime0
					local avg_ttime0
					local avg_stime0
					local clock0
					for i = -80, 0 do
						local t = log_queue:item_at(log_queue:count() + i)
						if t then
							local max_ttime = 0
							local max_stime = 0
							local sum_ttime = 0
							local sum_stime = 0
							for cpu_num, t in ipairs(t.cputimes) do
								local ttime = t.user + t.nice + t.sys
								local stime = t.sys
								max_ttime = max(max_ttime, ttime)
								max_stime = max(max_stime, stime)
								sum_ttime = sum_ttime + ttime
								sum_stime = sum_stime + stime
							end
							avg_ttime = sum_ttime / #t.cputimes
							avg_stime = sum_stime / #t.cputimes
							if clock0 then
								local dt = (t.clock - clock0)
								local max_tp = (max_ttime - max_ttime0) / dt
								local max_sp = (max_stime - max_stime0) / dt
								local avg_tp = (avg_ttime - avg_ttime0) / dt
								local avg_sp = (avg_stime - avg_stime0) / dt
								add(rs.rows, {
									machine,
									i,
									max_tp, max_sp,
									avg_tp, avg_sp,
									t.ram_size - t.ram_free,
									t.hdd_size - t.hdd_free,
									t.ram_size,
									t.hdd_size,
								})
							end
							max_ttime0 = max_ttime
							max_stime0 = max_stime
							avg_ttime0 = avg_ttime
							avg_stime0 = avg_stime
							clock0 = t.clock
						else
							add(rs.rows, {machine, i})
						end
					end
				end
			end
		end
	end
end)

rowset.machine_ram_log = virtual_rowset(function(self)
	self.allow = 'admin'
	self.fields = {
		{name = 'machine'},
		{name = 'clock'},
	}
	self.pk = ''
	function self:load_rows(rs, params)
		rs.rows = {}
		local machines = params['param:filter']
		if machines then
			for _, machine in ipairs(machines) do
				local log_queue = mm.machine_procinfo_logs[machine]
				if log_queue then
					local utime0 = 0
					local stime0 = 0
					local clock0 = 0
					for i = -60, 0 do
						local t = log_queue:item_at(log_queue:count() + i)
						if t then
							local dt = (t.clock - clock0)
							local up = (t.utime - utime0) / dt
							local sp = (t.stime - stime0) / dt
							add(rs.rows, {machine, i, up + sp, up, t.rss})
							utime0 = t.utime
							stime0 = t.stime
							clock0 = t.clock
						else
							add(rs.rows, {machine, i})
						end
					end
				end
			end
		end
	end
end)

function api.deploy_http_kill_all(opt, deploy)
	allow(usr'roles'.admin)
	local ok = mm.log_server_rpc(deploy, 'close_all_sockets')
	notify('HKA %s: %s', deploy, ok)
end
cmd_deploys('hka|http-kill-all DEPLOY', 'Kill all HTTP connections', function(opt, deploy)
	mm.deploy_http_kill_all(deploy)
end)

--mysql monitoring -----------------------------------------------------------

local mysql_stats_rowset = {
	allow = 'admin',
	select = [[
		select
			schema_name,
			digest,
			lower(replace(
				if(length(digest_text) > 256,
					concat(left(digest_text, 200), ' ... ', right(digest_text, 56)),
					digest_text
				), '`', '')) as query,
			if(sum_no_good_index_used > 0 or sum_no_index_used > 0, 1, 0) as full_scan,
			count_star as exec_count,
			cast(sum_timer_wait/1000000000000 as double) as exec_time_total,
			cast(max_timer_wait/1000000000000 as double) as exec_time_max,
			cast(avg_timer_wait/1000000000000 as double) as exec_time_avg,
			cast(1000000000000/avg_timer_wait as double) as qps_avg,
			sum_rows_sent as rows_sent,
			cast(round(sum_rows_sent / count_star) as double) rows_sent_avg,
			sum_rows_examined as rows_scanned
		from
			performance_schema.events_statements_summary_by_digest
	]],
	pk = 'schema_name digest',
	order_by = 'sum_timer_wait desc',
	limit = 20,
	field_attrs = {
		query = {w = 400},
		exec_count      = {w = 40},
		exec_time_total = {w = 60, decimals = 2},
		exec_time_max   = {w = 60, decimals = 2},
		exec_time_avg   = {w = 60, decimals = 2},
		qps_avg         = {w = 60, decimals = 0},
		full_scan       = {'bool'},
	},
	hide_cols = 'digest',
	db = function(params)
		local machines = params['param:filter']
		local machine = checkarg(machines and machines[1], 'machine required')
		return db(machine)
	end,
}

rowset.machine_mysql_stats = sql_rowset(mysql_stats_rowset)

rowset.deploy_mysql_stats = sql_rowset(update(mysql_stats_rowset, {
	where_all = 'schema_name = :deploy',
	db = function(params)
		local deploys = params['param:filter']
		local deploy = checkarg(deploys and deploys[1], 'deploy required')
		local machine = checkarg(first_row([[
			select machine from deploy where deploy = ?
		]], deploy), 'invalid deploy')
		params.deploy = deploy
		return db(machine)
	end,
}))

cmd_mysql('mysql-stats MACHINE|DEPLOY', 'Print MySQL query statistics', function(opt, md)
	local _, m = mm.ip(md)
	local opt = {
		hidecols = 'digest',
		maxsizes = {query = 60},
		colmap = {schema_name = 'db'},
	}
	if m ~= md then --deploy
		mm.print_rowset(opt, 'deploy_mysql_stats', nil, {md})
	else
		mm.print_rowset(opt, 'machine_mysql_stats', nil, {m})
	end
end)

--machine backups ------------------------------------------------------------

rowset.machine_backups = sql_rowset{
	allow = 'admin',
	select = [[
		select
			b.mbk       ,
			b.machine    ,
			b.parent_mbk,
			b.start_time ,
			b.duration   ,
			b.checksum   ,
			b.note
		from mbk b
	]],
	where_all = 'b.machine in (:param:filter)',
	pk = 'mbk',
	parent_col = 'parent_mbk',
	tree_col = 'machine',
	update_row = function(self, row)
		self:update_into('mbk', row, 'note')
	end,
	delete_row = function(self, row)
		mm.machine_backup_remove(row['mbk:old'])
	end,
}

rowset.machine_backup_deploys = sql_rowset{
	allow = 'admin',
	select = [[
		select
			mbk,
			deploy,
			app_version,
			sdk_version,
			app_commit,
			sdk_commit
		from
			mbk_deploy
	]],
	where_all = 'mbk in (:param:filter)',
	pk = 'mbk deploy',
	delete_row = function(self, row)
		mm.machine_backup_remove(row['mbk:old'])
	end,
}

rowset.machine_backup_copies = sql_rowset{
	allow = 'admin',
	select = [[
		select
			mbk_copy,
			mbk,
			parent_mbk_copy,
			machine,
			start_time,
			size,
			duration
		from
			mbk_copy
	]],
	where_all = 'mbk in (:param:filter)',
	pk = 'mbk_copy',
	delete_row = function(self, row)
		mm.machine_backup_copy_remove(row['mbk_copy:old'])
	end,
}

function api.print_machine_backups(opt, machine)
	local rows, cols = query({
		compact=1,
	}, [[
		select
			c.mbk_copy  copy,
			c.parent_mbk_copy `from`,
			b.note,
			b.machine    `of`,
			c.machine    `in`,
			b.start_time `made`,
			group_concat(
				concat(
					d.deploy
					, coalesce(concat('/', d.app_version), '')
					, coalesce(concat('=', d.app_commit ), '')
				) separator ' '
			) as contents,
			b.mbk        mbk,
			c.size,
			b.duration    bkp_took,
			c.duration    copy_took
		from mbk b
		left join mbk_copy c on c.mbk = b.mbk
		left join mbk_deploy d on d.mbk = b.mbk
		#if machine
		where
			b.machine = :machine
		#endif
		group by
			b.mbk, c.mbk_copy
		order by
			c.mbk_copy
	]], {machine = machine})
	checkfound(not machine or #rows > 0, 'machine not found: %s', machine)
	mysql_print_result{
		rows = rows,
		fields = cols,
		size = 'sum',
		made = 'max',
		bkp_took = 'max',
		copy_took = 'max',
		print = out_stdout_print,
	}
end
cmd_mbk('mbk|machine-backups MACHINE', 'Show machine backups', mm.print_machine_backups)

local function parse_backup_info(s)
	local size, checksum = s:match'^([^%s]+)%s+([^%s]+)'
	size, checksum = tonumber(size), str_arg(checksum)
	assert(size)
	assert(checksum)
	return size, checksum
end

function api.machine_backup(opt, machine, note, parent_mbk_copy, dest_machines)

	machine = checkarg(machine, 'machine required')

	if parent_mbk_copy == 'latest' then
		--find the local copy of the latest backup of the machine that has one.
		parent_mbk_copy = checkarg(first_row([[
			select c.mbk_copy from mbk_copy c, mbk b
			where c.mbk = b.mbk and b.machine = :machine and c.machine = :machine
			order by c.mbk desc limit 1
		]], {machine = machine}), 'no local backup of machine "%s" found for "latest"', machine)
	elseif parent_mbk_copy then
		parent_mbk_copy = checkarg(id_arg(parent_mbk_copy), 'invalid backup copy')
	end

	local parent_mbk = parent_mbk_copy and checkarg(first_row([[
		select c.mbk from mbk_copy c, mbk b
		where c.mbk = b.mbk and c.mbk_copy = ? and b.machine = ?
	]], parent_mbk_copy, machine), 'parent backup copy not of the same machine')

	local task_name = 'machine_backup '..machine
	check500(not mm.running_task(task_name), 'already running: %s', task_name)

	local start_time = time()

	local mbk = insert_row('mbk', {
		parent_mbk = parent_mbk,
		machine = machine,
		note = note,
		start_time = start_time,
	})
	rowset_changed'machine_backups'

	query([[
		insert into mbk_deploy (
			mbk         ,
			deploy      ,
			app_version ,
			sdk_version ,
			app_commit  ,
			sdk_commit
		) select
			?,
			deploy,
			deployed_app_version ,
			deployed_sdk_version ,
			deployed_app_commit  ,
			deployed_sdk_commit
		from
			deploy
		where
			machine = ?
			and deployed_at is not null
	]], mbk, machine)

	local mbk_copy = insert_row('mbk_copy', {
		mbk = mbk,
		parent_mbk_copy = parent_mbk_copy,
		machine = machine,
		start_time = start_time,
	})
	rowset_changed'machine_backup_copies'

	local task = mm.ssh_sh(machine, [[
		#use backup
		machine_backup "$mbk" "$PARENT_mbk"
	]], {
		mbk = mbk,
		PARENT_mbk = parent_mbk,
	}, {
		name = task_name,
		out_stdout = false,
	})

	local size, checksum = parse_backup_info(task:stdout())

	update_row('mbk', {
		mbk,
		duration = task.duration,
		checksum = checksum,
	})
	rowset_changed'machine_backups'

	update_row('mbk_copy', {
		mbk_copy,
		duration = 0,
		size = size,
	})
	rowset_changed'machine_backup_copies'

	mm.machine_backup_copy(opt, mbk_copy, dest_machines)

	notify('Machine backup done for %s.', machine)
end
cmd_mbk('mbk-backup MACHINE [NOTE] [UP_COPY] [MACHINE1,...]',
	'Backup a machine', mm.machine_backup)

local function mbk_copy_info(mbk_copy)
	return checkfound(first_row([[
		select
			c.mbk_copy,
			b.mbk,
			b.parent_mbk,
			c.machine,
			c.duration,
			c.size,
			b.checksum
		from mbk_copy c
		inner join mbk b on c.mbk = b.mbk
		where c.mbk_copy = ?
	]], mbk_copy), 'backup copy not found')
end

function api.machine_backup_copy(opt, src_mbk_copy, dest_machines)

	src_mbk_copy = checkarg(id_arg(src_mbk_copy), 'backup copy required')

	local function copy(src_mbk_copy, dest_machine)

		local c = mbk_copy_info(src_mbk_copy)

		checkarg(dest_machine ~= c.machine,
			'Cannot copy backup copy %d from machine %s to the same machine.',
				src_mbk_copy, c.machine)

		checkarg(c.duration,
			'Backup copy %d is not complete (didn\'t finish)',
				src_mbk_copy)

		checkarg(first_row([[
			select machine from machine
			where active = 1 and machine = ?
		]], dest_machine), 'invalid destination machine: %s', dest_machine)

		local parent_mbk_copy

		if c.parent_mbk then

			--find the parent_mbk's copy on the destination machine.
			parent_mbk_copy = first_row([[
				select mbk_copy from mbk_copy
				where mbk = ? and machine = ? and duration is not null
			]], c.parent_mbk, dest_machine)

			if not parent_mbk_copy then

				--copy the parent_mbk to the destination machine.
				local src_parent_mbk_copy = first_row([[
					select mbk_copy from mbk_copy
					where mbk = ? and machine = ?
				]], c.parent_mbk, c.machine)

				parent_mbk_copy = copy(src_parent_mbk_copy, dest_machine)
			end
		end

		local mbk_copy = insert_or_update_row('mbk_copy', {
			mbk = c.mbk,
			parent_mbk_copy = parent_mbk_copy,
			machine = dest_machine,
			start_time = time(),
		})
		rowset_changed'machine_backup_copies'

		local task = mm.ssh_sh(c.machine, [[
			#use ssh backup
			machine_backup_copy "$mbk" "$parent_mbk"
		]], update({
			mbk = c.mbk,
			parent_mbk = c.parent_mbk,
		}, rsync_vars(c.machine, dest_machine)), {
			name = 'machine_backup_copy '..src_mbk_copy..' '..dest_machine,
			out_stdour = false,
		})

		mm.machine_backup_copy_check(opt, mbk_copy)

		update_row('mbk_copy', {
			mbk_copy,
			duration = task.duration,
		})
		rowset_changed'machine_backup_copies'

		notify('Machine backup copy %d copied to %s as backup copy %d.',
			src_mbk_copy, dest_machine, mbk_copy)
	end

	local dm
	if not dest_machines then

		local machine = checkarg(first_row([[
			select machine from mbk_copy where mbk_copy = ?
		]], src_mbk_copy), 'backup copy not found: %d', src_mbk_copy)

		dm = query([[
			select dest_machine
			from machine_backup_copy_machine
			where machine = ?
		]], machine)

		checkfound(#dm > 0, 'no copy machines for backups of machine: %s', machine)
	else
		dm = collect(words(dest_machines:gsub(',', ' ')))
	end

	if #dm == 1 then
		copy(src_mbk_copy, dm[1])
	else
		local errs = {}
		for _,dest_machine in ipairs(dm) do
			local ok, err = pcall(copy, src_mbk_copy, dest_machine)
			if not ok then add(errs, tostring(err)) end
		end
		check500(#errs == 0, cat(errs, '\n'))
	end
end
cmd_mbk('mbk-copy COPY [MACHINE1,...]', 'Copy a machine backup', mm.machine_backup_copy)

function api.machine_backup_copy_check(opt, mbk_copy)
	local c = mbk_copy_info(mbk_copy)
	local task = mm.ssh_sh(c.machine, [[
		#use backup
		machine_backup_info "$mbk"
	]], {
		mbk = c.mbk,
	}, {
		name = 'machine_backup_info '..c.mbk_copy,
		out_stdout = false,
	})
	local size, checksum = parse_backup_info(task:stdout())
	check500(checksum == c.checksum, 'Machine backup copy %d from %s BAD CHECKSUM:'
		..'\n  expected: %s\n  computed: %s',
		c.mbk_copy, c.machine,
		c.checksum, checksum)

	update_row('mbk_copy', {c.mbk_copy, size = size})
	rowset_changed'machine_backup_copies'

	notify('Machine backup copy %d from %s checksum OK. Backup copy size: %s.',
		c.mbk_copy, c.machine, kbytes(size))
end
cmd_mbk('mbk-check COPY', 'Check a machine backup\'s integrity', mm.machine_backup_copy_check)

function api.machine_backup_copy_remove(opt, mbk_copy)

	mbk_copy = checkarg(id_arg(mbk_copy), 'backup copy required')

	local function remove(mbk_copy)

		local c = mbk_copy_info(mbk_copy)

		--remove this backup copy's children recursively first.
		for _,mbk_copy in each_row_vals([[
			select mbk_copy from mbk_copy where parent_mbk_copy = ?
		]], mbk_copy) do
			remove(mbk_copy)
		end

		mm.ssh_sh(c.machine, [[
			#use backup
			machine_backup_remove "$mbk"
		]], {
			mbk = c.mbk,
		}, {
			name = 'machine_backup_remove '..mbk_copy,
		})

		delete_row('mbk_copy', {mbk_copy})
		rowset_changed'machine_backup_copies'

		local backup_removed
		if first_row('select count(1) from mbk_copy where mbk = ?', c.mbk) == 0 then
			delete_row('mbk', {c.mbk})
			rowset_changed'machine_backups'
			backup_removed = true
		end

		return backup_removed
	end

	local backup_removed = remove(mbk_copy)

	notify('Backup copy removed: %s.%s.', mbk_copy,
		backup_removed and ' That was the last copy of the backup.' or '')
end
cmd_mbk('mbk-remove COPY1[-COPY2],...', 'Remove machine backup copies', function(copies)
	checkarg(copies, 'backup copy required')
	for s in words(copies:gsub(',', ' ')) do
		local mbk_copy1, mbk_copy2 = split(s:find'%-' and '-' or '..', s)
		mbk_copy1 = checkarg(id_arg(mbk_copy1 or s), 'invalid backup copy')
		mbk_copy2 = checkarg(id_arg(mbk_copy2 or s), 'invalid backup copy')
		for mbk_copy = min(mbk_copy1, mbk_copy2), max(mbk_copy1, mbk_copy2), 1 do
			mm.machine_backup_copy_remove(opt, mbk_copy)
		end
	end
end)

function api.machine_restore(opt, mbk_copy)

	local c = mbk_copy_info(mbk_copy)

	mm.ssh_sh(c.machine, [[
		#use backup
		machine_restore "$mbk"
	]], {
		mbk = c.mbk,
	}, {
		name = 'machine_restore '..c.machine,
	})

	query[[
		#
	]]

end
cmd_mbk('mbk-restore COPY', 'Restore a machine', mm.machine_restore)

--deploy backups -------------------------------------------------------------

rowset.deploy_backups = sql_rowset{
	allow = 'admin',
	select = [[
		select
			dbk        ,
			deploy     ,
			start_time ,
			note       ,
			duration   ,
			checksum
		from dbk
	]],
	where_all = 'deploy in (:param:filter)',
	pk = 'dbk',
	update_row = function(self, row)
		self:update_into('dbk', row, 'note')
	end,
	delete_row = function(self, row)
		mm.deploy_backup_remove(row['dbk:old'])
	end,
}

rowset.deploy_backup_copies = sql_rowset{
	allow = 'admin',
	select = [[
		select
			dbk_copy,
			dbk,
			machine,
			start_time,
			duration
		from
			dbk_copy
	]],
	pk = 'dbk_copy',
	where_all = 'dbk in (:param:filter)',
	delete_row = function(self, row)
		mm.deploy_backup_copy_remove(row['dbk_copy:old'])
	end,
}

function api.print_deploy_backups(opt, deploy)
	local rows, cols = query({
		compact=1,
	}, [[
		select
			c.dbk_copy,
			b.deploy,
			b.note,
			b.deploy `of`,
			c.machine `in`,
			b.start_time  `made`,
			b.app_version app_ver,
			b.sdk_version sdk_ver,
			b.app_commit  ,
			b.sdk_commit  ,
			b.dbk,
			c.size,
			b.duration bkp_took,
			c.duration copy_took
		from dbk b
		left join dbk_copy c on c.dbk = b.dbk
		#if deploy
		where
			b.deploy = :deploy
		#endif
		order by c.dbk_copy
	]], {deploy = deploy})
	checkfound(not deploy or #rows > 0, 'deploy not found')
	mysql_print_result{
		rows = rows,
		fields = cols,
		size = 'sum',
		made = 'max',
		bkp_took = 'max',
		copy_took = 'max',
		print = out_stdout_print,
	}
end
cmd_dbk('dbk|deploy-backups DEPLOY', 'Show deploy backups', mm.print_deploy_backups)

function api.deploy_backup(opt, deploy)

	deploy = checkarg(deploy, 'deploy required')

	local d = checkfound(first_row([[
		select
			deployed_app_version,
			deployed_sdk_version,
			deployed_app_commit,
			deployed_sdk_commit,
			machine,
			deployed_at
		from deploy
		where deploy = ?
	]], deploy), 'deploy not found')

	checkarg(d.deployed_at and d.machine, 'deploy is not deployed: %s', deploy)

	local task_name = 'deploy_backup '..deploy
	check500(not mm.running_task(task_name), 'already running: %s', task_name)

	--latest dbk of this deploy that has a good copy on this deploy's current machine.
	local parent_dbk = first_row([[
		select b.dbk from dbk b, dbk_copy c
		where c.dbk = b.dbk and b.deploy = ? and c.machine = ?
			and c.duration is not null
		order by b.dbk desc
		limit 1
	]], deploy, d.machine)

	local start_time = time()

	local dbk = insert_row('dbk', {
		deploy = deploy,
		app_version = d.deployed_app_version,
		sdk_version = d.deployed_sdk_version,
		app_commit  = d.deployed_app_commit,
		sdk_commit  = d.deployed_sdk_commit,
		note = opt.note,
		start_time = start_time,
	})

	local dbk_copy = insert_row('dbk_copy', {
		dbk = dbk,
		machine = d.machine,
		start_time = start_time,
	})

	rowset_changed'deploy_backups'
	rowset_changed'deploy_backup_copy'

	local task = mm.ssh_sh(d.machine, [[
		#use backup
		deploy_backup "$deploy" "$dbk" "$parent_dbk"
	]], {
		deploy = deploy,
		dbk = dbk,
		parent_dbk = parent_dbk,
	}, {
		name = task_name,
		out_stdout = false,
	})

	local size, checksum = parse_backup_info(task:stdout())

	update_row('dbk', {
		dbk,
		duration = task.duration,
		checksum = checksum,
	})
	rowset_changed'deploy_backups'

	update_row('dbk_copy', {
		dbk_copy,
		duration = 0,
		size = size,
	})
	rowset_changed'deploy_backup_copies'

	notify('Backup completed for: %s.', deploy)
end
cmd_dbk('dbk-backup [-note="..."] DEPLOY',
	'Create a backup for a deploy', mm.deploy_backup)

local function dbk_copy_info(dbk_copy)
	return checkfound(first_row([[
		select
			c.dbk_copy,
			c.dbk,
			c.machine,
			b.deploy,
			c.duration,
			b.app_version,
			b.sdk_version,
			b.app_commit,
			b.sdk_commit,
			c.size,
			b.checksum
		from dbk_copy c
		inner join dbk b on c.dbk = b.dbk
		where c.dbk_copy = ?
	]], dbk_copy), 'backup copy not found')
end

local function deploy_arg(s, required)
	local deploy = str_arg(s)
	local t = deploy and first_row('select * from deploy where deploy = ?', deploy)
	checkfound(t or not required, 'deploy not found: %s', s)
	return t
end

local function machine_arg(s, required)
	local machine = str_arg(s)
	local t = machine and first_row('select * from machine where machine = ?', machine)
	checkfound(t or not required, 'machine not found: %s', s)
	return t
end

local function dbk_copy_arg(s, required)
	local dbk_copy = id_arg(s)
	local t = dbk_copy and first_row('select * from dbk_copy where dbk_copy = ?', dbk_copy)
	checkfound(t or not required, 'deploy backup copy not found: %s', s)
	return t
end

--src     : `S,...` S: `COPY1[-COPY2]|DEPLOY`
--machine :
function api.deploy_backup_copy(opt, src_dbk_copy, machine)

	src_dbk_copy = checkarg(id_arg(src_dbk_copy, 'backup copy required'))
	local c = dbk_copy_info(src_dbk_copy)

	checkarg(c.duration, 'backup copy %d is not complete (didn\'t finish)', c.dbk_copy)
	checkarg(machine ~= c.machine, 'attempt to copy the backup to the same machine')

	--latest dbk of this deploy that has a good copy on the destination machine.
	local parent_dbk = first_row([[
		select b.dbk from dbk b, dbk_copy c
		where
			c.dbk = b.dbk
			and c.duration is not null
			and b.deploy = ?
			and c.machine = ?
			and b.dbk <> ?
		order by b.dbk desc
		limit 1
	]], c.deploy, machine, c.dbk)

	local dbk_copy = insert_or_update_row('dbk_copy', {
		dbk = c.dbk,
		machine = machine,
		start_time = time(),
	})

	local task = mm.ssh_sh(c.machine, [[
		#use ssh backup
		deploy_backup_copy "$dbk" "$parent_dbk"
	]], update({
		dbk = c.dbk,
		parent_dbk = parent_dbk,
	}, rsync_vars(c.machine, machine)), {
		name = 'deploy_backup_copy '..src_dbk_copy..' '..machine,
	})

	mm.deploy_backup_copy_check(opt, dbk_copy)

	update_row('dbk_copy', {
		dbk_copy,
		duration = task.duration,
	})
	rowset_changed'deploy_backup_copies'

	notify('Backup %d copied. Copy id: %d.', c.dbk, dbk_copy)
end
cmd_dbk('dbk-copy COPY|DEPLOY [MACHINE]', 'Copy a deploy backup', mm.deploy_backup_copy)

function api.deploy_backup_copy_check(opt, dbk_copy)
	local c = dbk_copy_info(dbk_copy)
	checkarg(c.checksum, 'Deploy backup copy %d does not have a checksum (not completed).', c.dbk_copy)
	local task = mm.ssh_sh(c.machine, [[
		#use backup
		deploy_backup_info "$dbk"
	]], {
		dbk = c.dbk,
	}, {
		name = 'deploy_backup_info '..c.dbk_copy,
		out_stdout = false,
	})
	local size, checksum = parse_backup_info(task:stdout())
	check500(checksum == c.checksum, 'Deploy backup copy %d from %s BAD CHECKSUM:'
		..'\n  expected: %s\n  computed: %s',
			c.dbk_copy, c.machine, c.checksum, checksum)

	update_row('dbk_copy', {c.dbk_copy, size = size})
	rowset_changed'deploy_backup_copies'

	notify('Backup copy %d OK. Size: %s.', c.dbk_copy, kbytes(size))
end
cmd_dbk('dbk-check COPY	', 'Check a deploy backup\'s integrity', mm.deploy_backup_copy_check)

function api.deploy_backup_copy_remove(opt, dbk_copy)

	dbk_copy = checkarg(id_arg(dbk_copy), 'backup copy required')
	local c = dbk_copy_info(dbk_copy)

	mm.ssh_sh(c.machine, [[
		#use backup
		deploy_backup_remove "$dbk"
	]], {
		dbk = c.dbk,
	}, {
		name = 'deploy_backup_remove '..dbk_copy,
	})

	delete_row('dbk_copy', {dbk_copy})
	rowset_changed'deploy_backup_copies'

	local backup_removed
	if first_row('select count(1) from dbk_copy where dbk = ?', c.dbk) == 0 then
		delete_row('dbk', {c.dbk})
		rowset_changed'deploy_backups'
		backup_removed = true
	end

	notify('Backup copy removed: %s.%s.', dbk_copy,
		backup_removed and ' That was the last copy of the backup.' or '')
end
cmd_dbk('dbk-remove COPY1[-COPY2],...', 'Remove deploy backup copies', function(copies)
	checkarg(copies, 'copies required')
	for s in words(copies:gsub(',', ' ')) do
		local dbk_copy1, dbk_copy2 = split(s:find'%-' and '-' or '..', s)
		dbk_copy1 = checkarg(id_arg(dbk_copy1 or s), 'invalid backup copy')
		dbk_copy2 = checkarg(id_arg(dbk_copy2 or s), 'invalid backup copy')
		for dbk_copy = min(dbk_copy1, dbk_copy2), max(dbk_copy1, dbk_copy2), 1 do
			mm.deploy_backup_copy_remove(opt, dbk_copy)
		end
	end
end)

function api.deploy_restore(opt, dbk_copy, dest_deploy)

	local c = dbk_copy_info(dbk_copy)
	local vars = deploy_vars(c.deploy, dest_deploy)
	local d = first_row([[
		select
			repo,
			app,
			env,
			mysql_pass,
			secret
		from deploy
		where deploy = ?
	]], c.deploy)

	mm.ssh_sh(c.machine, [[
		#use backup user deploy
		deploy_restore "$dbk"
	]], update({
		dbk = c.dbk,
	}, vars), {
		name = 'deploy_restore '..c.machine,
	})

	insert_or_update_row('deploy', {
		deploy = dest_deploy,
		machine = c.machine,
		repo = d.repo,
		app = d.app,
		env = d.env,
		mysql_pass = d.mysql_pass,
		secret = d.secret,
		deployed_app_version = c.app_version,
		deployed_sdk_version = c.sdk_version,
		deployed_app_commit = c.app_commit,
		deployed_sdk_commit = c.sdk_commit,
		deployed_at = time(),
		restored_from_dbk = c.dbk,
		restored_from_mbk = null,
	})

end
cmd_dbk('dbk-restore COPY [DEPLOY_NAME]', 'Restore a deployment', mm.deploy_restore)

--schedule backup tasks ------------------------------------------------------

local function machine_set_scheduled_backup_tasks(machine, enable)

	if not enable then
		set_scheduled_task('machine_full_backup '..machine, nil)
		set_scheduled_task('machine_incr_backup '..machine, nil)
		return
	end

	local row = first_row([[
		select
			active,
			full_backup_active,
			incr_backup_active,
			time_to_sec(full_backup_start_hours) full_backup_start_hours,
			time_to_sec(incr_backup_start_hours) incr_backup_start_hours,
			full_backup_run_every,
			incr_backup_run_every
		from machine
		where machine = ?
	]], machine)

	set_scheduled_task('machine_full_backup '..machine, row.active and row.full_backup_active and {
		action = function()
			mm.machine_backup(machine, 'scheduled full backup')
		end,
		task_name   = 'backup '..machine,
		machine     = machine,
		start_hours = row.full_backup_start_hours,
		run_every   = row.full_backup_run_every,
	} or nil)

	set_scheduled_task('machine_incr_backup '..machine, row.active and row.incr_backup_active and {
		action = function()
			mm.machine_backup(machine, 'scheduled incremental backup', 'latest')
		end,
		task_name   = 'backup '..machine,
		machine     = machine,
		start_hours = row.incr_backup_start_hours,
		run_every   = row.incr_backup_run_every,
	} or nil)

end

local function machine_update(machine, delete)
	machine_set_scheduled_backup_tasks(machine, not delete)
end

local function deploy_set_scheduled_backup_tasks(deploy, enable)

	if not enable then
		set_scheduled_task('deploy_backup '..deploy, nil)
		return
	end

	local d = first_row([[
		select
			active,
			machine,
			deployed_at,
			backup_active,
			time_to_sec(backup_start_hours) backup_start_hours,
			backup_run_every
		from deploy
		where deploy = ?
	]], deploy)

	set_scheduled_task('deploy_backup '..deploy,
		d.active and d.machine and d.deployed_at and d.backup_active and {
		action = function()
			mm.deploy_backup(machine, 'scheduled backup')
		end,
		task_name   = 'backup '..deploy,
		deploy      = deploy,
		start_hours = d.backup_start_hours,
		run_every   = d.backup_run_every,
	} or nil)

end

function deploy_update(deploy, delete)
	deploy_set_scheduled_backup_tasks(deploy, not delete)
end

function machine_schedule_backup_tasks()
	for _,machine in each_row_vals([[
		select machine from machine
		where active = 1 and (full_backup_active = 1 or incr_backup_active = 1)
	]]) do
		machine_set_scheduled_backup_tasks(machine, true)
	end
end

function deploy_schedule_backup_tasks()
	for _,deploy in each_row_vals([[
		select deploy from deploy
		where
			active = 1
			and deployed_at is not null and machine is not null
			and backup_active = 1
	]]) do
		deploy_set_scheduled_backup_tasks(deploy, true)
	end
end

--admin web UI ---------------------------------------------------------------

htmlfile'mm.html'
jsfile'mm.js'

rowset.git_hosting = sql_rowset{
	allow = 'admin',
	select = [[
		select
			name,
			host,
			ssh_hostkey,
			ssh_key,
			pos
		from
			git_hosting
	]],
	pk = 'name',
	hide_cols = 'ssh_hostkey ssh_key',
	insert_row = function(self, row)
		self:insert_into('git_hosting', row, 'name host ssh_hostkey ssh_key pos')
	end,
	update_row = function(self, row)
		self:update_into('git_hosting', row, 'name host ssh_hostkey ssh_key pos')
	end,
	delete_row = function(self, row)
		self:delete_from('git_hosting', row)
	end,
}

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

local function compute_cpu_max(self, vals)
	local t1 = vals.t1
	local t0 = vals.t0
	if not (t1 and t0) then return end
	local d = t1.clock - t0.clock
	local max_tp = 0
	for i,cpu1 in ipairs(t1.cputimes) do
		local cpu0 = t0.cputimes[i]
		local tp = (
			(cpu1.user - cpu0.user) +
			(cpu1.nice - cpu0.nice) +
			(cpu1.sys  - cpu0.sys )
		) * d
		max_tp = max(max_tp, tp)
	end
	return max(0, max_tp)
end

local function compute_uptime(self, vals)
	return vals.t1 and vals.t1.uptime
end

local function compute_ram_free(self, vals)
	return vals.t1 and vals.t1.ram_free
end

local function compute_hdd_free(self, vals)
	return vals.t1 and vals.t1.hdd_free
end

local function compute_ram(self, vals)
	return vals.t1 and vals.t1.ram_size or vals.ram
end

local function compute_hdd(self, vals)
	return vals.t1 and vals.t1.hdd_size or vals.hdd
end

rowset.machines = sql_rowset{
	allow = 'admin',
	select = [[
		select
			pos,
			machine as refresh,
			machine,
			active,
			0 as cpu_max,
			0 as ram_free,
			0 as hdd_free,
			provider,
			location,
			public_ip,
			local_ip,
			cost_per_month,
			cost_per_year,
			log_local_port,
			mysql_local_port,
			admin_page,
			ssh_key_ok,
			cpu,
			cores,
			ram,
			hdd,
			os_ver,
			mysql_ver,
			full_backup_active      ,
			full_backup_start_hours ,
			full_backup_run_every   ,
			incr_backup_active      ,
			incr_backup_start_hours ,
			incr_backup_run_every   ,
			backup_remove_older_than,
			ctime,
			0 as uptime
		from
			machine
	]],
	pk = 'machine',
	order_by = 'pos, ctime',
	field_attrs = {
		cpu_max     = {readonly = true, w = 60, 'percent_int', align = 'right', text = 'CPU Max %', compute = compute_cpu_max},
		ram_free    = {readonly = true, w = 60, 'filesize'   , filesize_decimals = 1, text = 'Free RAM', compute = compute_ram_free},
		hdd_free    = {readonly = true, w = 60, 'filesize'   , filesize_decimals = 1, text = 'Free Disk', compute = compute_hdd_free},
		public_ip   = {text = 'Public IP Address'},
		local_ip    = {text = 'Local IP Address', hidden = true},
		admin_page  = {text = 'VPS admin page of this machine'},
		ssh_key_ok  = {readonly = true, text = 'SSH key is up-to-date'},
		cpu         = {readonly = true, text = 'CPU'},
		cores       = {readonly = true, w = 20},
		ram         = {readonly = true, w = 60, filesize_decimals = 1, text = 'RAM Size', compute = compute_ram},
		hdd         = {readonly = true, w = 60, filesize_decimals = 1, text = 'Root Disk Size', compute = compute_hdd},
		os_ver      = {readonly = true, text = 'Operating System'},
		mysql_ver   = {readonly = true, text = 'MySQL Version'},
		uptime      = {readonly = true, text = 'Uptime', 'duration', compute = compute_uptime},
	},
	compute_row_vals = function(self, vals)
		vals.t1 = nil
		vals.t0 = nil
		local q = mm.machine_procinfo_logs[vals.machine]
		local t1 = q and q:item_at(q:count())
		local t0 = q and q:item_at(q:count() - 1)
		if not (t1 and t0) then return end
		local now = time()
		if t1.time < now - 2 then
			return
		end
		vals.t1 = t1
		vals.t0 = t0
	end,
	insert_row = function(self, row)
		local m1 = row.machine
		self:insert_into('machine', row, [[
			machine active provider location cost_per_month cost_per_year
			public_ip local_ip log_local_port mysql_local_port

			full_backup_active
			full_backup_start_hours
			full_backup_run_every
			incr_backup_active
			incr_backup_start_hours
			incr_backup_run_every
			backup_remove_older_than

			admin_page pos
		]])
		cp(mm.keyfile(), mm.keyfile(m1))
		cp(mm.ppkfile(), mm.ppkfile(m1))
		mm.putty_session_update(m1)
		machine_update(m1)
	end,
	update_row = function(self, row)
		local m1 = row.machine
		local m0 = row['machine:old']
		self:update_into('machine', row, [[
			machine active provider location cost_per_month cost_per_year
			public_ip local_ip log_local_port mysql_local_port

			full_backup_active
			full_backup_start_hours
			full_backup_run_every
			incr_backup_active
			incr_backup_start_hours
			incr_backup_run_every
			backup_remove_older_than

			admin_page pos
		]])
		if m1 and m1 ~= m0 then
			if exists(mm.keyfile(m0)) then mv(mm.keyfile(m0), mm.keyfile(m1)) end
			if exists(mm.ppkfile(m0)) then mv(mm.ppkfile(m0), mm.ppkfile(m1)) end
			mm.putty_session_rename(m0, m1)
			machine_update(m0, true)
		end
		machine_update(m1 or m0)
	end,
	delete_row = function(self, row)
		local m0 = row['machine:old']
		self:delete_from('machine', row)
		rm(mm.keyfile(m0))
		rm(mm.ppkfile(m0))
		mm.putty_session_remove(m0)
		machine_update(m0, true)
	end,
}

rowset.machine_backup_copy_machines = sql_rowset{
	allow = 'admin',
	select = [[
		select
			machine,
			dest_machine
		from machine_backup_copy_machine
	]],
	pk = 'machine dest_machine',
	hide_cols = 'machine',
	where_all = 'machine in (:param:filter)',
	insert_row = function(self, row)
		self:insert_into('machine_backup_copy_machine', row, 'machine dest_machine')
	end,
	update_row = function(self, row)
		self:update_into('machine_backup_copy_machine', row, 'machine dest_machine')
	end,
	delete_row = function(self, row)
		self:delete_from('machine_backup_copy_machine', row)
	end,
}

local function compute_rss(self, vals)
	return vals.t1 and vals.t1.rss
end

local function compute_lua_heap(self, vals)
	return vals.t1 and vals.t1.lua_heap
end

rowset.deploys = sql_rowset{
	allow = 'admin',
	select = [[
		select
			pos,
			deploy,
			active,
			'' as status,
			machine,
			0 as cpu_max,
			0 as rss,
			0 as lua_heap,
			0 as ram_free,
			0 as ram,
			0 as profiler_started,
			app,
			wanted_app_version, deployed_app_version, deployed_app_commit,
			wanted_sdk_version, deployed_sdk_version, deployed_sdk_commit,
			deployed_at,
			started_at,
			env,
			repo,
			domain,
			http_port,
			secret,
			mysql_pass,
			backup_active      ,
			backup_start_hours ,
			backup_run_every   ,
			backup_remove_older_than,
			ctime,
			mtime
		from
			deploy
	]],
	order_by = 'active desc, ctime',
	pk = 'deploy',
	name_col = 'deploy',
	rw_cols = [[
		pos deploy active machine app wanted_app_version wanted_sdk_version
		env repo domain http_port
		backup_active
		backup_start_hours
		backup_run_every
		backup_remove_older_than
	]],
	hide_cols = 'secret mysql_pass repo',
	field_attrs = {
		deploy = {
			validate = validate_deploy,
		},
		domain = {type = 'url'},
		status = {
			compute = function(self, vals)
				local vars = mm.deploy_state_vars[vals.deploy]
				return vars and vars.live_now and 'live' or null
			end,
		},
		cpu_max  = {'percent_int', text = 'CPU Max %'               , compute = compute_cpu_max  , w = 60, align = 'right', },
		rss      = {'filesize'   , text = 'RSS (Resident Set Size)' , compute = compute_rss      , filesize_magnitude = 'M'},
		lua_heap = {'filesize'   , text = 'Lua Heap Size'           , compute = compute_lua_heap , filesize_magnitude = 'M'},
		ram_free = {'filesize'   , text = 'RAM free (total)'        , compute = compute_ram_free , filesize_magnitude = 'M'},
		ram      = {'filesize'   , text = 'RAM size'                , compute = compute_ram      , filesize_magnitude = 'M'},
		profiler_started = {'bool',
			compute = function(self, vals)
				local vars = mm.deploy_state_vars[vals.deploy]
				return vars and vars.profiler_started or false
			end,
		},
	},
	compute_row_vals = function(self, vals)
		vals.t1 = nil
		vals.t0 = nil
		local q = mm.deploy_procinfo_logs[vals.deploy]
		local t1 = q and q:item_at(q:count())
		local t0 = q and q:item_at(q:count() - 1)
		if not (t1 and t0) then return end
		local now = time()
		if t1.time < now - 2 then
			return
		end
		vals.t1 = t1
		vals.t0 = t0
	end,
	insert_row = function(self, row)
		local d1 = row.deploy
		row.secret = base64_encode(random_string(46)) --results in a 64 byte string
 		row.mysql_pass = base64_encode(random_string(23)) --results in a 32 byte string
 		self:insert_into('deploy', row, [[
			deploy machine active repo app wanted_app_version wanted_sdk_version
			env domain http_port secret mysql_pass pos
			backup_active
			backup_start_hours
			backup_run_every
			backup_remove_older_than
		]])
		deploy_update(d1)
	end,
	update_row = function(self, row)
		local d0 = row['deploy:old']
		local d1 = row.deploy
		if row.machine then
			local m0 = first_row([[
				select machine from deploy where deploy = ?
				and deployed_app_commit is not null
			]], d0)
			if m0 then
				raise('db', '%s', 'Remove the deploy from the machine first.')
			end
		end
		self:update_into('deploy', row, [[
			machine active repo app wanted_app_version wanted_sdk_version
			domain http_port
			backup_active
			backup_start_hours
			backup_run_every
			backup_remove_older_than
			env pos
		]])
		if d1 and d1 ~= d0 then
			mm.deploy_rename(d0, d1)
			deploy_update(d0, true)
		end
		deploy_update(d0)
	end,
	delete_row = function(self, row)
		local d0 = row['deploy:old']
		local deployed = first_row([[
				select if(deployed_at is not null and machine is not null, 1, 0)
				from deploy where deploy = ?
			]], d0) == 1
		raise('db', '%s', 'Remove the deploy from the machine first.')
		self:delete_from('deploy', row)
		deploy_update(d0, true)
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

rowset.deploy_backup_copy_machines = sql_rowset{
	allow = 'admin',
	select = [[
		select
			deploy,
			dest_machine
		from deploy_backup_copy_machine
	]],
	pk = 'deploy dest_machine',
	hide_cols = 'deploy',
	where_all = 'deploy in (:param:filter)',
	insert_row = function(self, row)
		self:insert_into('deploy_backup_copy_machine', row, 'deploy dest_machine')
	end,
	update_row = function(self, row)
		self:update_into('deploy_backup_copy_machine', row, 'deploy dest_machine')
	end,
	delete_row = function(self, row)
		self:delete_from('deploy_backup_copy_machine', row)
	end,
}

rowset.config = virtual_rowset(function(self, ...)

	self.allow = 'admin'
	self.fields = {
		{name = 'config_id', 'double'},
		{name = 'mm_pubkey', text = 'MM\'s Public Key', maxlen = 8192},
		{name = 'mysql_root_pass', text = 'MySQL Root Password'},
	}
	self.pk = 'config_id'

	function self:load_rows(rs, params)
		local row = {1, mm.ssh_pubkey(), mm.mysql_root_pass()}
		rs.rows = {row}
	end

end)

function action.live()
	allow(usr'roles'.admin)
	setmime'txt'
	logging.printlive(outprint)
end

------------------------------------------------------------------------------

local function start_tunnels_and_log_servers()
	for _, machine, log_local_port, mysql_local_port in each_row_vals([[
		select
			machine,
			log_local_port,
			mysql_local_port
		from machine
		where active = 1
		order by machine
	]]) do
		if log_local_port then
			mm.rtunnel(machine, log_local_port..':'..mm.log_port, {
				editable = false,
				bg = true,
			})
			mm.log_server(machine)
		end
		if mysql_local_port then
			mm.tunnel(machine, mysql_local_port..':'..mm.mysql_port, {
				editable = false,
				bg = true,
			})
			config(machine..'_db_host', '127.0.0.1')
			config(machine..'_db_user', 'root')
			config(machine..'_db_port', mysql_local_port)
			config(machine..'_db_pass', mm.mysql_root_pass(machine))
			config(machine..'_db_name', 'performance_schema')
			config(machine..'_db_schema', false)
		end
	end
end

local run_server = mm.run_server
function mm:run_server()

	if true then

		runevery(1, function()
			if update_deploys_live_state() then
				rowset_changed'deploys'
			end
			rowset_changed'machines'
		end, 'rowsets-changed-every-second')

		runafter(0, function()
			start_tunnels_and_log_servers()
			machine_schedule_backup_tasks()
			deploy_schedule_backup_tasks()
			load_tasks_last_run()
			--runagainevery(60, run_tasks, 'run-tasks-every-60s')
		end, 'startup')

	end

	run_server(self)
end

--logging.filter.log = true

function api.test(opt, machine)
	mm.ssh_sh(machine, [[
		#use deploy
		test_task
	]], {}, {name = 'test_task'})
end
cmd_tasks('tt MACHINE', 'Test task', function(opt, machine)
	mm.test(opt, machine)
end)

return mm:run()
