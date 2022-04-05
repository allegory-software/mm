
// machines gre / refresh button field attrs & action
rowset_field_attrs['machines.refresh'] = {
	type: 'button',
	w: 40,
	button_options: {icon: 'fas fa fa-sync', bare: true, text: '', load_spin: true},
	action: function(machine) {
		this.post('/api/update-machine-info', [machine])
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
					post('/api/ssh-hostkey-update', [machine])
			},
		})

		ssh_items.push({
			text: 'Update key',
			action: function() {
				let machine = e.focused_row_cell_val('machine')
				if (machine)
					post('/api/ssh-key-update', [machine])
			},
		})

		ssh_items.push({
			text: 'Check key',
			action: function() {
				let machine = e.focused_row_cell_val('machine')
				if (machine)
					post('/api/ssh-key-check', [machine])
			},
		})

		items.push({
			text: 'Prepare machine',
			action: function() {
				let machine = e.focused_row_cell_val('machine')
				if (machine)
					post('/api/machine-prepare', [machine])
			},
		})

		items.push({
			text: 'Update git keys',
			action: function() {
				let machine = e.focused_row_cell_val('machine')
				if (machine)
					post('/api/git-keys-update', [machine])
			},
		})

		items.push({
			text: 'Start log server',
			action: function() {
				let machine = e.focused_row_cell_val('machine')
				if (machine)
					post('/api/log-server', [machine])
			},
		})

	})

})

function ssh_key_gen() {
	this.post('/api/ssh-key-gen')
}

function ssh_key_updates() {
	this.post('/api/ssh-key-update')
}

function deploy_action(btn, action) {
	let deploy = mm_deploys_grid.focused_row_cell_val('deploy')
	btn.post(['', 'api', action], [deploy])
}
function deploy_start   () { deploy_action(this, 'deploy-start') }
function deploy_stop    () { deploy_action(this, 'deploy-stop') }
function deploy_restart () { deploy_action(this, 'deploy-restart') }
function deploy_deploy  () { deploy_action(this, 'deploy') }
function deploy_remove  () { deploy_action(this, 'deploy-remove') }

function deploy_backup() {
	this.post('/api/xbkp-backup', [this.val('deploy')])
}
