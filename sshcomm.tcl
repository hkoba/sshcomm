# -*- mode: tcl; tab-width: 8; coding: utf-8 -*-
#
#  Usage:
#
#   package require sshcomm
#   set comm_id [sshcomm::comm $host]
#   comm::comm send $comm_id {script...}
#
#  Or more configurable style:
#
#   set obj [sshcomm::ssh -host $host]
#   # or set obj [sshcomm::connection %AUTO% -host $host]
#   set c1 [$obj comm new]
#   set c2 [$obj comm new]
#   comm::comm send -async $c1 {script...}
#   comm::comm send -async $c2 {script...}
#

# To change log level to 3:
#
#   sshcomm::configure -debuglevel 3 -debugchan stdout
#

package require snit
package require comm

namespace eval ::sshcomm {
    namespace eval remote {}

    proc comm {host args} {
	[pooled_ssh $host {*}$args] comm new
    }
    proc ssh {host args} {
	::sshcomm::connection %AUTO% -host $host {*}$args
    }

    variable sshPool; array set sshPool {}
    proc pooled_ssh {host args} {
	variable sshPool
	set vn sshPool($host)
	if {[info exists $vn]} {
	    # XXX: $args are ignored for the second call. Is this ok?
	    set $vn
	} else {
	    set $vn [ssh $host {*}$args]
	}
    }

    proc list-connections {} {
	variable sshPool
	array names sshPool
    }
    proc forget {host} {
	variable sshPool
	set vn sshPool($host)
	if {![info exists $vn]} return
	set obj [set $vn]
	unset $vn
	$obj destroy
    }
    proc forget-all {} {
	variable sshPool
	set result {}
	foreach host [list-connections] {
	    dlog 3 "forget $host"
	    if {[catch [list forget $host] error]} {
		lappend result [list $host $error $::errorInfo]
	    }
	}
	if {[llength $result]} {
	    error "sshcomm::destroy-all error: $result"
	}
    }

    variable config
    array set config [list -debugchan "" -debuglevel 0 -sshcmd ""]
    proc configure args {
	variable config
	foreach {name value} $args {
	    set vn config($name)
	    if {[info exists $vn]} {
		set $vn $value
	    } else {
		error "Invalid option for sshcomm::config: $name"
	    }
	}
    }

    variable debugLog ""
    proc dlog {level args} {
	variable config
	variable debugLog
	if {$config(-debugchan) ne ""} {
	    if {$config(-debuglevel) < $level} return
	    puts $config(-debugchan) "\[[pid]\] $args"
	} else {
	    lappend debugLog [list $level $args]
	}
    }

    proc default {varName default} {
	upvar 1 $varName var
	if {[info exists var]} {
	    set var
	} else {
	    set default
	}
    }

    proc probe-port {} {
	set sock [socket -server {apply {args {}}} 0]
	set port [lindex [fconfigure $sock -sockname] end]
	close $sock
	set port
    }

    proc finally {varName command} {
	# [apply] is to discard additional arguments from [trace add var].
        uplevel 1 [list trace add variable $varName unset \
                       [list apply [list args $command]]]

    }

    proc varbackup {scopeVar varName newValue} {
	upvar 1 $scopeVar old $varName var
	set old $var
	set var $newValue
	# Since [finally] uses apply, we need one more [uplevel].
	uplevel 1 [list finally $scopeVar \
		       [list uplevel 1 [list set $varName $old]]]
    }
}

#########################################
# Local side, per-connection object.
#
snit::type sshcomm::connection {
    option -host ""
    option -lport ""; # Local port
    option -rport ""; # Remote port
    option -localhost localhost

    option -sshcmd ""
    option -autoconnect yes
    option -tclsh tclsh

    option -remote-config {}

    variable mySSH ""; # Control channel
    constructor args {
	$self configurelist $args
	if {$options(-autoconnect)} {
	    $self connect
	}
    }

    destructor {
	if {$mySSH ne ""} {
	    foreach cid [$self comm list] {
		$self comm forget $cid
	    }

	    ::sshcomm::dlog 2 closing $mySSH pid [pid $mySSH]
	    puts $mySSH "exit"
	    close $mySSH
	}
    }

    method connect {args} {
	if {$options(-host) eq ""} {
	    error "host is empty"
	}
	$self remote open $options(-host)
	$self remote setup {*}$args
    }

    option -wait-after-probe 150
    method {remote open} host {
	if {$options(-rport) eq ""} {
	    set options(-rport) [$self probe-remote-port $host]
	    if {$options(-wait-after-probe) ne ""} {
		# XXX: event loop
		after $options(-wait-after-probe)
	    }
	}
	if {$options(-lport) in {"" 0}} {
	    set options(-lport) [::sshcomm::probe-port]
	}
	
	set cmd [$self sshcmd {*}[$self forwarder] \
		     $host $options(-tclsh)]

	::sshcomm::dlog 2 open $cmd
	set mySSH [open [list | {*}$cmd] w+]
	fconfigure $mySSH -buffering line
	set mySSH
    }

    #
    # XXX:BUG This may not work when sshcomm::remote::keepalive is active.
    # use [comm::comm send $cid [sshcomm::definition $ns]], instead.
    #
    method {remote redefine} {{ns "::sshcomm"} args} {
	puts $mySSH [sshcomm::definition $ns {*}$args]
	puts $mySSH {}
	flush $mySSH
    }

    method {remote setup} args {
	puts $mySSH {
	    fconfigure stdout -buffering line
	    fconfigure stderr -buffering line
	}
	$self remote redefine
	puts $mySSH [list ::sshcomm::remote::setup $options(-rport) \
			 {*}$options(-remote-config) {*}$args]
	flush $mySSH

	if {[gets $mySSH line] <= 0} {
	    close $mySSH; # This will raise ssh startup error.
	    set mySSH ""
	    error "Can't invoke sshcomm!"; # May not reached.
	}
	# XXX: Should record remote pid
	if {$line ne "OK port $options(-rport)"} {
	    error "Unknown result: $line"
	}
	fileevent $mySSH readable [list $self remote readable]
	update idletask
	set mySSH
    }

    variable myLastCommID 0
    variable myCommDict; array set myCommDict {}
    method {comm new} {} {
	# XXX: Refactor this negotiation as extensible form.
	set cookie [clock seconds].[expr {int(100000000 * rand())}]

	# [1] Register cookie via established ssh channel
	puts $mySSH [list ::sshcomm::remote::cookie-add $cookie]

	# [2] Open forwarding socket
	set sock [socket $options(-localhost) $options(-lport)]
	::sshcomm::dlog 3 forward socket $sock for $options(-host)

	# [3] Send the cookie. Without it, remote will reject connection.
	puts $sock $cookie
	flush $sock

	set cid [$self comm init $sock]
	# Too much?
	proc ::$cid args "comm::comm send [list $cid] \$args"

	set cid
    }

    method {comm init} sock {
	# To emulate ::comm::commConnect
	if {[llength [info commands ::$sock]]} {
	    ::sshcomm::dlog 1 warning "socket command confliction for $sock"\
		host $options(-host)
	    rename ::$sock ""
	}

	set chan ::comm::comm; # XXX: ok??
	::comm::comm new $sock
	set cid [list [incr myLastCommID] $options(-host)]
	set myCommDict($cid) $sock

	::comm::commNewConn $chan $cid $sock
	puts $sock [list $::comm::comm(offerVers) $::comm::comm($chan,port)]
	set ::comm::comm($chan,vers,$cid) $::comm::comm(defVers)
	flush $sock
	set cid
    }
    method {comm forget} cid {
	::sshcomm::dlog 2 comm shutdown $cid
	::comm::comm shutdown $cid

	# Workaround for proc collision.
	set sock $myCommDict($cid)
	array unset myCommDict($cid)
	if {[llength [info commands ::$sock]]} {
	    rename ::$sock ""
	}
    }
    method {comm list} {} {
	array names myCommDict
    }

    # keepalive
    # control response
    method {remote readable} {} {
	if {[gets $mySSH line]} {
	    ::sshcomm::dlog 4 from $options(-host) "GOT($line)"
	}
	if {[eof $mySSH]} {
	    ::sshcomm::dlog 4 closing ssh $options(-host)
	    close $mySSH
	}
    }

    #========================================

    method forwarder {} {
	list -L $options(-lport):$options(-localhost):$options(-rport)
    }

    method probe-remote-port host {
	sshcomm::varbackup old options(-forwardx11) no
	set probe [list [info body sshcomm::probe-port]]
	set cmd [$self sshcmd $host $options(-tclsh) << [subst -nocommand {
	    puts [apply [list {} $probe]]
	}]]
	::sshcomm::dlog 2 probe-remote-port $cmd
	update
	set rport [exec {*}$cmd]
	update idletask
	set rport
    }

    method sshcmd args {
	list {*}[if {$options(-sshcmd) ne ""} {
	    set options(-sshcmd)
	} else {
	    $self $::tcl_platform(platform) sshcmd
	}] {*}$args
    }
    option -forwardx11 yes
    method {unix sshcmd} {} {
	set cmd [list ssh -o StrictHostKeyChecking=true -T]
	if {$options(-forwardx11)
	    && [info exists ::env(DISPLAY)]
	    && $::env(DISPLAY) ne ""} {
	    lappend cmd -Y
	} else {
	    lappend cmd -x
	}
	set cmd
    }
    method {windows sshcmd} {} {
	list plink
    }
}

#========================================

proc ::sshcomm::definition-of-proc {proc} {
    set args {}
    foreach var [info args $proc] {
	if {[info default $proc $var default]} {
	    lappend args [list $var $default]
	} else {
	    lappend args $var
	}
    }
    list proc $proc $args [info body $proc]
}

proc ::sshcomm::definition {{ns {}} args} {
    if {$ns eq ""} {
	set ns [namespace current]
    }
    set result {}
    foreach ns [list $ns {*}$args] {
	foreach n [namespace-ancestry $ns] {
	    append result [list namespace eval $n {}]\n
	}
	foreach proc [info procs [set ns]::*] {
	    append result [definition-of-proc $proc]\n
	}
	foreach vn [info vars [set ns]::*] {
	    if {![info exists $vn]} {
		# really??
		continue
	    } elseif {[array exists $vn]} {
		append result [list array set $vn [array get $vn]]\n
	    } else {
		append result [list set $vn [set $vn]]\n
	    }
	}
	if {[llength [set pats [namespace eval $ns [list namespace export]]]]} {
	    append result [list namespace eval $ns \
			       [list namespace export {*}$pats]]\n
	}
	if {[namespace ensemble exists $ns]} {
	    set ensemble [namespace ensemble configure $ns]
	    dict unset ensemble -namespace
	    # -parameters is not available in 8.5
	    foreach drop [list -parameters] {
		if {![dict exists $ensemble $drop]
		    || [dict get $ensemble $drop] ne ""} continue
		dict unset ensemble $drop
	    }
	    append result [list namespace eval $ns \
			       [list namespace ensemble create {*}$ensemble]]\n
	}
	foreach ns [namespace children $ns] {
	    # puts "ns=$ns"
	    append result [definition $ns]\n
	}
    }
    set result
}

proc ::sshcomm::namespace-ancestry ns {
    set result {}
    while {$ns ne "" && $ns ne "::"} {
	set result [linsert $result 0 $ns]
	set ns [namespace parent $ns]
    }
    set result
}

#########################################
# Remote
#

# XXX: This should be snit too, but remote migration of snit::type is not yet...
namespace eval ::sshcomm::remote {
    variable config; array set config {}

    variable authCookie; array set authCookie {}
    variable myServerSock ""

    variable attackers; array set attackers {}
}

proc ::sshcomm::remote::setup {port args} {
    variable config; array set config $args

    package require comm
    comm::comm destroy

#    interp bgerror {} [list apply {{msg dict} {
#	puts "ERROR($msg) $dict"
#	exit
#    }}]

    variable myServerSock [socket -server [namespace current]::accept $port]
    puts "OK port $port"
    flush stdout
    after 30000 [list [namespace current]::keepalive 30000]
    fileevent stdin readable [list [namespace current]::control stdin]
    vwait [namespace current]::forever
}

proc ::sshcomm::remote::accept {sock addr port} {
    set rc [catch {
	dputs "connected from $addr:$port"
	variable attackers
	if {! ($addr in {0.0.0.0 127.0.0.1})} {
	    incr attackers($addr)
	    close $sock
	    dputs " -> closed"
	    return
	}
	# XXX: Should use non blocking read.
	# XXX: Should limit read length (to avoid extremely long line)
	set cookie [gets $sock]
	dputs " -> got cookie: $cookie"

	if {![cookie-del $cookie]} {
	    incr attackers($addr,$port)
	    close $sock
	    dputs " -> no such cookie, closed"
	    return
	}
	
	# new だけじゃ、 commCollect が set されない！
	# commNewConn を呼ぶ必要がある
	# それは commConnect か, commIncoming か、どちらかから呼ばれる
	::comm::comm new $sock
	dputs "Now channels = $::comm::comm(chans)"
	::comm::commIncoming ::$sock $sock $addr $port
	dputs connected
    } error]

    if {$rc && $rc != 2} {
	after idle [list apply [list {sock error ei} {
	    puts "ERROR(remote::accept): $error\n$ei"
	    close $sock
	}] $sock $error $::errorInfo]
    }
}

proc ::sshcomm::remote::cookie-add {cookie {value ""}} {
    variable authCookie
    if {$value eq ""} {
	set value [clock seconds]
    }
    set authCookie($cookie) $value
}

proc ::sshcomm::remote::cookie-del cookie {
    variable authCookie
    set vn authCookie($cookie)
    if {[info exists $vn]} {
	unset $vn
	return 1
    } else {
	return 0
    }
}

proc ::sshcomm::remote::cget {name default} {
    variable config
    set vn config($name)
    if {[info exists $vn]} {
	set $vn
    } else {
	set default
    }
}

proc ::sshcomm::remote::dputs {args} {
    if {![cget -verbose no]} return
    puts $args
}

proc ::sshcomm::remote::keepalive msec {
    puts "pid [pid] [clock seconds]"
    after $msec [list [namespace current]::keepalive $msec]
}

proc ::sshcomm::remote::control {fh args} {
    set count [gets $fh line]
    if {$count < 0} {
	close $fh
	exit
    }
    if {$count > 0} {
	set rc [catch [list uplevel \#0 $line] error]
	if {$rc} {
	    puts "ERROR($error) $::errorInfo"
	    exit
	}
    }
}

proc ::sshcomm::remote::fread {fn args} {
    set fh [open $fn]
    if {[llength $args]} {
	fconfigure $fh {*}$args
    }
    set data [read $fh]
    close $fh
    set data
}

#========================================
# Deprecated API.
namespace eval ::sshcomm::client {
    proc create host {
	::sshcomm::comm $host
    }
}
namespace eval ::sshcomm {
    proc sshcmd {} {
	if {$::tcl_platform(platform) eq "windows"} {
	    return plink
	} else {
	    list ssh -o StrictHostKeyChecking=true -T
	}
    }
}
#========================================

package provide sshcomm 0.3

