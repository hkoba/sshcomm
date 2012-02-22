# -*- mode: tcl; tab-width: 8 -*-
#
#  Usage:
#
#   package require sshcomm
#   set comm_id [sshcomm::new $host]
#   comm::comm send $comm_id {script...}

package require snit

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
}

#########################################
# Local side, per-connection object.
#
snit::type sshcomm::ssh {
    option -host ""
    option -port ""; # Remote port for this host.
    option -sshcmd ""
    option -autoconnect yes
    option -tclsh tclsh
    option -localhost 0

    option -remote-config {}

    variable mySSH ""; # Control channel

    typevariable ourPort ""
    typeconstructor {
	package require comm
	if {$ourPort eq ""} {
	    # To recycle master listener port
	    set ourPort [comm::comm self]
	    comm::comm destroy
	    ::comm::comm new ::comm::comm
	}
    }

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
	if {$options(-port) eq ""} {
	    set options(-port) [$self probe-available-port $host]
	}
	
	set cmd [$self sshcmd {*}[$self forwarder $options(-port)] \
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
	puts $mySSH [list ::sshcomm::remote::setup $options(-port) \
			 {*}$options(-remote-config) {*}$args]
	flush $mySSH

	if {[gets $mySSH line] <= 0} {
	    close $mySSH; # This will raise ssh startup error.
	    set mySSH ""
	    error "Can't invoke sshcomm!"; # May not reached.
	}
	if {$line ne "OK port $options(-port)"} {
	    error "Unknown result: $line"
	}
	fileevent $mySSH readable [list $self remote readable]
	set mySSH
    }

    variable myLastCommID 0
    method {comm new} {} {
	# cookie を作って、
	set cookie [expr {int(100000000 * rand())}]

	# cookie を mySSH 経由で送ってから、
	puts $mySSH [list ::sshcomm::remote::register $cookie]

	# socket を開き, cookie を送る
	set sock [socket $options(-localhost) $ourPort]
	puts $sock $cookie
	flush $sock

	$self comm handshake $sock
    }

    method {comm handshake} sock {
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
	    close $mySSH
	}
    }

    #========================================

    method forwarder rport {
	list -L $ourPort:$options(-localhost):$rport
    }

    method probe-available-port host {
	set cmd [$self sshcmd $host $options(-tclsh) << {
	    package require comm
	    puts [comm::comm self]
	}]
	::sshcomm::dlog 2 probe-available-port $cmd
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

#----------------------------------------
if {0} {

proc ::sshcomm::master::probe-available-port host {
    package require comm
    # To recycle master listener port
    set master [comm::comm self]
    comm::comm destroy
    ::comm::comm new ::comm::comm
    
    eval [list lappend cmd] [sshcomm::sshcmd]
    lappend cmd $host tclsh
    lappend cmd << {
	package require comm
	puts [comm::comm self]
    }
    lappend ::sshcomm::debugLog "master::probe-available-port $host by $cmd"
    set remote [eval [list exec] $cmd]
    list $master $host $remote
}

# ::sshcomm::master::create --
#
#     
#
# Arguments:
#      host   remote hostname.
#
# Results:
#      comm id.

proc ::sshcomm::master::create host {
    update
    set forward [probe-available-port $host]
    update
    if {[llength $forward] != 3} {
	error "Can't detect available ports for $host"
    }
    eval [list create-forward] $forward
}

proc ::sshcomm::master::create-forward {lport host rport} {
    set fh [connect $lport $host $rport]
    setup-remote $fh $rport
    wait-remote $lport $fh $rport
}

proc ::sshcomm::master::connect {lport host rport} {
    variable $lport; upvar 0 $lport data
    
    set cmd "| [sshcomm::sshcmd] -L $lport:localhost:$rport $host"
    append cmd " tclsh"
    lappend ::sshcomm::debugLog "master::connect $host by $cmd"
    set fh [open $cmd w+]
    fconfigure $fh -buffering line
    array set data [list fh $fh host $host rport $rport]
    set fh
}

proc ::sshcomm::master::setup-remote {fh rport} {
    puts $fh {
	fconfigure stdout -buffering line
	fconfigure stderr -buffering line
    }
    puts $fh [sshcomm::definition]
    puts $fh {}
    puts $fh [list ::sshcomm::remote::create $rport]
    flush $fh
}

proc ::sshcomm::master::wait-remote {lport fh rport} {
    if {[gets $fh line] <= 0} {
	close $fh
	error "Can't invoke sshcomm!"
    }
    if {$line != "OK port $rport"} {
	error "Unknown result: $line"
    }
    fileevent $fh readable [list gets $fh [namespace current]::last-click]
    comm::comm connect $lport
    set lport
}

proc ::sshcomm::master::last-click {} {
    variable last-click
    set last-click
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
    after 30000 keepalive
    fileevent stdin readable [list [namespace current]::control stdin]
    vwait [namespace current]::forever
}

proc ::sshcomm::remote::accept {sock addr port} {
    dputs "connected from $addr:$port"
    variable attackers
    if {! ($addr in {0.0.0.0 127.0.0.1})} {
	incr attackers($addr)
	close $sock
	dputs " -> closed"
    }
    # XXX: Should use non blocking read.
    set cookie [gets $sock]
    dputs " -> got cookie: $cookie"

    variable authCookie
    set vn authCookie($cookie)
    if {![info exists $vn]} {
	incr attackers($addr,$port,$cookie)
	close $sock
	dputs " -> no such cookie, closed"
    }
    unset $vn

    # new だけじゃ、 commCollect が set されない！
    # commNewConn を呼ぶ必要がある
    # それは commConnect か, commIncoming か、どちらかから呼ばれる
    if {[catch {
	::comm::comm new $sock
	dputs "Now channels = $::comm::comm(chans)"
	::comm::commIncoming ::$sock $sock $addr $port
    } error]} {
	dputs "ERROR in commIncoming: $error\n$::errorInfo"
    } else {
	dputs connected
    }
}

proc ::sshcomm::remote::register cookie {
    variable authCookie
    set authCookie($cookie) [clock seconds]
}

proc ::sshcomm::remote::cget {name {default ""}} {
    variable config
    set vn config($name)
    if {[info exists $vn]} {
	set $vn
    } else {
	set dfault
    }
}

proc ::sshcomm::remote::dputs {args} {
    if {![cget -verbose no]} return
    puts $args
}

proc ::sshcomm::remote::keepalive {{sec 30}} {
    puts [clock seconds]
    variable keepalive_id [after [expr {$sec * 1000}] \
			       [namespace code [info level 0]]]
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
