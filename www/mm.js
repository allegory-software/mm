
// text streaming API client -------------------------------------------------

let chunk_decoder = function(onchunk) {
	let i = 0
	let chan, size
	return function(s, finished) {
		while (1) {
			let len = s.length-i
			if (size == null && len >= 10) {
				chan = s.slice(i, i+1)
				size = parseInt(s.slice(i+1, i+9), 16)
				i+=10; len-=10
			}
			if (size != null && len >= size) {
				let s1 = s.slice(i, i+size); i+=size
				onchunk(chan, s1, finished)
				chan = null
				size = null
				continue
			}
			break
		}
	}
}

let mm_onchunk = function(chan, s, finished) {
	if (chan == 'N')
		notify(s, 'info')
	else if (chan == 'E' || chan == 'e')
		notify(s, 'error')
	else if (chan == 'W')
		notify(s, 'warn')
}

// mm_api.cmd([e,][opt,]...args)
mm_api = new Proxy(obj(), {
	get(_, cmd) {
		return function(...args) {
			let e, opt
			if (iselem(args[0]))
				e = args.shift()
			if (isobj(args[0]))
				opt = args.shift
			return ajax({
				url: ['', 'api.txt', cmd.replaceAll('_', '-')],
				upload: {opt: opt, args: args},
				onchunk: chunk_decoder(mm_onchunk),
				notify: e,
			})
		}
	}
})

// actions -------------------------------------------------------------------

function ssh_key_gen() {
	mm_api.ssh_key_gen()
}

function ssh_key_update() {
	mm_api.ssh_key_update()
}

function machine_backup() {
	mm_api.machine_backup(this.val('machine'))
}

function deploy_action(action, ...args) {
	let deploy = mm_deploys_grid.focused_row_cell_val('deploy')
	mm_api[action](deploy, ...args)
	return false
}
function deploy_start   () { return deploy_action('app', 'start') }
function deploy_stop    () { return deploy_action('app', 'stop') }
function deploy_restart () { return deploy_action('app', 'restart') }
function deploy_deploy  () { return deploy_action('deploy') }
function deploy_remove  () { return deploy_action('deploy_remove') }
function deploy_backup  () { return deploy_action('backup') }

// wiring --------------------------------------------------------------------

// machines grid / refresh button field attrs & action
rowset_field_attrs['machines.refresh'] = {
	type: 'button',
	w: 40,
	button_options: {icon: 'fas fa fa-sync', bare: true, text: '', load_spin: true},
	action: function(machine) {
		this.post('/api.txt/update-machine-info', [machine])
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

// machines grid context menu items.
on('mm_machines_grid.init', function(e) {

	e.on('init_context_menu_items', function(items) {

		let grid_items = [].set(items)
		items.clear()

		let setup_items = [
			{
				text: 'Prepare machine (first thing to do)',
				action: function() {
					let machine = e.focused_row_cell_val('machine')
					if (machine)
						mm_api.prepare(machine)
				},
			},
			{
				text: 'Update SSH host fingerprint',
				action: function() {
					let machine = e.focused_row_cell_val('machine')
					if (machine)
						mm_api.ssh_hostkey_update(machine)
				},
			},
			{
				text: 'Update SSH key',
				action: function() {
					let machine = e.focused_row_cell_val('machine')
					if (machine)
						mm_api.ssh_key_update(machine)
				},
			},
			{
				text: 'Check that SSH key is up-to-date',
				action: function() {
					let machine = e.focused_row_cell_val('machine')
					if (machine)
						mm_api.ssh_key_check(machine)
				},
			},
			{
				text: 'Update SSH Git keys',
				action: function() {
					let machine = e.focused_row_cell_val('machine')
					if (machine)
						mm_api.git_keys_update(machine)
				},
			},
		]

		items.extend([
			{
				text: 'Grid options',
				icon: 'fa fa-table',
				items: grid_items,
			},
			{
				text: 'Setup',
				icon: 'fa fa-cog',
				items: setup_items,
			},
			{
				text: 'Start log server',
				action: function() {
					let machine = e.focused_row_cell_val('machine')
					if (machine)
						mm_api.log_server(machine)
				},
			},
			{
				text: 'Reboot machine',
				icon: 'fa fa-power-off',
				confirm: 'Are you sure you want to reboot the machine?',
				action: function() {
					let machine = e.focused_row_cell_val('machine')
					if (machine)
						mm_api.machine_reboot(machine)
				}
			},
		])

	})

})

on('mm_machine_backups_grid.init', function(e) {
	e.indent_size = 4
})

on('mm_machine_backup_copies_grid.init', function(e) {

	e.on('init_context_menu_items', function(items) {

		let grid_items = [].set(items)
		items.clear()

		items.extend([
			{
				text: 'Grid options',
				icon: 'fa fa-table',
				items: grid_items,
			},
			{
				text: 'Incremental backup from this backup copy',
				icon: 'fa fa-compact-disc',
				action: function() {
					let parent_mbk_copy = e.focused_row_cell_val('mbk_copy')
					let machine = e.focused_row_cell_val('machine')
					mm_api.machine_backup(machine, parent_mbk_copy)
				},
			},
		])

	})

})

on('mm_deploys_grid.init', function(e) {

	e.on('init_context_menu_items', function(items) {

		let grid_items = [].set(items)
		items.clear()

		items.extend([
			{
				text: 'Grid options',
				icon: 'fa fa-table',
				items: grid_items,
			},
			{
				text: 'Restart',
				icon: 'fa fa-arrow-rotate-left',
				load_spin: 'fa-spin fa-spin-reverse',
				action: deploy_restart,
			},
			{
				text: 'Start',
				icon: 'fa fa-play',
				load_spin: 'fa-beat-fade',
				action: deploy_start,
			},
			{
				text: 'Stop',
				icon: 'fa fa-power-off',
				action: deploy_stop,
			},
			{
				text: 'Deploy',
				icon: 'fa fa-pizza-slice',
				load_spin: 'fa-fade',
				action: deploy_deploy,
			},
		])

	})

})

on('mm_backup_replicas_grid.init', function(e) {

	e.on('init_context_menu_items', function(items) {

	})

})

{
let get_livelist_timer
on('mm_deploy_livelist_grid.bind', function(e, on) {
	if (on) {
		get_livelist_timer = runagainevery(1, function get_livelist() {
			let pv0 = e.param_vals && e.param_vals[0]
			let deploy = pv0 && pv0.deploy
			if (deploy)
				mm_api.deploy_rpc(deploy, 'get_livelist')
		})
	} else if (get_livelist_timer) {
		clearInterval(get_livelist_timer)
		get_livelist_timer = null
	}
})
}

on('mm_deploy_profiler_start_button.init', function(e) {
	let started
	e.action = function() {
		deploy_action('deploy_rpc', started ? 'stop_profiler' : 'start_profiler', 'Fl')
	}
	e.do_after('do_update_row', function(row) {
		e.xoff()
		started = row && e.val('profiler_started')
		e.icon = started ? 'fa fa-stop' : 'fa fa-circle'
		e.disable('not_live', !row || e.val('status') != 'live')
		e.xon()
	})
})

on('mm_deploy_collectgarbage_button.init', function(e) {
	e.do_after('do_update_row', function(row) {
		e.disable('not_live', !row || e.val('status') != 'live')
	})
})

mm_deploy_collectgarbage_button_action = function() {
	deploy_action('deploy_rpc', 'collectgarbage')
}

on('mm_deploy_jit_onoff_button.init', function(e) {
	let jit_on
	e.action = function() {
		deploy_action('deploy_rpc', 'jit_onoff', !jit_on)
	}
	e.do_after('do_update_row', function(row) {
		e.xoff()
		jit_on = row && e.val('jit_on')
		e.icon = jit_on ? 'fa-solid fa-gauge-high' : 'fa-solid fa-gauge'
		e.disable('not_live', !row || e.val('status') != 'live')
		e.xon()
	})
})

on('mm_deploy_reset_counts_button.init', function(e, on) {
	e.do_after('do_update_row', function(row) {
		e.disable('not_live', !(row && e.val('status') == 'live'))
	})
})
function mm_deploy_reset_counts_button_action() {
	mm_api.deploy_rpc(this.val('deploy'), 'reset_counts')
}

function mm_deploy_env_grid_params_changed() {
	let pv = this.param_vals
	let deploy = pv && pv[0] && pv[0].deploy
	if (deploy)
		mm_api.deploy_rpc(deploy, 'get_env')
}
on('mm_deploy_env_grid.bind', function(e, on) {
	e.on('params_changed', mm_deploy_env_grid_params_changed, on)
	if (on)
		deploy_env_grid_params_changed.call(e)
})

function mm_deploy_eval_button_action() {
	let s = mm_deploy_eval_script_textarea.input_val
	let deploy = this.val('deploy')
	if (s)
		mm_api.deploy_rpc(deploy, 'eval', s)
}
