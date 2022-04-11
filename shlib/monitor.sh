#use mysql

machine_info() {
	echo "   os_ver $(lsb_release -sd)"
	echo "mysql_ver $(has_mysql && query 'select version();')"
	echo "      cpu $(lscpu | sed -n 's/^Model name:\s*\(.*\)/\1/p')"
	local      cps="$(lscpu | sed -n 's/^Core(s) per socket:\s*\(.*\)/\1/p')"
	local  sockets="$(lscpu | sed -n 's/^Socket(s):\s*\(.*\)/\1/p')"
	echo "    cores $(expr $sockets \* $cps)"
	echo "      ram $(cat /proc/meminfo | awk '/MemTotal/ {$2*=1024; printf "%.0f",$2}')"
	echo "      hdd $(df -l / | awk '(NR > 1) {$2*=1024; printf "%.0f",$2}')"
}
