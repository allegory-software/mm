
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

css[[
body {
	/* layout content: center limited-width body to window */
	display: flex;
	flex-flow: column;
}
.header {
	display: flex;
	border-bottom: 1px solid #ccc;
	align-items: baseline;
	justify-content: space-between;
	padding: 0 .5em;
}
]]

js[[
sign_in_options = {
	logo: 'sign-in-logo.png',
}
]]

html[[
<div class=header>
	<div class=logo b>MANY MACHINES</div>
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
