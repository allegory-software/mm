
local mm = require'xapp'.app'mm'

mm.title = 'Many Machines'
mm.font = 'opensans'

config('db_port', 3307)
config('db_pass', 'abcd12')
config('var_dir', '.')
config('session_secret', '!xpAi$^!@#)fas!`5@cXiOZ{!9fdsjdkfh7zk')
config('pass_salt'     , 'is9v09z-@^%@s!0~ckl0827ScZpx92kldsufy')

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
		cpu         $name,
		ram_gb      double,
		hdd_gb      double,
		cores       smallint,
		os_ver      $name,
		mysql_ver   $name,
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

end

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
		</x-listbox>
	</div>
	<x-switcher nav_id=actions_listbox>
		<x-grid action=machines rowset_name=machines></x-grid>
		<x-grid action=deploys rowset_name=deploys></x-grid>
	</x-switcher>
</x-split>
]]

rowset.machines = sql_rowset{
	select = [[
		select
			machine,
			public_ip,
			local_ip,
			last_seen,
			cpu,
			ram_gb,
			hdd_gb,
			cores,
			os_ver,
			mysql_ver
		from
			machine
		order by
			pos, ctime
	]],
	pk = 'machine',
	insert_row = function(row)
		insert_row('machine', row, 'machine public_ip local_ip')
	end,
	update_row = function(row)
		update_row('machine', row, 'machine public_ip local_ip')
	end,
	delete_row = function(row)
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
	insert_row = function(row)
		row.deploy = insert_row('deploy', row, 'machine repo version')
	end,
	update_row = function(row)
		update_row('deploy', row, 'machine repo version')
	end,
	delete_row = function(row)
		delete_row('deploy', row, 'deploy')
	end,
}

return mm.run'install'
