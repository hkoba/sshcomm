# -*- mode: tcl; tab-width: 8 -*-
#
#  Usage:
#
#   package require sshcomm
#   set comm_id [sshcomm::new $host]
#   comm::comm send $comm_id {script...}
#
#  Or more configurable style:
#
#   set ssh [sshcomm::ssh %AUTO% -host $host]
#   set c1 [$ssh comm new]
#   set c2 [$ssh comm new]
#   comm::comm send $c1 {script...}
#   comm::comm send $c2 {script...}
#

package require snit
package require comm

namespace eval ::sshcomm {
    namespace eval remote {}

    proc new {host args} {
	[connection $host] comm new {*}$args
    }

    variable sshPool; array set sshPool {}
    proc connection {host args} {
	variable sshPool
	set vn sshPool($host)
	if {[info exists $vn]} {
	    set $vn
	} else {
	    set $vn [::sshcomm::ssh %AUTO% -host $host {*}$args]
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
	    puts $config(-debugchan) $args
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
}

#########################################
# Local side, per-connection object.
#
snit::type sshcomm::ssh {
    option -host ""
    option -lport ""; # Local port
    option -rport ""; # Remote port
    option -localhost 0

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

    method {remote open} host {
	if {$options(-rport) eq ""} {
	    set options(-rport) [$self probe-remote-port $host]
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

    method {remote setup} args {
	puts $mySSH {
	    fconfigure stdout -buffering line
	    fconfigure stderr -buffering line
	}
	puts $mySSH [sshcomm::definition]
	puts $mySSH {}
	puts $mySSH [list ::sshcomm::remote::setup $options(-rport) \
			 {*}$options(-remote-config) {*}$args]
	flush $mySSH

	if {[gets $mySSH line] <= 0} {
	    close $mySSH; # This will raise ssh startup error.
	    set mySSH ""
	    error "Can't invoke sshcomm!"; # May not reached.
	}
	if {$line ne "OK port $options(-rport)"} {
	    error "Unknown result: $line"
	}
	fileevent $mySSH readable [list $self remote readable]
	update idletask
	set mySSH
    }

    variable myLastCommID 0
    method {comm new} {} {
	# cookie を作って、
	set cookie [clock seconds].[expr {int(100000000 * rand())}]

	# cookie を mySSH 経由で送ってから、
	puts $mySSH [list ::sshcomm::remote::cookie-add $cookie]

	# socket を開き, cookie を送る
	set sock [socket $options(-localhost) $options(-lport)]
	puts $sock $cookie
	flush $sock

	$self comm init $sock
    }

    method {comm init} sock {
	# To emulate ::comm::commConnect
	set chan ::comm::comm; # XXX: ok??
	::comm::comm new $sock
	set cid [list [incr myLastCommID] $options(-host)]
	::comm::commNewConn $chan $cid $sock
	puts $sock [list $::comm::comm(offerVers) $::comm::comm($chan,port)]
	set ::comm::comm($chan,vers,$cid) $::comm::comm(defVers)
	flush $sock
	set cid
    }

    # keepalive
    # control response
    method {remote readable} {} {
	if {[gets $mySSH line]} {
	    puts "GOT($line)"
	}
	if {[eof $mySSH]} {
	    puts "closing control channel.."
	    close $mySSH
	}
    }

    #========================================

    method forwarder {} {
	list -L $options(-lport):$options(-localhost):$options(-rport)
    }

    method probe-remote-port host {
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
    method {unix sshcmd} {} {
	set cmd [list ssh -o StrictHostKeyChecking=true -T]
	if {[info exists ::env(DISPLAY)] && $::env(DISPLAY) ne ""} {
	    lappend cmd -Y
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

proc ::sshcomm::definition {{ns {}}} {
    if {$ns == ""} {
	return [definition [namespace current]]
    } else {
	set result {}
	append result [list namespace eval $ns {}]\n
	foreach proc [info procs [set ns]::*] {
	    append result [definition-of-proc $proc]\n
	    
	}
	foreach ns [namespace children $ns] {
	    # puts "ns=$ns"
	    append result [definition $ns]\n
	}
	set result
    }
}

proc ::sshcomm::sshcmd {} {
    variable config
    if {$config(-sshcmd) ne ""} {
	return $config(-sshcmd)
    }

    set cmdName [namespace current]::sshcmd/$::tcl_platform(platform)
    if {[info procs $cmdName] != ""} {
	return [$cmdName]
    }

    set cmd [list ssh -o StrictHostKeyChecking=true -T]
    if {$::tcl_platform(platform) eq "unix"
	&& [info exists ::env(DISPLAY)]
	&& $::env(DISPLAY) ne ""} {
	lappend cmd -Y
    }
    return $cmd
}

proc ::sshcomm::sshcmd/windows {} {
    return plink
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
    puts [clock seconds]
    after $msec [list [namespace::current]::keepalive $msec]
}

proc ::sshcomm::remote::control {fh args} {
    set count [gets $fh line]
    if {$count < 0} {
	close $fh
	exit
    }
    if {$count > 0} {
	uplevel \#0 $line
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

package provide sshcomm 0.2
