--go@ x:\sdk\bin\windows\luajit mm.lua -vv run
--go@ plink d10 -t -batch sdk/bin/linux/luajit mm/mm.lua -v
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
	- all processes are tracked by task system with output capturing and autokill.
	- maintains secure access to all services via bulk updating of:
		- ssh root keys.
		- MySQL root password.
		- ssh git hosting (github, etc.) keys.
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
	- MySQL backups:
		- incremental, per-server, with xtrabackup.
		- non-incremental, per-db, with mysqldump.
		- replicated, with rsync.
		- TODO: per-table.
		- TODO: restore.
	- file replication:
		- incremental, via rsync.

LIMITATIONS
	- the machines need to run Linux (Debian 10) and have a public IP.
	- all deployments connect to the same MySQL server instance.
	- each deployment is given a single MySQL db.
	- single ssh key for root access.
	- single ssh key for git access.

]]

local function mm_schema()

	tables.config = {
		config      , idpk,
		ssh_key     , private_key,
		ssh_pubkey  , public_key,
	}

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
		active      , bool1,
		ssh_hostkey , public_key,
		ssh_key     , private_key,
		ssh_pubkey  , public_key,
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
		pos         , pos,
		ctime       , ctime,
	}

	tables.deploy = {
		deploy           , strpk,
		machine          , strid, not_null, fk,
		repo             , url, not_null,
		app              , strid, not_null,
		wanted_app_version   , strid,
		wanted_sdk_version   , strid,
		deployed_app_version , strid,
		deployed_sdk_version , strid,
		deployed_app_commit  , strid,
		deployed_sdk_commit  , strid,
		deployed_at          , timeago,
		started_at           , timeago,
		env              , strid, not_null,
		secret           , secret_key, not_null, --multi-purpose
		mysql_pass       , hash, not_null,
		restored_from_dbk, id, weak_fk(dbk),
		restored_from_mbk, id, weak_fk(mbk),
		ctime            , ctime,
		mtime            , mtime,
		pos              , pos,
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
		machine     , strid, weak_fk(machine),
		parent_mbk  , id, fk(mbk),
		start_time  , timeago,
		duration    , duration,
		size        , filesize,
		checksum    , hash,
		name        , name,
	}

	tables.mbk_deploy = {
		mbk         , id   , not_null, child_fk,
		deploy      , strid, not_null, fk, pk,
		app_version , strid,
		sdk_version , strid,
		app_commit  , strid,
		sdk_commit  , strid,
	}

	tables.mbk_copy = {
		mbk_copy   , idpk,
		parent_mbk_copy, id, fk(mbk_copy),
		mbk        , id   , not_null, fk,
		machine     , strid, not_null, fk, uk(mbk, machine),
		start_time  , timeago,
		duration    , duration,
	}

	--deploy backups: done with mysqldump so they are slow and non-incremental,
	--but they're the only way to backup & restore a single schema out of many
	--on a mysql server.
	tables.dbk = {
		dbk        , idpk,
		deploy      , strid, not_null, fk,
		app_version , strid,
		sdk_version , strid,
		app_commit  , strid,
		sdk_commit  , strid,
		start_time  , timeago,
		duration    , duration,
		size        , filesize,
		checksum    , hash,
		name        , name,
	}

	tables.dbk_copy = {
		dbk_copy   , idpk,
		dbk        , id, not_null, fk,
		machine     , strid, not_null, fk, uk(dbk, machine),
		start_time  , timeago,
		duration    , duration,
	}

	tables.action = {
		action, strpk,
	}

	tables.action.rows = {
		{'backup'},
	}

	tables.task = {
		task          , idpk,
		name          , longstrid, uk,
		--running
		action        , strid, not_null, fk,
		--schedule
		start_hours   , timeofday, --null means start right away.
		run_every     , duration, --null means de-arm after start.
		armed         , bool1,
		--editing
		generated_by  , name,
		editable      , bool1,
		--log
		last_run      , timeago,
		last_duration , duration,
		last_status   , strid,
		ctime         , ctime,
		mtime         , mtime,
	}

	tables.task_bkp = {
		task    , id, pk, fk,
		deploy  , strid, not_null, fk,
		name    , name,
	}

	tables.task_bkp_machine = {
		task    , id, fk,
		machine , strid, fk, pk,
	}

	tables.task_run = {
		task_run   , idpk,
		start_time , timeago, not_null,
		task       , id,
		name       , longstrid,
		duration   , duration,
		stdin      , text,
		stdouterr  , text,
		exit_code  , int,
	}

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
local mess = require'mess'

--config ---------------------------------------------------------------------

mm.sshfsdir = [[C:\PROGRA~1\SSHFS-Win\bin]] --no spaces!
mm.sshdir   = mm.bindir

config('page_title_suffix', 'Many Machines')
config('sign_in_logo', '/sign-in-logo.png')
config('favicon_href', '/favicon1.ico')
config('dev_email', 'cosmin.apreutesei@gmail.com')

config('secret', '!xpAi$^!@#)fas!`5@cXiOZ{!9fdsjdkfh7zk')
config('smtp_host', 'mail.bpnpart.com')
config('smtp_user', 'admin@bpnpart.com')
config('host', 'bpnpart.com')
config('noreply_email', 'admin@bpnpart.com')

--logging.filter[''] = true
--config('http_debug', 'protocol stream')
config('getpage_debug', 'stream')

--load_opensans()

mm.schema:import(mm_schema)

local function NYI(event)
	logerror('mm', event, 'NYI')
end

--install --------------------------------------------------------------------

cmd('install [forealz]', 'Install or migrate mm', function(doit)
	create_db()
	local dry = doit ~= 'forealz'
	db():sync_schema(mm.schema, {dry = dry})
	if not dry then
		create_user()
	end
	say'Install done.'
end)

--web api / server -----------------------------------------------------------

mm.json_api = {} --{action->fn}
mm.text_api = {} --{action->fn}
local function api_action(api)
	return function(action, ...)
		local f = checkfound(api[action:gsub('-', '_')])
		checkarg(method'post', 'try POST')
		local post = repl(post(), '')
		checkarg(post == nil or istab(post))
		allow(admin())
		--args are passed as `getarg1, getarg2, ..., postarg1, postarg2, ...`
		--in any combination, including only get args or only post args.
		local args = extend(pack_json(...), post)
		return f(unpack_json(args))
	end
end
action['api.json'] = api_action(mm.json_api)
action['api.txt' ] = api_action(mm.text_api)

--web api / client -----------------------------------------------------------

local function unpack_ret(ret)
	if istab(ret) and ret.unpack then
		return unpack_json(ret.unpack)
	end
	return ret
end

local function _api(ext, out_it, action, ...)

	local out_buf, out_content
	if out_it then
		out_buf = {}
		function out_content(req, buf, sz)
			local res = req.response
			if res.status == 200 then
				out(buf, sz)
			else
				add(out_buf, ffi.string(buf, sz))
			end
		end
	end
	local uri = url{segments = {'', 'api.'..ext, action}}
	local ret, res = getpage{
		host = config'mm_host',
		uri = uri,
		headers = {
			cookie = {
				session = config'session_cookie',
			},
		},
		method = 'POST',
		upload = pack_json(...),
		receive_content = out_content,
		compress = not out_it,
			--^^let text come in chunked so we can see each line as soom as it comes.
	}

	check500(ret ~= nil, '%s', res)

	if out_buf then
		ret = concat(out_buf)
	end

	ret = repl(ret, '') --json action that returned nil.

	if res.status ~= 200 then --check*(), http_error(), error(), or bug.
		local err = istab(ret) and ret.error or ret or res.status_message
		checkfound (res.status ~= 404, '%s', err)
		checkarg   (res.status ~= 400, '%s', err)
		allow      (res.status ~= 403, '%s', err)
		check500   (res.status ~= 500, '%s', err)
	end

	return ret
end
local function call_json_api(action, ...)
	return unpack_ret(_api('json', false, action, ...))
end
local function out_text_api(action, ...)
	_api('txt', true, action, ...)
end

--Lua/web/cmdline api generator ----------------------------------------------

local function from_server(from_db)
	return not from_db and mm.conf.mm_host and not mm.server_running
end

local json_api = setmetatable({}, {__newindex = function(_, name, fn)
	local ext_name = name:gsub('_', '-')
	mm[name] = function(...)
		if from_server() then
			return call_json_api(ext_name, ...)
		end
		return unpack_ret(fn(...))
	end
	mm.json_api[name] = fn
end})

local text_api = setmetatable({}, {__newindex = function(_, name, fn)
	local ext_name = name:gsub('_', '-')
	mm['out_'..name] = function(...)
		if from_server() then
			out_text_api(ext_name, ...)
			return
		end
		fn(...)
	end
	mm.text_api[name] = fn
end})

local hybrid_api = setmetatable({}, {__newindex = function(_, name, fn)
	text_api[name] = function(...) return fn(true , ...) end
	json_api[name] = function(...) return fn(false, ...) end
end})

local function _call(die_on_error, fn, ...)
	local ok, ret = errors.pcall(fn, ...)
	if not ok then
		local err = ret
		if die_on_error then
			die('%s', err)
		else
			say('ERROR: %s', err)
		end
	end
	if istab(ret) and ret.notify then
		local kind = ret.notify_kind
		say('%s%s', kind and kind:upper()..': ' or '', ret.notify)
	end
	return ret
end
local call = function(...) return _call(true, ...) end
local callp = function(...) return _call(false, ...) end

local function wrap(fn)
	return function(...)
		call(fn, ...)
	end
end
local cmd_ssh_keys    = cmdsection('SSH KEY MANAGEMENT', wrap)
local cmd_ssh         = cmdsection('SSH TERMINALS'     , wrap)
local cmd_ssh_tunnels = cmdsection('SSH TUNNELS'       , wrap)
local cmd_ssh_mounts  = cmdsection('SSH-FS MOUNTS'     , wrap)
local cmd_mysql       = cmdsection('MYSQL'             , wrap)
local cmd_machines    = cmdsection('MACHINES'          , wrap)
local cmd_deployments = cmdsection('DEPLOYMENTS'       , wrap)
local cmd_mbk        = cmdsection('MACHINE-LEVEL BACKUP & RESTORE', wrap)
local cmd_dbk        = cmdsection('DEPLOYMENT-LEVEL BACKUP & RESTORE', wrap)
local cmd_tasks       = cmdsection('TASKS'             , wrap)

--task system ----------------------------------------------------------------

mm.tasks = {}
mm.tasks_by_id = {}
mm.tasks_by_name = {}
local last_task_id = 0
local task_events_thread

local task = {}

function mm.running_task(name)
	local task = mm.tasks_by_name[name]
	return task and task.keyed ~= false
		and (task.status == 'new' or task.status == 'running') and task or nil
end

function mm.task(opt)
	check500(not mm.running_task(opt.keyed ~= false and opt.name),
		'task already running: %s', opt.name)
	last_task_id = last_task_id + 1
	local self = object(task, opt, {
		id = last_task_id,
		start_time = time(),
		duration = 0,
		status = 'new',
		errors = {},
		_out = {},
		_err = {},
		_outerr = {}, --interleaved as they come
	})
	mm.tasks[self] = true
	mm.tasks_by_id[self.id] = self
	if self.name then
		mm.tasks_by_name[self.name] = self
	end
	return self
end

function task:free()
	self:finish()
	mm.tasks[self] = nil
	mm.tasks_by_id[self.id] = nil
	if self.name then
		mm.tasks_by_name[self.name] = nil
	end
	rowset_changed'running_tasks'
end

function task:changed()
	self.duration = (self.end_time or time()) - self.start_time
	rowset_changed'running_tasks'
end

function task:setstatus(s)
	self.status = s
	self:changed()
	if not self.nolog then
		if not self.task_run then
			self.task_run = insert_row('task_run', {
				start_time = self.start_time,
				task = self.task,
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

function task:finish(exit_code)
	if self.end_time then return end --already called.
	self.end_time = time()
	self.exit_code = exit_code
	self:setstatus(exit_code and 'finished' or 'killed')
	local s = self:stdouterr()
	if s ~= '' then
		dbg('mm', 'taskout', '%s\n%s', self.name or self.id, s)
	end
	if self.on_finish then
		self:on_finish()
	end
end

function task:do_kill() NYI() end --stub

function task:kill()
	self.killed = true
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

local function cmp_start_time(t1, t2)
	return t1.start_time < t2.start_time
end

rowset.running_tasks = virtual_rowset(function(self, ...)

	self.allow = 'admin'
	self.fields = {
		{name = 'id'        , type = 'number'},
		{name = 'pinned'    , 'bool'},
		{name = 'type'      , },
		{name = 'name'      , },
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
			task.type,
			task.name,
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
		for task in sortedpairs(mm.tasks, cmp_start_time) do
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
		local task = mm.tasks_by_id[row['id:old']]
		task:kill()
	end

end)

function text_api.running_tasks()
	local fields = {
		{name = 'id'},
		{name = 'name'},
		{name = 'machine'},
		{name = 'status'},
		{name = 'start_time', type = 'timeago'},
		{name = 'duration', type = 'duration'},
		{name = 'exit_code', type = 'number'},
	}
	local rows = {}
	for task in sortedpairs(mm.tasks, cmp_start_time) do
		add(rows, {
			task.id,
			task.name,
			task.machine,
			task.status,
			task.start_time,
			task.duration,
			task.exit_code,
		})
	end
	outpqr(rows, fields)
end
cmd_tasks('t|tasks', 'Show running tasks', mm.out_running_tasks)

rowset.task_runs = sql_rowset{
	allow = 'admin',
	select = [[
		select
			task_run   ,
			start_time ,
			task       ,
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

local function update_task_name(task)
	local action = first_row('select action from task where task = ?', task)
	if action == 'backup' then
		local deploy = first_row('select deploy from task_bkp where task = ?', task)
		if not deploy then return end
		update_row('task', {task, name = 'backup '..action})
	end
end

local function task_function(task)
	local action = first_row('select action from task where task = ?', task)
	if action == 'backup' then
		local t = first_row('select deploy, name from task_bkp where task = ?', task)
		local machines = query('select machine from task_bkp_machine where task = ?', task)
		return function()
			mm.backup(t.deploy, t.name, nil, unpack(machines))
		end
	end
end

rowset.scheduled_tasks = sql_rowset{
	allow = 'admin',
	select = [[
		select
			task,
			name,
			action,
			start_hours,
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
	ro_cols = 'name',
	field_attrs = {
		--
	},
	insert_row = function(self, row)
		local task = self:insert_into('task', row, 'action start_hours run_every armed')
		update_task_name(task)
	end,
	update_row = function(self, row)
		local task = row['task:old']
		local editable, action, args = first_row_vals([[
			select editable, action from task where task = ?
		]], task)
		checkarg(editable ~= false, 'task not editable')
		self:update_into('task', row, 'action start_hours run_every armed')
		update_task_name(task)
	end,
	delete_row = function(self, row)
		checkarg(row['editable:old'], 'task not editable')
		self:delete_from('task', row)
	end,
}

rowset.scheduled_tasks_backup = sql_rowset{
	allow = 'admin',
	select = [[
		select
			task,
			deploy,
			name
		from task_bkp
	]],
	where = 'task in (:param:filter)',
	pk = 'task',
	hide_cols = 'task',
	insert_row = function(self, row)
		self:insert_into('task_bkp', row, 'deploy name')
		update_task_name(row.task)
	end,
	update_row = function(self, row)
		local task = row['task:old']
		self:update_into('task_bkp', row, 'deploy name')
		update_task_name(task)
	end,
	delete_row = function(self, row)
		self:delete_from('task_bkp', row)
	end,
}

rowset.scheduled_tasks_backup_machines = sql_rowset{
	allow = 'admin',
	select = [[
		select
			task,
			machine
		from task_bkp_machine
	]],
	where = 'task in (:param:filter)',
	pk = 'task machine',
	hide_cols = 'task',
	insert_row = function(self, row)
		self:insert_into('task_bkp_machine', row, 'machine')
		update_task_name(row.task)
	end,
	update_row = function(self, row)
		local task = row['task:old']
		self:update_into('task_bkp_machine', row, 'machine')
		update_task_name(task)
	end,
	delete_row = function(self, row)
		self:delete_from('task_bkp_machine', row)
	end,
}

function text_api.scheduled_tasks()
	local rows, fields = query({compact=1}, [[
		select
			task,
			name,
			action,
			start_hours,
			run_every,
			armed,
			generated_by,
			editable,
			last_run,
			last_duration,
			last_status
		from
			task
		order by
			last_run desc,
			ctime desc
	]])
	outpqr(rows, fields)
end
cmd_tasks('st|scheduled-tasks', 'Show scheduled tasks', mm.out_scheduled_tasks)

local function run_tasks()
	local now = time()
	local today = glue.day(now)

	for _, task, name, action, start_hours, run_every, last_run in each_row_vals[[
		select
			task,
			name,
			action,
			time_to_sec(start_hours) start_hours,
			run_every,
			unix_timestamp(last_run) last_run
		from
			task
		where
			armed = 1
			and name is not null
		order by
			last_run
	]] do

		local min_time = not start_hours and last_run and run_every
			and last_run + run_every or -1/0

		if start_hours and run_every then
			local today_at = today + start_hours
			local seconds_late = (now - today_at) % run_every --always >= 0
			local last_sched_time = now - seconds_late
			local already_run = last_run and last_run >= last_sched_time
			local too_late = seconds_late > run_every / 2
			if already_run or too_late then
				min_time = 1/0
			end
		end

		if now >= min_time and not mm.running_task(name) then

			local task_func = task_function(task)
			warnif('mm', 'task-func', not task_func, 'invalid task action %s', action)
			if task_func then
				local rearm = run_every and true or false
				note('mm', 'run-task', '%s', name)
				update_row('task', {task, last_run = now, armed = armed})
				resume(thread(function()
					local ok, err = pcall(task_func)
				end, 'run-task %s', task))
			end
		end
	end
end

--Lua/web/cmdline info api ---------------------------------------------------

function sshcmd(cmd)
	return win and indir(mm.sshdir, cmd) or cmd
end

function json_api.machines()
	return (query'select machine from machine')
end

function mm.each_machine(f, fmt, ...)
	local machines = mm.machines()
	local threads = sock.threadset()
	for _,machine in ipairs(machines) do
		resume(threads:thread(f, fmt, machine, ...), machine)
	end
	threads:wait()
end

local function callm(cmd, machine)
	if not machine then
		call(mm.each_machine, function(m)
			callp(mm[cmd], m)
		end, cmd..' %s')
		return
	end
	mm[cmd](machine)
end

function json_api.machine_info(machine)
	return checkfound(first_row([[
		select
			machine,
			mysql_local_port
		from machine where machine = ?
	]], checkarg(machine, 'machine required')), 'machine not found')
end

function json_api.deploy_info(deploy)
	return checkfound(first_row([[
		select
			deploy,
			mysql_pass
		from deploy where deploy = ?
	]], checkarg(deploy, 'deploy required')), 'deploy not found')
end

function json_api.ip(md)
	local md = checkarg(md, 'machine or deploy required')
	local m = first_row('select machine from deploy where deploy = ?', md) or md
	local ip = first_row('select public_ip from machine where machine = ?', m)
	return {unpack = pack_json(checkfound(ip, 'machine not found'), m)}
end
cmd_machines('ip MACHINE|DEPLOY', 'Get the IP address of a machine or deployment',
	function(machine)
		print((mm.ip(machine)))
	end)

local function known_hosts_file()
	return indir(mm.vardir, 'known_hosts')
end
function json_api.known_hosts_file_contents()
	return load(known_hosts_file())
end
function mm.known_hosts_file()
	local file = known_hosts_file()
	if from_server() then
		save(file, mm.known_hosts_file_contents())
	end
	return file
end

local function keyfile(machine, ext)
	return indir(mm.vardir, 'mm'..(machine and '-'..machine or '')..'.'..(ext or 'key'))
end
function json_api.keyfile_contents(machine, ext)
	return load(keyfile(machine, ext))
end
function mm.keyfile(machine, ext) --`mm ssh ...` gets it from the server
	local file = keyfile(machine, ext)
	if from_server() then
		save(file, mm.keyfile_contents(machine, ext))
	end
	return file
end
function mm.ppkfile(machine) --`mm putty ...` gets it from the server
	return mm.keyfile(machine, 'ppk')
end

function json_api.ssh_pubkey(machine)
	--NOTE: Windows ssh-keygen puts the key name at the end, but the Linux one doesn't.
	local s = readpipe(sshcmd'ssh-keygen'..' -y -f "'..mm.keyfile(machine)..'"'):trim()
	return (s:match('^[^%s]+%s+[^%s]+')..' mm')
end
cmd_ssh_keys('ssh-pubkey [MACHINE]', 'Show a/the SSH public key', function(machine)
	print(mm.ssh_pubkey(machine))
end)

--for manual updating via `curl mm.allegory.ro/pubkey/MACHINE >> authroized_keys`.
function action.pubkey(machine)
	setmime'txt' --TODO: disable html filter
	outall(mm.ssh_pubkey(machine))
end

function json_api.ssh_hostkey(machine)
	return checkfound(first_row([[
		select ssh_hostkey from machine where machine = ?
	]], checkarg(machine, 'machine required')), 'machine not found'):trim()
end
cmd_ssh_keys('ssh-hostkey MACHINE', 'Show a SSH host key', function(machine)
	print(mm.ssh_hostkey(machine))
end)

function json_api.ssh_hostkey_sha(machine)
	machine = checkarg(machine, 'machine required')
	local key = first_row([[
		select ssh_hostkey from machine where machine = ?
	]], machine)
	local key = checkfound(key, 'machine not found'):trim()
	local task = mm.exec({
		sshcmd'ssh-keygen', '-E', 'sha256', '-lf', '-'
	}, {
		stdin = key,
		capture_stdout = true,
		name = 'ssh_hostkey_sha '..machine,
		keyed = false, nolog = true,
	})
	check500(task.exit_code == 0, 'ssh-keygen exit code: %d', task.exit_code)
	return (task:stdout():trim():match'%s([^%s]+)')
end
cmd_ssh_keys('ssh-hostkey-sha MACHINE', 'Show a SSH host key SHA', function(machine)
	print(mm.ssh_hostkey_sha(machine))
end)

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
	local task = mm.exec(cmd, {
		name = 'ssh_key_gen_ppk'..(machine and ' '..machine or ''),
	})
	check500(task.exit_code == 0, 'winscp/puttygen exit code: %d', task.exit_code)
	return {notify = 'PPK file generated'}
end

function json_api.mysql_root_pass(machine) --last line of the private key
	local s = load(mm.keyfile(machine))
		:gsub('%-+.-PRIVATE%s+KEY%-+', ''):gsub('[\r\n]', ''):trim():sub(-32)
	assert(#s == 32)
	return s
end
cmd_mysql('mysql-root-pass [MACHINE]', 'Show the MySQL root password', function(machine)
	print(mm.mysql_root_pass(machine))
end)

function mm.mysql_pass(deploy)
	return mm.deploy_info(deploy).mysql_pass
end
cmd_mysql('mysql-pass DEPLOY', 'Show the MySQL password for an app', function(deploy)
	print(mm.mysql_pass(deploy))
end)

--async exec -----------------------------------------------------------------

function mm.exec(cmd, opt)

	opt = opt or empty

	local task = mm.task(update({cmd = cmd}, opt))

	local capture_stdout = opt.capture_stdout or mm.server_running or opt.out_stdouterr
	local capture_stderr = opt.capture_stderr or mm.server_running or opt.out_stdouterr

	local p, err = proc.exec{
		cmd = cmd,
		env = opt.env and update(proc.env(), opt.env),
		async = true,
		autokill = true,
		stdout = capture_stdout,
		stderr = capture_stderr,
		stdin = opt.stdin and true or false,
	}

	local wait

	if not p then
		task:logerror('exec', '%s', err)
	else

		task.process = p
		task:setstatus'running'

		if p.stdin then
			resume(thread(function()
				--dbg('mm', 'execin', '%s', opt.stdin)
				local ok, err = p.stdin:write(opt.stdin)
				if not ok then
					task:logerror('stdinwr', '%s', err)
				end
				assert(p.stdin:close()) --signal eof
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
					if opt.out_stdouterr then
						out(s)
					end
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
					if opt.out_stdouterr then
						out(s)
					end
				end
				p.stderr:close()
			end, 'exec-stderr %s', p))
		end

		--release all db connections now in case this is a long running task.
		release_dbs()

		function wait()
			local exit_code, err = p:wait()
			if not exit_code then
				if not (err == 'killed' and task.killed) then
					task:logerror('procwait', '%s', err)
				end
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

		function task:do_kill()
			p:kill()
		end
	end

	local function finish()
		if opt and not mm.server_running then
			task:free()
		else
			resume(thread(function()
				sleep(10)
				while task.pinned do
					sleep(1)
				end
				task:free()
			end, 'exec-zombie %s', p))
		end
		if #task.errors > 0 then
			check500(false, cat(task.errors, '\n'))
		end
	end

	if not p then
		finish()
	else
		if opt.async then
			resume(thread(function()
				wait()
				finish()
			end, 'exec-wait %s', p))
		else
			wait()
			finish()
		end
	end

	return task
end

--ssh ------------------------------------------------------------------------

function mm.ssh(md, args, opt)
	opt = opt or {}
	local ip, machine = mm.ip(md)
	opt.machine = machine
	return mm.exec(extend({
		sshcmd'ssh',
		opt.allocate_tty and '-t' or '-T',
		'-q',
		'-o', 'BatchMode=yes',
		'-o', 'ConnectTimeout=3',
		'-o', 'PreferredAuthentications=publickey',
		'-o', 'UserKnownHostsFile='..mm.known_hosts_file(),
		'-i', mm.keyfile(machine),
		'root@'..ip,
	}, args), opt)
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
	local script_s = script:outdent()
	local s = mm.sh_script(script_s, script_env, opt.pp_env)
	opt.stdin = '{\n'..s..'\n}; exit'..(opt.stdin or '')
	note('mm', 'ssh-sh', '%s %s', machine, script_s:sub(1, 50))
	return mm.ssh(machine, {'bash', '-s'}, opt)
end

--machine commands -----------------------------------------------------------

function text_api.machines()
	local rows, cols = query({
		compact=1,
	}, [[
		select
			machine,
			public_ip,
			cores,
			ram,
			hdd,
			cpu,
			os_ver,
			mysql_ver,
			ctime
		from machine
		order by pos, ctime
	]])
	outpqr(rows, cols)
end
cmd_machines('m|machines', 'Show the list of machines', mm.out_machines)

function hybrid_api.machine_rename(to_text, old_machine, new_machine)

	checkarg(new_machine, 'new_machine required')

	checkarg(not first_row([[
		select 1 from machine where machine = ?
	]], new_machine), 'machine already exists: %s', new_machine)

	local task = mm.ssh_sh(old_machine, [=[
		#use deploy
		machine_rename "$OLD_MACHINE" "$NEW_MACHINE"
	]=], {
		OLD_MACHINE = old_machine,
		NEW_MACHINE = new_machine,
	}, {
		name = 'machine_rename '..old_machine,
		out_stdouterr = to_text,
	})
	check500(task.exit_code == 0, 'machine_rename exit code: %d', task.exit_code)

	update_row('machine', {old_machine, machine = new_machine})

	--TODO: !!!!

	if exists(mm.keyfile(old_machine)) then
		mv(mm.keyfile(old_machine), mm.keyfile(new_machine))
	end
	if exists(mm.ppkfile(old_machine)) then
		mv(mm.ppkfile(old_machine), mm.ppkfile(new_machine))
	end

	return {notify = 'Machine renamed from '..old_machine..' to '..new_machine}
end

cmd_machines('machine-rename OLD_MACHINE NEW_MACHINE',
	'Rename a machine',
	mm.out_machine_rename)

function text_api.update_machine_info(machine)
	local task = mm.ssh_sh(machine, [=[
		#use machine
		machine_info
	]=], nil, {
		name = 'update_machine_info '..(machine or ''),
		keyed = false, nolog = true,
		capture_stdout = true,
	})
	check500(task.exit_code == 0, 'machine_info exit code: %d',
		task.exit_code)
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
		outprint(_('%20s %s', k, t[k]))
	end
end
cmd_machines('i|machine-info MACHINE', 'Show machine info', mm.out_update_machine_info)

function json_api.machine_reboot(machine)
	mm.ssh(machine, {
		'reboot',
	}, {
		name = 'machine_reboot '..(machine or ''),
	})
	return {notify = 'Machine rebooted: '..machine}
end

--command: ssh-hostkey-update ------------------------------------------------

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
	save(mm.known_hosts_file(), concat(t, '\n'))
end

function json_api.ssh_hostkey_update(machine)
	local ip, machine = mm.ip(machine)
	local task = mm.exec({
		sshcmd'ssh-keyscan', '-4', '-T', '2', '-t', 'rsa', ip
	}, {
		name = 'ssh_hostkey_update '..machine,
		capture_stdout = true,
	})
	check500(task.exit_code == 0, 'ssh-keyscan exit code: %d', task.exit_code)
	local s = task:stdout()
	assert(update_row('machine', {machine, ssh_hostkey = s}).affected_rows == 1)
	gen_known_hosts_file()
	return {notify = 'Host key updated for '..machine}
end
cmd_ssh_keys('ssh-hostkey-update MACHINE', 'Make a machine known again to us',
	mm.ssh_hostkey_update)

--command: ssh-key-gen -------------------------------------------------------

function json_api.ssh_key_gen()
	rm(mm.keyfile())
	exec(sshcmd'ssh-keygen'..' -f %s -t rsa -b 2048 -C "mm" -q -N ""', mm.keyfile())
	rm(mm.keyfile()..'.pub') --we'll compute it every time.
	mm.ssh_key_fix_perms()
	mm.ssh_key_gen_ppk()
	rowset_changed'config'
	query'update machine set ssh_key_ok = 0'
	rowset_changed'machines'
	return {notify = 'SSH key generated'}
end
cmd_ssh_keys('ssh-key-gen', 'Generate a new SSH key', function()
	call'ssh_key_gen'
end)

--command: ssh-key-update ----------------------------------------------------

function json_api.ssh_key_update(machine)
	note('mm', 'upd-key', '%s', machine)
	local pubkey = mm.ssh_pubkey()
	local task = mm.ssh_sh(machine, [=[
		#use ssh mysql user
		has_mysql && {
			mysql_update_pass localhost root "$MYSQL_ROOT_PASS"
			mysql_gen_my_cnf  localhost root "$MYSQL_ROOT_PASS"
		}
		ssh_update_pubkey mm "$PUBKEY"
		user_lock_pass root
		ssh_pubkey mm  # print it so we can check it
	]=], {
		PUBKEY = pubkey,
		MYSQL_ROOT_PASS = mm.mysql_root_pass(),
	}, {
		name = 'ssh_key_update '..machine,
		capture_stdout = true,
	})
	check500(task.exit_code == 0, 'SSH key update script exit code %d for %s',
		task.exit_code, machine)
	local stored_pubkey = task:stdout():trim()
	check500(stored_pubkey == pubkey, 'SSH public key NOT updated for '..machine)

	cp(mm.keyfile(), mm.keyfile(machine))
	cp(mm.ppkfile(), mm.ppkfile(machine))
	mm.ssh_key_fix_perms(machine)

	update_row('machine', {machine, ssh_key_ok = true})
	rowset_changed'machines'

	return {notify = 'SSH key updated for '..machine}
end
cmd_ssh_keys('ssh_key_update [MACHINE]', 'Update SSH key(s)',
	function(machine)
		callm('ssh_key_update', machine)
	end)

function json_api.ssh_key_check(machine)
	local task = mm.ssh_sh(machine, [[
		#use ssh
		ssh_pubkey mm
	]], nil, {
		name = 'ssh_key_check '..(machine or ''),
		keyed = false, nolog = true,
		capture_stdout = true,
	})
	check500(task.exit_code == 0, 'SSH key check script exit code %d for %s',
		task.exit_code, machine)
	local host_pubkey = task:stdout():trim()
	local ok = host_pubkey == mm.ssh_pubkey()
	update_row('machine', {machine, ssh_key_ok = ok})
	rowset_changed'machines'
	return {
		notify = 'SSH key is'..(ok and '' or ' NOT')..' up-to-date for '..machine,
		notify_kind = not ok and 'warn' or nil,
		ssh_key_ok = ok,
	}
end
cmd_ssh_keys('ssh-key-check [MACHINE]', 'Check that SSH keys are up-to-date',
	function(machine)
		callm('ssh_key_check', machine)
	end)

--git keys update -------------------------------------------------------------

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

function json_api.git_keys_update(machine)
	local vars = git_hosting_vars()
	local task = mm.ssh_sh(machine, [=[
		#use ssh
		ssh_git_keys_update
	]=], vars, {
		task = 'git_keys_update '..(machine or ''),
	})
	check500(task.exit_code == 0, 'Git keys update script exit code %d for %s',
		task.exit_code, machine)
	return {notify = 'Git keys updated for '..machine}
end
cmd_ssh_keys('git-keys-update [MACHINE]', 'Updage Git SSH keys',
	function(machine)
		callm('git_keys_update', machine)
	end)

--command: prepare machine ---------------------------------------------------

function hybrid_api.prepare(to_text, machine)
	mm.ip(machine)
	local vars = git_hosting_vars()
	vars.MYSQL_ROOT_PASS = mm.mysql_root_pass(machine)
	vars.MACHINE = machine
	mm.ssh_sh(machine, [=[
		#use deploy
		machine_prepare
	]=], vars, {
		name = 'prepare '..machine,
		out_stdouterr = to_text,
	})
	return {notify = 'Machine prepared: '..machine}
end
cmd_machines('prepare MACHINE', 'Prepare a new machine', mm.out_prepare)

--deploy commands ------------------------------------------------------------

function text_api.deploys()
	local rows, cols = query({
		compact=1,
	}, [[
		select
			deploy,
			machine,
			app,
			env,
			deployed_at,
			started_at,
			wanted_app_version   app_want,
			deployed_app_version app_depl,
			deployed_app_commit  app_comm,
			wanted_sdk_version   sdk_want,
			deployed_sdk_version sdk_depl,
			deployed_sdk_commit  sdk_comm,
			repo
		from deploy
		order by pos, ctime
	]])
	outpqr(rows, cols)
end
cmd_deployments('d|deploys', 'Show the list of deployments', mm.out_deploys)

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

local function deploy_vars(deploy, new_deploy)

	deploy = checkarg(deploy, 'deploy required')

	local vars = {}
	for k,v in pairs(checkfound(first_row([[
		select
			d.machine,
			d.repo,
			d.app,
			d.wanted_app_version app_version,
			d.wanted_sdk_version sdk_version,
			coalesce(d.env, 'dev') env,
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
	vars.MYSQL_DB = new_deploy
	vars.MYSQL_USER = new_deploy

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

function hybrid_api.deploy(to_text, deploy, app_ver, sdk_ver)
	if app_ver or sdk_ver then
		update_row('deploy', {
			deploy,
			wanted_app_version = app_ver,
			wanted_sdk_version = sdk_ver,
		})
	end
	local vars = deploy_vars(deploy)
	update(vars, git_hosting_vars())
	local task = mm.ssh_sh(vars.MACHINE, [[
		#use deploy
		deploy
	]], vars, {
		name = 'deploy '..deploy,
		capture_stdout = true,
		out_stdouterr = to_text,
	})
	local s = task:stdout()
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
	return {notify = 'Deployed: '..deploy}
end
cmd_deployments('deploy DEPLOY [APP_VERSION] [SDK_VERSION]', 'Deploy an app',
	mm.out_deploy)

function hybrid_api.deploy_remove(deploy)
	local vars = deploy_vars(deploy)
	mm.ssh_sh(vars.MACHINE, [[
		#use deploy
		deploy_remove "$DEPLOY"
	]], {
		DEPLOY = vars.DEPLOY,
	}, {
		name = 'deploy_remove '..deploy,
	})

	update_row('deploy', {
		vars.DEPLOY,
		deployed_app_version = null,
		deployed_sdk_version = null,
		deployed_app_commit = null,
		deployed_sdk_commit = null,
	})
	return {notify = 'Deploy removed: '..deploy}
end
cmd_deployments('deploy-remove DEPLOY', 'Remove a deployment',
	mm.out_deploy_remove)

function hybrid_api.deploy_rename(to_text, old_deploy, new_deploy)

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
		local task = mm.ssh_sh(machine, [=[
			#use deploy
			deploy_rename "$OLD_DEPLOY" "$NEW_DEPLOY"
		]=], update({
			OLD_DEPLOY = old_deploy,
			NEW_DEPLOY = new_deploy,
		}, vars), {
			name = 'deploy_rename '..old_deploy,
			out_stdouterr = to_text,
		})
		check500(task.exit_code == 0, 'deploy_rename exit code: %d', task.exit_code)
	end

	update_row('deploy', {old_deploy, deploy = new_deploy})

	return {notify = 'Deploy renamed from '..old_deploy..' to '..new_deploy}
end
cmd_deployments('deploy-rename OLD_DEPLOY NEW_DEPLOY',
	'Rename a deployment (requires app restart)',
	mm.out_deploy_rename)

local function find_cmd(...)
	for i=1,select('#',...) do
		local s = select(i, ...)
		if not s:starts'-' then return s end
	end
end

function hybrid_api.app(to_text, deploy, ...)
	local vars = deploy_vars(deploy)
	local args = proc.quote_args_unix(...)
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
			out_stdouterr = to_text,
		})
	local ok = task.exit_code == 0
	if ok then
		local cmd = find_cmd(...)
		if cmd == 'start' or cmd == 'restart' then
			update_row('deploy', {deploy, started_at = time()})
			rowset_changed'deploys'
		end
	end
	return {
		notify = task_name..(ok and ' ok' or ' exit code: '..task.exit_code),
		notify_kind = not ok and 'error' or nil,
	}
end
cmd_deployments('app DEPLOY ...', 'Run a deployed app', mm.out_app)

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
		q = queue.new(queues.queue_size)
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
		local live_now = dt < 3
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

	local task = mm.task({
		name = 'log_server '..machine,
		machine = machine,
		editable = false,
		type = 'long',
	})

	local logserver = mess.listen('127.0.0.1', lport, function(mess, chan)
		local deploy
		resume(thread(function()
			while not chan:closed() do
				if deploy then
					mm.log_server_rpc(deploy, 'get_procinfo')
				end
				chan:sleep(1)
			end
		end, 'log-server-get-procinfo %s', machine))
		chan:recvall(function(chan, msg)
			if not deploy then --first message identifies the client.
				deploy = msg.deploy
				log_server_chan[deploy] = chan
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
				end
			else
				queue_push(mm.deploy_logs, deploy, msg)
				rowset_changed'deploy_log'
			end
		end, function()
			log_server_chan[deploy] = nil
		end)
		log_server_chan[deploy] = nil
	end, nil, 'log-server-'..machine)

	function task:do_kill()
		logserver:stop()
	end

	task:setstatus'running'
	return task
end
function mm.json_api.log_server(machine)
	mm.log_server(machine)
	return {notify = 'Log server started'}
end

function mm.log_server_rpc(deploy, cmd, ...)
	local chan = log_server_chan[deploy]
	if not chan then return end
	chan:send(pack(cmd, ...))
end

function action.poll_livelist(deploy)
	allow(admin())
	mm.log_server_rpc(deploy, 'poll_livelist')
end

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
		{name = 'descr'},
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

rowset.deploy_procinfo_log = virtual_rowset(function(self)
	self.allow = 'admin'
	self.fields = {
		{name = 'deploy'},
		{name = 'clock'    , type = 'number'   , },
		{name = 'cpu'      , type = 'number'   , text = 'CPU'},
		{name = 'cpu_sys'  , type = 'number'   , text = 'CPU (kernel)'},
		{name = 'rss'      , type = 'filesize' , text = 'RSS (Resident Set Size)', filesize_magnitude = 'M'},
		{name = 'ram_free' , type = 'filesize' , text = 'RAM free (total)', filesize_magnitude = 'M'},
		{name = 'ram_size' , type = 'filesize' , text = 'RAM size', hidden = true},
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
								local up = (t.utime - utime0) / dt * 100
								local sp = (t.stime - stime0) / dt * 100
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
		{name = 'clock'        , type = 'number'   , },
		{name = 'max_cpu'      , type = 'number'   , text = 'Max CPU'},
		{name = 'max_cpu_sys'  , type = 'number'   , text = 'Max CPU (kernel)'},
		{name = 'avg_cpu'      , type = 'number'   , text = 'Avg CPU'},
		{name = 'avg_cpu_sys'  , type = 'number'   , text = 'Avg CPU (kernel)'},
		{name = 'ram_used'     , type = 'filesize' , filesize_magnitude = 'M', text = 'RAM Used'},
		{name = 'hdd_used'     , type = 'filesize' , filesize_magnitude = 'M', text = 'Disk Used'},
		{name = 'ram_size'     , type = 'filesize' , filesize_magnitude = 'M', text = 'RAM Size'},
		{name = 'hdd_size'     , type = 'filesize' , filesize_magnitude = 'M', text = 'Disk Size'},
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
								local max_tp = (max_ttime - max_ttime0) / dt * 100
								local max_sp = (max_stime - max_stime0) / dt * 100
								local avg_tp = (avg_ttime - avg_ttime0) / dt * 100
								local avg_sp = (avg_stime - avg_stime0) / dt * 100
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
							local up = (t.utime - utime0) / dt * 100
							local sp = (t.stime - stime0) / dt * 100
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
		exec_time_total = {w = 40, decimals = 2},
		exec_time_max   = {w = 40, decimals = 2},
		exec_time_avg   = {w = 40, decimals = 2},
		full_scan = {'bool'},
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
			b.size       ,
			b.checksum   ,
			b.name
		from mbk b
	]],
	where_all = 'b.machine in (:param:filter)',
	pk = 'mbk',
	parent_col = 'parent_mbk',
	tree_col = 'machine',
	update_row = function(self, row)
		self:update_into('mbk', row, 'name')
	end,
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
			duration
		from
			mbk_copy
	]],
	pk = 'mbk_copy',
	where_all = 'mbk in (:param:filter)',
	pk = 'mbk_copy',
	delete_row = function(self, row)
		mm.machine_backup_copy_remove(row['mbk_copy:old'])
	end,
}

function text_api.machine_backups(machine)
	local rows, cols = query({
		compact=1,
	}, [[
		select
			c.mbk_copy  copy,
			c.parent_mbk_copy `from`,
			b.name,
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
			b.size,
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
	checkfound(not machine or #rows > 0, 'machine not found')
	outpqr(rows, cols, {
		size = 'sum',
		made = 'max',
		bkp_took = 'max',
		copy_took = 'max',
	})
end
cmd_mbk('mbk|machine-backups MACHINE', 'Show machine backups', mm.out_machine_backups)

function hybrid_api.machine_backup(to_text, machine, name, parent_mbk_copy, ...)

	machine = checkarg(machine, 'machine required')

	if parent_mbk_copy == 'latest' then
		parent_mbk_copy = checkarg(first_row([[
			--find the local copy of the latest backup of :machine that has one.
			select c.mbk_copy from mbk_copy c, mbk b
			where c.mbk = b.mbk and b.machine = :machine and c.machine = :machine
			order by c.mbk desc limit 1
		]], {machine = machine}), 'no local backup of machine "%s" found for "latest"', nachine)
	elseif parent_mbk_copy then
		parent_mbk_copy = checkarg(parent_mbk_copy, 'invalid backup copy')
	end

	local parent_mbk = parent_mbk_copy and checkarg(first_row([[
		select c.mbk from mbk_copy c, mbk b
		where c.mbk = b.mbk and c.mbk_copy = ? and b.machine = ?
	]], parent_mbk_copy, machine), 'parent backup copy not of the same machine')

	local task_name = 'mbk_backup '..machine
	check500(not mm.running_task(task_name), 'already running: %s', task_name)

	local start_time = time()

	local mbk = insert_row('mbk', {
		parent_mbk = parent_mbk,
		machine = machine,
		name = name,
		start_time = start_time,
	})
	rowset_changed'machine_backups'

	query([[
		insert into mbk_deploy (
			mbk        ,
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
		capture_stdout = true,
		out_stdouterr = to_text,
	})
	check500(task.exit_code == 0, 'machine_backup exit code: '..task.exit_code)

	local s = task:stdout()
	local size, checksum = s:match'^([^%s]+)%s+([^%s]+)'

	update_row('mbk', {
		mbk,
		duration = task.duration,
		size = tonumber(size),
		checksum = checksum,
	})
	rowset_changed'machine_backups'

	update_row('mbk_copy', {
		mbk_copy,
		duration = 0,
	})
	rowset_changed'machine_backup_copies'

	for i=1,select('#',...) do
		local machine = select(i,...)
		;(to_text and mm.out_machine_backup_copy or mm.machine_backup_copy)(mbk_copy, machine)
	end

	return {notify = 'Machine backup done for '..machine}
end
cmd_mbk('mbk-backup MACHINE [NAME] [UP_COPY] [MACHINE1,...]',
	'Backup a machine', mm.out_machine_backup)

local function rsync_vars(machine)
	return {
		HOST = mm.ip(machine, true),
		SSH_KEY = load(mm.keyfile(machine)),
		SSH_HOSTKEY = mm.ssh_hostkey(machine),
	}
end

local function mbk_copy_info(mbk_copy)
	return checkfound(first_row([[
		select
			c.mbk_copy,
			b.mbk, b.parent_mbk,
			c.machine, c.duration
		from mbk_copy c
		inner join mbk b on c.mbk = b.mbk
		where c.mbk_copy = ?
	]], mbk_copy), 'backup copy not found')
end

function hybrid_api.machine_backup_copy(to_text, src_mbk_copy, machine)

	machine = checkarg(machine)
	src_mbk_copy = checkarg(id_arg(src_mbk_copy, 'backup copy required'))
	local c = mbk_copy_info(src_mbk_copy)

	checkarg(c.duration, 'Backup copy %d is not complete (didn\'t finish)', c.mbk_copy)
	checkarg(machine ~= c.machine, 'Choose a different machine to copy the backup to.')

	local parent_mbk_copy = c.parent_mbk and checkarg(first_row([[
		select mbk_copy from mbk_copy
		where mbk = ? and machine = ? and duration is not null
	]], c.parent_mbk, machine),
		'a copy of the backup\'s parent backup was not found on machine "%s"', machine)

	local mbk_copy = insert_or_update_row('mbk_copy', {
		mbk = c.mbk,
		parent_mbk_copy = parent_mbk_copy,
		machine = machine,
		start_time = time(),
	})
	rowset_changed'machine_backup_copies'

	local task = mm.ssh_sh(c.machine, [[
		#use ssh backup
		rsync_to "$HOST" "$(bkp_dir machine $mbk)" "$(bkp_dir machine $parent_mbk)"
	]], update({
		mbk = c.mbk,
		parent_mbk = c.parent_mbk,
	}, rsync_vars(machine)), {
		name = 'machine_backup_copy '..src_mbk_copy..' '..machine,
		out_stdouterr = to_text,
	})
	check500(task.exit_code == 0, 'rsync_to exit code: %d', task.exit_code)

	update_row('mbk_copy', {
		mbk_copy,
		duration = task.duration,
	})
	rowset_changed'machine_backup_copies'

	return {notify = _('Backup copied: %d, copy id: %d', c.mbk, mbk_copy)}
end
cmd_mbk('mbk-copy COPY MACHINE', 'Copy a machine backup', mm.out_machine_backup_copy)

function json_api.machine_backup_copy_remove(mbk_copy)

	mbk_copy = checkarg(id_arg(mbk_copy, 'backup copy required'))
	local c = mbk_copy_info(mbk_copy)

	checkarg(not first_row([[
		select 1 from mbk_copy where parent_mbk_copy = ? limit 1
	]], mbk_copy), 'Backup has derived incremental backups. Remove those first.')

	local task = mm.ssh_sh(c.machine, [[
		#use backup
		machine_backup_remove "$mbk"
	]], {
		mbk = c.mbk,
	}, {
		name = 'machine_backup_remove '..mbk_copy,
	})
	check500(task.exit_code == 0, 'machine_backup_remove exit code: %d', task.exit_code)

	delete_row('mbk_copy', {mbk_copy})
	rowset_changed'machine_backup_copies'

	local backup_removed
	if first_row('select count(1) from mbk_copy where mbk = ?', c.mbk) == 0 then
		delete_row('mbk', {c.mbk})
		rowset_changed'machine_backups'
		backup_removed = true
	end

	return {notify = 'Backup copy removed: '..mbk_copy..'.'
		..(backup_removed and ' That was the last copy of the backup.' or '')}
end
cmd_mbk('mbk-remove COPY1[-COPY2] ...', 'Remove machine backup copies', function(...)
	for i=1,select('#',...) do
		local s = select(i,...)
		local mbk_copy1, mbk_copy2 = s, s
		if s:find'%-' then
			mbk_copy1, mbk_copy2 = s:match'(.-)%-(.*)'
		elseif s:find'%.%.' then
			mbk_copy1, mbk_copy2 = s:match'(.-)%.%.(.*)'
		end
		mbk_copy1 = checkarg(mbk_copy1, 'invalid backup copy')
		mbk_copy2 = checkarg(mbk_copy2, 'invalid backup copy')
		for mbk_copy = max(mbk_copy1, mbk_copy2), min(mbk_copy1, mbk_copy2), -1 do
			callp(mm.machine_backup_copy_remove, mbk_copy)
		end
	end
end)

function hybrid_api.machine_restore(to_text, mbk_copy)

	local c = mbk_copy_info(mbk_copy)

	local task = mm.ssh_sh(c.machine, [[
		#use backup
		machine_restore "$mbk"
	]], {
		mbk = c.mbk,
	}, {
		name = 'machine_restore '..c.machine,
	})
	check500(task.exit_code == 0, 'machine_restore exit code: %d', task.exit_code)

	query[[
		#
	]]

end
cmd_mbk('mbk-restore COPY', 'Restore a machine', mm.out_machine_restore)

--deploy backups -------------------------------------------------------------

rowset.deploy_backups = sql_rowset{
	allow = 'admin',
	select = [[
		select
			dbk        ,
			deploy     ,
			start_time ,
			name       ,
			size       ,
			duration   ,
			checksum
		from dbk
	]],
	where_all = 'deploy in (:param:filter)',
	pk = 'dbk',
	update_row = function(self, row)
		self:update_into('dbk', row, 'name')
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

function text_api.deploy_backups(deploy)
	local rows, cols = query({
		compact=1,
	}, [[
		select
			c.dbk_copy,
			b.deploy,
			b.name,
			b.deploy `of`,
			c.machine `in`,
			b.start_time  `made`,
			b.app_version app_ver,
			b.sdk_version sdk_ver,
			b.app_commit  ,
			b.sdk_commit  ,
			b.dbk,
			b.size,
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
	outpqr(rows, cols, {
		size = 'sum',
		made = 'max',
		bkp_took = 'max',
		copy_took = 'max',
	})
end
cmd_dbk('dbk|deploy-backups DEPLOY', 'Show deploy backups', mm.out_deploy_backups)

function hybrid_api.deploy_backup(to_text, deploy, name, ...)

	local d = checkfound(first_row([[
		select
			machine,
			deployed_app_version,
			deployed_sdk_version,
			deployed_app_commit,
			deployed_sdk_commit,
			deployed_at
		from deploy
		where deploy = ?
	]], checkarg(deploy, 'deploy required')), 'deploy not found')

	check500(d.deployed_at, '%s is not deployed.', deploy)

	local task_name = 'deploy_backup '..deploy
	check500(not mm.running_task(task_name), 'already running: %s', task_name)

	local start_time = time()

	local dbk = insert_row('dbk', {
		deploy = deploy,
		app_version = d.deployed_app_version,
		sdk_version = d.deployed_sdk_version,
		app_commit  = d.deployed_app_commit,
		sdk_commit  = d.deployed_sdk_commit,
		name = name,
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
		deploy_backup "$deploy" "$dbk"
	]], {
		deploy = deploy,
		dbk = dbk,
	}, {
		name = task_name,
		capture_stdout = true,
		out_stdouterr = to_text,
	})
	check500(task.exit_code == 0, 'deploy_backup exit code: %d', task.exit_code)

	local s = task:stdout()
	local size, checksum = s:match'^([^%s]+)%s+([^%s]+)'

	update_row('dbk', {
		dbk,
		duration = task.duration,
		size = tonumber(size),
		checksum = checksum,
	})
	rowset_changed'deploy_backups'

	update_row('dbk_copy', {
		dbk_copy,
		duration = 0,
	})
	rowset_changed'deploy_backup_copies'

	for i=1,select('#',...) do
		local machine = select(i,...)
		;(to_text and mm.out_dbk_copy or mm.dbk_copy)(dbk_copy, deploy)
	end

	return {notify = 'Backup done for '..deploy}
end
cmd_dbk('dbk-backup DEPLOY [NAME] [MACHINE1,...]',
	'Backup a deploy', mm.out_deploy_backup)

local function dbk_copy_info(dbk_copy)
	return checkfound(first_row([[
		select c.dbk_copy, c.dbk, c.machine, b.deploy, c.duration
		from dbk_copy c
		inner join dbk b on c.dbk = b.dbk
		where c.dbk_copy = ?
	]], dbk_copy), 'backup copy not found')
end

function hybrid_api.deploy_backup_copy(to_text, src_dbk_copy, machine)

	machine = checkarg(machine)
	src_dbk_copy = checkarg(id_arg(src_dbk_copy, 'backup copy required'))
	local c = dbk_copy_info(src_dbk_copy)

	checkarg(c.duration, 'Backup copy %d is not complete (didn\'t finish)', c.dbk_copy)
	checkarg(machine ~= c.machine, 'Choose a different machine to copy the backup to.')

	local dbk_copy = insert_or_update_row('dbk_copy', {
		dbk = c.dbk,
		machine = machine,
		start_time = time(),
	})

	local task = mm.ssh_sh(c.machine, [[
		#use ssh backup
		rsync_to "$HOST" "$(bkp_dir deploy $dbk)"
	]], update({
		dbk = c.dbk,
	}, rsync_vars(machine)), {
		name = 'deploy_backup_copy '..src_dbk_copy..' '..machine,
		out_stdouterr = to_text,
	})
	check500(task.exit_code == 0, 'deploy_backup_copy exit code: %d', task.exit_code)

	update_row('dbk_copy', {
		dbk_copy,
		duration = task.duration,
	})
	rowset_changed'deploy_backup_copies'

	return {notify = _('Backup copied: %d, copy id: %d', c.dbk, dbk_copy)}
end
cmd_dbk('dbk-copy COPY MACHINE', 'Copy a deploy backup', mm.out_deploy_backup_copy)

function json_api.deploy_backup_copy_remove(dbk_copy)

	dbk_copy = checkarg(id_arg(dbk_copy, 'backup copy required'))
	local c = dbk_copy_info(dbk_copy)

	local task = mm.ssh_sh(c.machine, [[
		#use backup
		deploy_backup_remove "$dbk"
	]], {
		dbk = c.dbk,
	}, {
		name = 'deploy_backup_remove '..dbk_copy,
	})
	check500(task.exit_code == 0, 'deploy_backup_remove exit code: %d', task.exit_code)

	delete_row('dbk_copy', {dbk_copy})
	rowset_changed'deploy_backup_copies'

	local backup_removed
	if first_row('select count(1) from dbk_copy where dbk = ?', c.dbk) == 0 then
		delete_row('dbk', {c.dbk})
		rowset_changed'deploy_backups'
		backup_removed = true
	end

	return {notify = 'Backup copy removed: '..dbk_copy..'.'
		..(backup_removed and ' That was the last copy of the backup.' or '')}
end
cmd_dbk('dbk-remove COPY1[-COPY2] ...', 'Remove deploy backup copies', function(...)
	for i=1,select('#',...) do
		local s = select(i,...)
		local dbk_copy1, dbk_copy2 = s, s
		if s:find'%-' then
			dbk_copy1, dbk_copy2 = s:match'(.-)%-(.*)'
		elseif s:find'%.%.' then
			dbk_copy1, dbk_copy2 = s:match'(.-)%.%.(.*)'
		end
		dbk_copy1 = checkarg(dbk_copy1, 'invalid backup copy')
		dbk_copy2 = checkarg(dbk_copy2, 'invalid backup copy')
		for dbk_copy = max(dbk_copy1, dbk_copy2), min(dbk_copy1, dbk_copy2), -1 do
			callp(mm.deploy_backup_copy_remove, dbk_copy)
		end
	end
end)

function hybrid_api.deploy_restore(to_text, dbk_copy, new_machine, new_deploy)

	local c = dbk_copy_info(dbk_copy)

	if new_deploy and new_deploy ~= c.deploy then
		checkarg(not first_row('select 1 from deploy where deploy = ?', new_deploy),
			'deploy already exists: %s', new_deploy)
	end

	if new_machine and new_machine ~= c.machine then
		-- ??
	end

	local vars = deploy_vars(c.deploy, new_deploy)

	local task = mm.ssh_sh(c.machine, [[
		#use backup
		deploy_restore "$DBK" "$DEPLOY"
	]], update({
		DBK = c.dbk,
	}, vars), {
		name = 'deploy_restore '..c.machine,
	})
	check500(task.exit_code == 0, 'deploy_restore exit code: %d', task.exit_code)

	if new_deploy and new_deploy ~= c.deploy then
		query([[
			insert into deploy (
				deploy,
				machine,
				repo,
				app,
				wanted_app_version,
				wanted_sdk_version,
				deployed_app_version,
				deployed_sdk_version,
				deployed_app_commit,
				deployed_sdk_commit,
				deployed_at,
				started_at,
				env,
				secret,
				mysql_pass,
				restored_from_dbk,
				restored_from_mbk
			) select
				deploy,
				:machine,
				repo,
				app,
				wanted_app_version,
				wanted_sdk_version,
				deployed_app_version,
				deployed_sdk_version,
				deployed_app_commit,
				deployed_sdk_commit,
				now(), --deployed_at
				null, --stasrted_at
				env,
				secret,
				mysql_pass,
				:dbkp,
				null --restored_from_mbk
			from deploy
			where deploy = ?
		]], {
			deploy = c.deploy,
			machine = c.machine,
			dbkp = c.dbkp,
		})
	end

end
cmd_dbk('dbk-restore COPY [DEPLOY_NAME]', 'Restore a deployment', mm.out_deploy_restore)

--remote access tools --------------------------------------------------------

cmd_ssh('ssh -|MACHINE|DEPLOY,... [CMD ...]', 'SSH to machine(s)', function(md, cmd, ...)
	checkarg(md, 'machine or deploy required')
	local machines =
		md == '-' and mm.machines()
		or glue.names(md:gsub(',', ' '))
	local last_exit_code
	for _,md in ipairs(machines) do
		local ip, m = mm.ip(md)
		say('SSH to %s:', m)
		local task = mm.ssh(md,
			cmd and {'bash', '-c', "'"..catargs(' ', cmd, ...).."'"},
			not cmd and {allocate_tty = true} or nil)
		if task.exit_code ~= 0 then
			say('SSH to %s: exit code: %d', m, task.exit_code)
		end
		last_exit_code = task.exit_code
	end
	return last_exit_code
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
	#use deploy backup
	]]
	local script_env = update({
		DEBUG   = env'DEBUG' or '',
		VERBOSE = env'VERBOSE' or '',
	}, git_hosting_vars(), deploy and deploy_vars(deploy))
	local s = mm.sh_script(script:outdent(), script_env)
	local s = catargs('\n',
		'export MM_TMP_SH=/root/.mm.$$.sh',
		'cat << \'EOFFF\' > $MM_TMP_SH',
		'rm -f $MM_TMP_SH',
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

--TODO: accept NAME as in `[LPORT|NAME:][RPORT|NAME]`
function mm.tunnel(machine, ports, opt, rev)
	local args = {'-N'}
	if logging.debug then add(args, '-v') end
	ports = checkarg(ports, 'ports expected')
	local rports = {}
	for ports in ports:gmatch'([^,]+)' do
		local lport, rport = ports:match'(.-):(.*)'
		rport = rport or ports
		lport = lport or ports
		add(args, rev and '-R' or '-L')
		if rev then lport, rport = rport, lport end
		add(args, '127.0.0.1:'..lport..':127.0.0.1:'..rport)
		note('mm', 'tunnel', '%s:%s %s %s', machine, lport, rev and '->' or '<-', rport)
		add(rports, rport)
	end
	local on_finish
	local function start_tunnel()
		mm.ssh(machine, args, update({
			name = (rev and 'r' or '')..'tunnel'..' '..machine..' '..cat(rports, ','),
		}, update({
			type = 'long',
			on_finish = on_finish,
		}, opt)))
	end
	function on_finish(task)
		if task.killed then return end
		sleep(1)
		start_tunnel()
	end
	start_tunnel()
end
function mm.rtunnel(machine, ports, opt)
	return mm.tunnel(machine, ports, opt, true)
end

cmd_ssh_tunnels('tunnel MACHINE [LPORT1:]RPORT1,...',
	'Create SSH tunnel(s) to machine',
	function(machine, ports)
		mm.tunnel(machine, ports, {allocate_tty = true})
	end)

cmd_ssh_tunnels('rtunnel MACHINE [LPORT1:]RPORT1,...',
	'Create reverse SSH tunnel(s) to machine',
	function(machine, ports)
		return mm.rtunnel(machine, ports, {allocate_tty = true})
	end)

cmd_mysql('mysql DEPLOY|MACHINE [SQL]', 'Execute MySQL command or remote REPL', function(md, sql)
	local ip, machine = mm.ip(md)
	local deploy = machine ~= md and md
	local args = {'mysql', '-h', 'localhost', '-u', 'root', deploy}
	if sql then append(args, '-e', proc.quote_arg_unix(sql)) end
	return mm.ssh(machine, args, not sql and {allocate_tty = true} or nil)
end)

--TODO: `sshfs.exe` is buggy in background mode: it kills itself when parent cmd is closed.
function mm.mount(machine, rem_path, drive, bg)
	if win then
		drive = drive or 'S'
		rem_path = rem_path or '/'
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
			local task = mm.exec(cmd, {
				name = 'mount '..drive,
			})
			assertf(task.exit_code == 0, 'sshfs exit code: %d', task.exit_code)
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

function text_api.rsync(dir, machine1, machine2)
	local task = mm.ssh_sh(machine1, [[
		#use ssh
		rsync_to "$HOST" "$DIR"
		]], update({
			DIR = dir
		}, rsync_vars(machine2)), {
			out_stdouterr = true,
		}
	)
	check500(task.exit_code == 0, 'rsync_to exit code: %d', task.exit_code)
end

cmd_ssh_mounts('rsync DIR MACHINE1 MACHINE2', 'Copy files between machines', mm.out_rsync)

function text_api.sha(machine, dir)
	local task = mm.ssh_sh(machine, [[
		#use fs
		sha_dir "$DIR"
		]], {
			DIR = dir
		}, {
			out_stdouterr = true,
		}
	)
	check500(task.exit_code == 0, 'sha_dir exit code: %d', task.exit_code)
end

cmd_ssh_mounts('sha MACHINE DIR', 'Compute SHA of dir contents', mm.out_sha)

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
		local tp = floor((
			(cpu1.user - cpu0.user) +
			(cpu1.nice - cpu0.nice) +
			(cpu1.sys  - cpu0.sys )
		) * d * 100)
		max_tp = max(max_tp, tp)
	end
	return max_tp
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
			ctime,
			0 as uptime
		from
			machine
	]],
	pk = 'machine',
	order_by = 'pos, ctime',
	field_attrs = {
		cpu_max     = {readonly = true, w = 60, type = 'percent', align = 'right', text = 'CPU Max %', compute = compute_cpu_max},
		ram_free    = {readonly = true, w = 60, type = 'filesize', filesize_decimals = 1, text = 'Free RAM', compute = compute_ram_free},
		hdd_free    = {readonly = true, w = 60, type = 'filesize', filesize_decimals = 1, text = 'Free Disk', compute = compute_hdd_free},
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
		uptime      = {readonly = true, text = 'Uptime', type = 'duration', compute = compute_uptime},
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
		self:insert_into('machine', row, [[
			machine provider location cost_per_month cost_per_year
			public_ip local_ip log_local_port mysql_local_port
			admin_page pos
		]])
		cp(mm.keyfile(), mm.keyfile(row.machine))
		cp(mm.ppkfile(), mm.ppkfile(row.machine))
	end,
	update_row = function(self, row)
		self:update_into('machine', row, [[
			machine provider location cost_per_month cost_per_year
			public_ip local_ip log_local_port mysql_local_port
			admin_page pos
		]])
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

rowset.deploys = sql_rowset{
	allow = 'admin',
	select = [[
		select
			pos,
			deploy,
			'' as status,
			machine,
			app,
			wanted_app_version, deployed_app_version, deployed_app_commit,
			wanted_sdk_version, deployed_sdk_version, deployed_sdk_commit,
			deployed_at,
			started_at,
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
				return vars and vars.live_now and 'live' or null
			end,
		},
	},
	ro_cols = [[
		secret mysql_pass
		deployed_app_version
		deployed_sdk_version
		deployed_app_commit
		deployed_sdk_commit
		deployed_at
		started_at
	]],
	hide_cols = 'secret mysql_pass repo',
	insert_row = function(self, row)
		row.secret = b64(random_string(46)) --results in a 64 byte string
 		row.mysql_pass = b64(random_string(23)) --results in a 32 byte string
 		self:insert_into('deploy', row, [[
			deploy machine repo app wanted_app_version wanted_sdk_version
			env secret mysql_pass pos
		]])
	end,
	update_row = function(self, row)
		self:update_into('deploy', row, [[
			machine repo app wanted_app_version wanted_sdk_version
			env pos
		]])
		if row.deploy then
			mm.deploy_rename(row['deploy:old'], row.deploy)
		end
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
		local row = {1, mm.ssh_pubkey(), mm.mysql_root_pass()}
		rs.rows = {row}
	end

end)

function action.live()
	allow(admin())
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
		from machine order by machine
	]]) do
		if log_local_port then
			mm.rtunnel(machine, log_local_port..':'..mm.log_port, {
				editable = false,
				async = true,
			})
		end
		if mysql_local_port then
			mm.tunnel(machine, mysql_local_port..':'..mm.mysql_port, {
				editable = false,
				async = true,
			})
			config(machine..'_db_host', '127.0.0.1')
			config(machine..'_db_port', mysql_local_port)
			config(machine..'_db_pass', mm.mysql_root_pass(machine))
			config(machine..'_db_name', 'performance_schema')
			config(machine..'_db_schema', false)
		end
		pcall(mm.log_server, machine)
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
		end, 'start-log-servers')

		runagainevery(60, run_tasks, 'run-tasks-every-60s')
	end

	run_server(self)
end

return mm:run()
