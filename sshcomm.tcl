#!/usr/bin/tclsh
# -*- mode: tcl; tab-width: 8 -*-
# $Id: sshcomm.tcl,v 1.2 2005/05/17 05:01:52 hkoba Exp $
#
#  Usage:
#
#   set num [sshcomm::client::create $host]
#   comm::comm send $num {script...}


package provide sshcomm 0.1

namespace eval ::sshcomm {
    namespace eval server {}
    namespace eval client {
	variable SCRIPT [info script]
    }
}

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
    set cmdName [namespace current]::sshcmd/$::tcl_platform(platform)
    if {[info procs $cmdName] != ""} {
	$cmdName
    } else {
	return "ssh -T"
    }
}

proc ::sshcomm::sshcmd/windows {} {
    return plink
}

#########################################
# Server
#
proc ::sshcomm::create-comm {port listen args} {
    lappend args -port $port -listen $listen
    if {[info exists ::comm::comm]} {
	eval [list ::comm::comm config] $args
    } else {
	namespace eval ::comm {variable comm; array set comm {comm,port 0}}
	package require comm
	unset ::comm::comm(comm,port)
	eval [list ::comm::comm new ::comm::comm] $args
    }
}

proc ::sshcomm::server::create {port args} {
    ::sshcomm::create-comm $port 1
    puts "OK port $port"
    fileevent stdin readable [list [namespace current]::terminator stdin]
    keepalive
    vwait [namespace current]::forever
}

proc ::sshcomm::server::keepalive {{sec 30}} {
    puts [clock seconds]
    variable keepalive_id [after [expr {$sec * 1000}] \
			       [namespace code [info level 0]]]
}

proc ::sshcomm::server::terminator {fh args} {
    set count [gets $fh line]
    if {$count < 0} {
	close $fh
	exit
    }
    if {$count > 0} {
	uplevel \#0 $line
    }
}

#########################################
# Client
#

proc ::sshcomm::client::probe-available-port host {
    package require comm
    # To recycle local listener port
    set local [comm::comm self]
    comm::comm destroy
    ::comm::comm new ::comm::comm
    
    eval [list lappend cmd] [sshcomm::sshcmd]
    lappend cmd $host tclsh
    lappend cmd << {
	package require comm
	puts [comm::comm self]
    }
    set remote [eval [list exec] $cmd]
    list $local $host $remote
}

# ::sshcomm::client::create --
#
#     
#
# Arguments:
#      host   remote hostname.
#
# Results:
#      comm id.

proc ::sshcomm::client::create host {
    set forward [probe-available-port $host]
    if {[llength $forward] != 3} {
	error "Can't detect available ports for $host"
    }
    eval [list create-forward] $forward
}

proc ::sshcomm::client::create-forward {lport host rport} {
    set fh [connect $lport $host $rport]
    setup-server $fh $rport
    wait-server $lport $fh $rport
}

proc ::sshcomm::client::connect {lport host rport} {
    variable $lport; upvar 0 $lport data
    
    set cmd "| [sshcomm::sshcmd] -L $lport:localhost:$rport $host"
    append cmd " tclsh"
    set fh [open $cmd w+]
    fconfigure $fh -buffering line
    array set data [list fh $fh host $host rport $rport]
    set fh
}
proc ::sshcomm::client::setup-server {fh rport} {
    puts $fh {
	fconfigure stdout -buffering line
	fconfigure stderr -buffering line
    }
    puts $fh [sshcomm::definition]
    puts $fh {}
    puts $fh [list ::sshcomm::server::create $rport]
    flush $fh
}

proc ::sshcomm::client::wait-server {lport fh rport} {
    if {[gets $fh line] <= 0} {
	error "Can't invoke sshcomm!"
    }
    if {$line != "OK port $rport"} {
	error "Unknown result: $line"
    }
    fileevent $fh readable [list gets $fh [namespace current]::last-click]
    comm::comm connect $lport
    set lport
}

proc ::sshcomm::client::last-click {} {
    variable last-click
    set last-click
}

proc ::sshcomm::fread {fn} {
    set fh [open $fn]
    set data [read $fh]
    close $fh
    set data
}
