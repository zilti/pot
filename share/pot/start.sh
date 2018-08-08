#!/bin/sh

# supported releases
start-help()
{
	echo "pot start [-h] [potname]"
	echo '  -h print this help'
	echo '  -v verbose'
	echo '  -s take a snapshot before to start'
	echo '     snapshots are identified by the epoch'
	echo '     all zfs datasets under the jail dataset are considered'
	echo '  -S take a snapshot before to start'
	echo '     snapshots are identified by the epoch'
	echo '     all zfs datasets mounted in rw are considered (full)'
	echo '  potname : the jail that has to start'
}

# $1 pot name
# $2 the network interface, if created
start-cleanup()
{
	local _pname
	_pname=$1
	if [ -z "$_pname" ]; then
		return
	fi
	if [ -n $2 ]; then
		ifconfig $2 destroy
	fi
	pot-cmd stop $_pname
}

# $1 pot name
_js_dep()
{
	local _pname _depPot
	_pname=$1
	_depPot="$( _get_conf_var $_pname pot.depend )"
	if [ -z "$_depPot" ]; then
		return 0 # true
	fi
	for _d in $_depPot ; do
		pot-start $_depPot
	done
	return 0 # true
}

# $1 jail name
_js_mount()
{
	local _pname _node _mnt_p _opt _dset
	_pname=$1
	_debug "Using the fscomp.conf"
	while read -r line ; do
		_dset=$( echo $line | awk '{print $1}' )
		_mnt_p=$( echo $line | awk '{print $2}' )
		_opt=$( echo $line | awk '{print $3}' )
		if [ "$_opt" = "zfs-remount" ]; then
			zfs set mountpoint=$_mnt_p $_dset
			_node=$( _get_zfs_mountpoint $_dset )
			if _zfs_exist $_dset $_node ; then
				# the information are correct - move the mountpoint
				_debug "start: the dataset $_dset is mounted at $_node"
			else
				# mountpoint already moved ?
				_error "Dataset $_dset not mounted at $_mnt_p! Aborting"
				start-cleanup $_pname
				return 1 # false
			fi
		else
			_node=$( _get_zfs_mountpoint $_dset )
			mount_nullfs -o ${_opt:-rw} $_node $_mnt_p
			if [ "$?" -ne 0 ]; then
				_error "Error mounting $_node"
				start-cleanup $_pname
				return 1 # false
			else
				_debug "mount $_mnt_p"
			fi
		fi
	done < ${POT_FS_ROOT}/jails/$_pname/conf/fscomp.conf
	mount -t tmpfs tmpfs ${POT_FS_ROOT}/jails/$_pname/m/tmp
	if [ "$?" -ne 0 ]; then
		_error "Error mouning tmpfs"
		start-cleanup $_pname
		return 1 # false
	else
		_debug "mount ${POT_FS_ROOT}/jails/$_pname/m/tmp"
	fi
}

# $1 pot name
_js_resolv()
{
	local _pname _jdir _dns
	_pname="$1"
	_jdir="${POT_FS_ROOT}/jails/$_pname"
	_dns="$(_get_conf_var $_pname pot.dns)"
	if [ -z "$_dns" ]; then
		_dns=inherit
	fi
	if [ "$_dns" = "inherit" ]; then
		if [ ! -r /etc/resolv.conf ]; then
			_error "No resolv.conf found in /etc"
			start-cleanup $_pname
			return 1 # false
		fi
		if [ -d $_jdir/m/etc ]; then
			cp /etc/resolv.conf $_jdir/m/etc
		else
			_info "No custom etc directory found, resolv.conf not loaded"
		fi
	else # resolv.conf generation
		_domain="$( _get_conf_var $_pname host.hostname | cut -f 2 -d'.' )"
		echo "# Generated by pot" > $_jdir/m/etc/resolv.conf
		echo "search $_domain" >> $_jdir/m/etc/resolv.conf
		echo "nameserver ${POT_DNS_IP}" >> $_jdir/m/etc/resolv.conf
	fi
	return 0
}

_js_create_epair()
{
	local _epair
	_epair=$(ifconfig epair create)
	if [ -z "${_epair}" ]; then
		_error "ifconfig epair failed"
		start-cleanup $_pname
		exit 1 # false
	fi
	echo ${_epair%a}
}

# $1 pot name
_js_vnet()
{
	local _pname _bridge _epair _epairb _ip
	_pname=$1
	if ! _is_vnet_up ; then
		_info "No pot bridge found! Calling vnet-start to fix the issue"
		pot-cmd vnet-start
	fi
	_bridge=$(_pot_bridge)
	_epair=${2}a
	_epairb="${2}b"
	ifconfig ${_epair} up
	ifconfig $_bridge addm ${_epair}
	_ip=$( _get_conf_var $_pname ip4 )
	# set the network configuration in the pot's rc.conf
	if [ -w ${POT_FS_ROOT}/jails/$_pname/m/etc/rc.conf ]; then
		sed -i '' '/ifconfig_epair/d' ${POT_FS_ROOT}/jails/$_pname/m/etc/rc.conf
	fi
	echo "ifconfig_${_epairb}=\"inet $_ip netmask $POT_NETMASK\"" >> ${POT_FS_ROOT}/jails/$_pname/m/etc/rc.conf
	sysrc -f ${POT_FS_ROOT}/jails/$_pname/m/etc/rc.conf defaultrouter="$POT_GATEWAY"
}

# $1: exclude list
_js_get_free_rnd_port()
{
	local _min _max exc_ports used_ports rdr_ports rand
	excl_ports="$1"
	_min=$( sysctl -n net.inet.ip.portrange.reservedhigh )
	_min=$(( _min + 1 ))
	_max=$( sysctl -n net.inet.ip.portrange.first )
	_max=$(( _max - 1 ))
	used_ports="$(sockstat -p ${_min}-${_max} -4l | awk '!/USER/ { n=split($6,a,":"); if ( n == 2 ) { print a[2]; }}' | sort -u)"
	rdr_ports="$(pfctl -s nat -P | awk '/rdr/ { n=split($0,a," "); for(i=1;i<=n;i++) { if (a[i] == "=" ) { print a[i+1];break;}}}')"
	rand=$_min
	while [ $rand -le $_max ]; do
		for p in $excl_ports $used_ports $rdr_ports ; do
			if [ "$p" = "$rand" ]; then
				rand=$(( rand + 1 ))
				continue 2
			fi
		done
		echo $rand
		break
	done
}

# $1 pot name
_js_export_ports()
{
	local _pname _ip _ports _random_port _excl_list
	_pname=$1
	_ip="$( _get_conf_var $_pname ip4 )"
	_ports="$( _get_pot_export_ports $_pname )"
	_pfrules="/tmp/pot_pfrules"
	pfctl -s nat -P > $_pfrules
	for _port in $_ports ; do
		_random_port=$( _js_get_free_rnd_port "$_excl_list" )
		_debug "Redirect: from $POT_EXTIF : $_random_port to $_ip : $_port"
		echo "rdr pass on $POT_EXTIF proto tcp from any to $POT_EXTIF port $_random_port -> $_ip port $_port" >> $_pfrules
		_excl_list="$excl_list $_random_port"
	done
	pfctl -f $_pfrules
}

# $1 jail name
_js_rss()
{
	local _pname _jid _cpuset _memory
	_pname=$1
	_cpuset="$( _get_conf_var $_pname pot.rss.cpuset)"
	_memory="$( _get_conf_var $_pname pot.rss.memory)"
	if [ -n "$_cpuset" ]; then
		_jid="$( jls -j $_pname | sed 1d | awk '{ print $1 }' )"
		cpuset -l $_cpuset -j $_jid
	fi
	if [ -n "$_memory" ]; then
		if ! _is_rctl_available ; then
			_info "memory constraint cannot be applies because rctl is not enabled - ignoring"
		else
			rctl -a jail:$_pname:memoryuse:deny=$_memory
		fi
	fi
}

# $1 pot name
_js_get_cmd()
{
	# shellcheck disable=SC2039
	local _pname _cdir _value
	_pname="$1"
	_cdir="${POT_FS_ROOT}/jails/$_pname/conf"
	_value="$( grep "^pot.cmd=" "$_cdir/pot.conf" | cut -f2 -d'=' )"
	[ -z "$_value" ] && _value="sh /etc/rc"
	echo "$_value"
}

# $1 jail name
_js_start()
{
	local _pname _jdir _iface _hostname _osrelease _param _ip _cmd
	_pname="$1"
	_cmd="$( _js_get_cmd "$_pname" )"
	_iface=
	_param="allow.set_hostname=false allow.mount allow.mount.fdescfs allow.raw_sockets allow.socket_af allow.sysvipc"
	_param="$_param allow.chflags"
	_param="$_param mount.devfs persist exec.stop=sh,/etc/rc.shutdown"
	_jdir="${POT_FS_ROOT}/jails/$_pname"
	_hostname="$( _get_conf_var $_pname host.hostname )"
	_osrelease="$( _get_conf_var $_pname osrelease )"
	_param="$_param name=$_pname host.hostname=$_hostname osrelease=$_osrelease"
	_param="$_param path=${_jdir}/m"
	if _is_pot_vnet "$_pname" ; then
		_iface="$( _js_create_epair )"
		_js_vnet "$_pname" "$_iface"
		_param="$_param vnet vnet.interface=${_iface}b"
		_js_export_ports "$_pname"
	else
		_ip=$( _get_conf_var $_pname ip4 )
		if [ "$_ip" = "inherit" ]; then
			_param="$_param ip4=inherit"
		else
			_param="$_param interface=${POT_EXTIF} ip4.addr=$_ip"
		fi
	fi
	jail -c -J "/tmp/${_pname}.jail.conf" $_param command=$_cmd
	sleep 1
	if ! _is_pot_running "$_pname" ; then
		start-cleanup $_pname ${_iface}a
		return 1
	fi
	_js_rss "$_pname"
}

pot-start()
{
	local _pname _snap
	_snap=none
	args=$(getopt hvsS $*)
	if [ $? -ne 0 ]; then
		start-help
		exit 1
	fi

	set -- $args
	while true; do
		case "$1" in
		-h)
			start-help
			exit 0
			;;
		-v)
			_POT_VERBOSITY=$(( _POT_VERBOSITY + 1))
			shift
			;;
		-s)
			_snap=normal
			shift
			;;
		-S)
			_snap=full
			shift
			;;
		--)
			shift
			break
			;;
		esac
	done
	_pname=$1
	if [ -z "$_pname" ]; then
		_error "A pot name is mandatory"
		start-help
		exit 1
	fi
	if ! _is_pot $_pname ; then
		exit 1
	fi
	if _is_pot_running $_pname ; then
		_debug "pot $_pname is already running"
		return 0
	fi
	if ! _is_uid0 ; then
		${EXIT} 1
	fi

	if _is_pot_vnet $_pname ; then
		if ! _is_vnet_available ; then
			_error "This kernel doesn't support VIMAGE! No vnet possible - abort"
			${EXIT} 1
		fi
	fi

	if ! _js_dep $_pname ; then
		_error "dependecy failed to start"
	fi
	case $_snap in
		normal)
			_pot_zfs_snap $_pname
			;;
		full)
			_pot_zfs_snap_full $_pname
			;;
		none|*)
			;;
	esac
	if ! _js_mount $_pname ; then
		_error "Mount failed"
		exit 1
	fi
	_js_resolv $_pname
	if ! _js_start $_pname ; then
		_error "$_pname failed to start"
		exit 1
	else
		_info "The pot "${_pname}" started"
	fi
}
