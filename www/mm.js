
// actions -------------------------------------------------------------------

function ssh_key_gen() {
	this.post('/api.json/ssh-key-gen')
}

function ssh_key_updates() {
	this.post('/api.json/ssh-key-update')
}

function deploy_action(btn, action, ...args) {
	let deploy = mm_deploys_grid.focused_row_cell_val('deploy')
	btn.post(['', 'api.json', action, deploy, ...args])
	return false
}
function deploy_start   () { return deploy_action(this, 'app', 'start') }
function deploy_stop    () { return deploy_action(this, 'app', 'stop') }
function deploy_restart () { return deploy_action(this, 'app', 'restart') }
function deploy_deploy  () { return deploy_action(this, 'deploy') }
function deploy_remove  () { return deploy_action(this, 'deploy-remove') }

function deploy_backup() {
	this.post(['', 'api.json', 'backup', this.val('deploy')])
}

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
						post('/api.json/machine-prepare', [machine])
				},
			},
			{
				text: 'Update SSH host fingerprint',
				action: function() {
					let machine = e.focused_row_cell_val('machine')
					if (machine)
						post('/api.json/ssh-hostkey-update', [machine])
				},
			},
			{
				text: 'Update SSH key',
				action: function() {
					let machine = e.focused_row_cell_val('machine')
					if (machine)
						post('/api.json/ssh-key-update', [machine])
				},
			},
			{
				text: 'Check that SSH key is up-to-date',
				action: function() {
					let machine = e.focused_row_cell_val('machine')
					if (machine)
						post('/api.json/ssh-key-check', [machine])
				},
			},
			{
				text: 'Update SSH Git keys',
				action: function() {
					let machine = e.focused_row_cell_val('machine')
					if (machine)
						post('/api.json/git-keys-update', [machine])
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
						post('/api.json/log-server', [machine])
				},
			},
			{
				text: 'Reboot machine',
				icon: 'fa fa-power-off',
				confirm: 'Are you sure you want to reboot the machine?',
				action: function() {
					let machine = e.focused_row_cell_val('machine')
					if (machine)
						post('/api.json/machine-reboot', [machine])
				}
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

on('mm_deploy_livelist.bind', function(e, on) {
	if (on) {
		e._get_livelist_timer = runagainevery(1, function get_livelist() {
			let pv0 = e.param_vals && e.param_vals[0]
			let deploy = pv0 && pv0.deploy
			if (deploy)
				post(['get-livelist', deploy])
		})
	} else if (e._get_livelist_timer) {
		clearInterval(e._get_livelist_timer)
		e._get_livelist_timer = null
	}
})
