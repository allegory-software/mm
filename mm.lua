
local mm = require'webb_xapp'.app'mm'
require'x_auth'

mm.title = 'Many Machines'

config('db_port', 3307)
config('db_pass', 'abcd12')
config('var_dir', '.')
config('session_secret', '!xpAi$^!@#)fas!`5@cXiOZ{!9fdsjdkfh7zk')
config('pass_salt'     , 'is9v09z-@^%@s!0~ckl0827ScZpx92kldsufy')

function mm.install()

	auth_create_tables()

	query[[
	$table machine (
		machine   $strpk,
		public_ip $name,
		local_ip  $name,
		ssh_key   blob,
		last_seen timestamp,
		os_ver    $name,
		mysql_ver $name,
		pos       $pos,
		ctime     $ctime
	);
	]]

	query[[
	$table deploy (
		deploy    $strpk,
		machine   $strid not null, $fk(deploy, machine),
		repo      $name not null,
		version   $strid not null
	);
	]]

end

js[[

on_dom_load(function() {
	init_components()
	init_auth()
	init_action()
})

]]

html[[
<div class=header>
	<div class=logo>
		<a href=/>Many Machines</a>
	</div>
	<x-settings-button></x-settings-button>
</div>
<x-grid rowset_name=machines></x-grid>
]]

rowset.machines = sql_rowset{
	select = [[
		select
			machine,
			public_ip,
			local_ip,
			last_seen,
			os_ver,
			mysql_ver
		from
			machine
		order by
			pos, ctime
	]],
	pk = 'machine'
}

return mm.run'start'
