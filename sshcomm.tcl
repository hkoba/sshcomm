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
#   set obj [sshcomm::ssh $host {*}$opts]
#   # or set obj [sshcomm::connection %AUTO% -host $host {*}$opts]
#   set c1 [$obj comm new]
#   set c2 [$obj comm new]
#   comm::comm send -async $c1 {script...}
#   comm::comm send -async $c2 {script...}
#

# To change log level to 3:
#
#   sshcomm::configure -debuglevel 3 -debugchan stderr
#

package require snit
package require comm

namespace eval ::sshcomm {
    namespace eval remote {}

    proc comm {host args} {
	[pooled_ssh $host {*}$args] comm new
    }
    proc ssh {host args} {
	::sshcomm::connection %AUTO% -host $host \
	    -plugins [list-plugins] \
	    {*}$args
    }

    variable pluginList {}
    proc register-plugin {{ns ""}} {
	if {$ns eq ""} {
	    set ns [uplevel 1 namespace current]
	}
	if {[lsearch $::sshcomm::pluginList $ns] < 0} {
	    lappend ::sshcomm::pluginList $ns
	}
    }
    proc list-plugins {} {
	set ::sshcomm::pluginList
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

    proc askpass-helper {sshcomm} {
        ::sshcomm::utils::askpass
    }
    
    proc close-all {fhList args} {
        #
        foreach fh $fhList {
            chan close $fh
        }
    }
}

#########################################
# Local side, per-connection object.
#
snit::type sshcomm::connection {
    option -host ""
    option -lport ""; # Local port
    option -rport ""; # Remote port
    option -localhost 127.0.0.1; # To use ipv4 instead of ipv6.

    option -sshcmd ""
    option -ssh-verbose no
    option -autoconnect yes
    option -tclsh tclsh

    option -sudo no
    option -sudo-askpass-path "";    # external helper
    option -sudo-askpass-command ""; # tcl callback
    option -env-lang ""

    option -remote-config {}
    option -plugins {}

    variable mySSH ""; # Control channel
    constructor args {
	$self configurelist $args
	if {$options(-autoconnect)} {
	    $self connect
	}
    }

    destructor {
	set vn ::sshcomm::sshPool($options(-host))
	if {[info exists $vn]} {
	    unset $vn
	}
	if {$mySSH ne ""} {
	    foreach cid [$self comm list] {
		$self comm forget $cid
	    }

	    ::sshcomm::dlog 2 closing $mySSH pid [pid $mySSH]

            logged_safe_do 2 puts $mySSH "exit"

            close $mySSH
	}
    }

    proc logged_safe_do {level args} {
        if {[set rc [catch $args error]]} {
            ::sshcomm::dlog $level error $error
        }
        set rc
    }

    method connect {args} {
	if {$options(-host) eq ""} {
	    error "host is empty"
	}
	$self remote open $options(-host)
	$self remote prereq
	$self remote setup {*}$args
    }

    option -wait-after-probe 150
    method {remote open} {{host ""}} {
	if {$host eq ""} {
	    set host $options(-host)
	}
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
	
	set cmd [$self sshcmd {*}[$self forwarder] $host]
        if {$options(-ssh-verbose)} {
            set cmd [linsert $cmd 1 -v]
        }

	set envlist {}
	
	if {$options(-env-lang) ne ""} {
	    lappend envlist LANG=$options(-env-lang)
	}

	set sudo {}
	if {$options(-sudo)} {
	    if {$options(-sudo-askpass-path) ne ""} {
		lappend envlist SUDO_ASKPASS=$options(-sudo-askpass-path)
		set sudo [list sudo -A]
	    } elseif {$options(-sudo-askpass-command) ne ""} {
		set sudo [list sudo -S]
	    } else {
		error "No sudo askpass method for -sudo!\nPlease specify either -sudo-askpass-path or -sudo-askpass-command"
	    }
	}
	
	if {$envlist ne ""} {
	    lappend cmd env {*}$envlist
	}

	lappend cmd {*}$sudo $options(-tclsh)
        if {$options(-ssh-verbose)} {
            lappend cmd 2>@ stderr
        }

	::sshcomm::dlog 2 open $cmd
	set mySSH [open [list | {*}$cmd] w+]
	fconfigure $mySSH -buffering line

	if {$options(-sudo) && $options(-sudo-askpass-path) eq ""} {
	    # XXX: This can block
            $self remote expect {^\[sudo\].*:}
            $self remote puts [{*}$options(-sudo-askpass-command)]
	}
	
	set mySSH
    }
    
    method {remote expect} pattern {
        ::sshcomm::dlog 2 expect $pattern
        while {[gets $mySSH line] >= 0} {
            ::sshcomm::dlog 3 got $pattern
            if {[regexp $pattern $line]} return
            ::sshcomm::dlog 3 still waiting $pattern ...
        }
    }

    variable myEvalCnt 0
    # Poor man's rpc. Used while initial handshake and debugging.
    method {remote eval} command {
	set seq [incr myEvalCnt]
	$self remote puts [list apply [list {seq command} {
	    set rc [catch $command res]
	    puts [list $seq $rc $res]
	}] $seq  $command]

	set reply ""
	while {[gets $mySSH line] >= 0} {
	    append reply $line
	    if {[info complete $reply]} break
	}
	if {[lindex $reply 0] != $seq} {
	    error "Remote Eval seqno mismatch! $reply"
	}
	lassign $reply rseq rcode result
	if {$rcode in {0 2}} {
	    return $result
	} else {
	    return -code $rcode $result
	}
    }

    method {remote puts} text {
	puts $mySSH $text
	flush $mySSH
    }

    #
    # XXX:BUG This may not work when sshcomm::remote::keepalive is active.
    # use [comm::comm send $cid [sshcomm::definition $ns]], instead.
    #
    method {remote redefine} {args} {
	$self remote eval [$self current-definition]
    }

    method current-definition args {
	sshcomm::definition ::sshcomm {*}$options(-plugins) {*}$args
    }

    variable myRemoteHasOwnComm ""
    method {remote has-own-comm} {} {
	set myRemoteHasOwnComm
    }
    method {remote prereq} {} {
	if {[catch {$self remote eval {package require comm}} error]} {
	    set myRemoteHasOwnComm no
	    $self remote eval [::sshcomm::definition ::comm]
	    $self remote eval [list package provide comm [package require comm]]
	    $self remote eval {package require comm}
	} else {
	    set myRemoteHasOwnComm yes
	}
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

    method {forward new} spec {
	set cookie [clock seconds].[expr {int(100000000 * rand())}]

	# [1] Register cookie via established ssh channel
	puts $mySSH [list ::sshcomm::remote::cookie-add $cookie $spec]

	# [2] Open forwarding socket
	set sock [socket $options(-localhost) $options(-lport)]
	::sshcomm::dlog 3 new forward localSock $sock opened for $options(-host)

	# [3] Send the cookie. Without it, remote will reject connection.
	puts $sock $cookie
	flush $sock

        set sock
    }

    variable myLastCommID 0
    variable myCommDict; array set myCommDict {}
    method {comm new} {} {

        set sock [$self forward new comm]

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
	set cmd [$self sshcmd $host]
        lappend cmd $options(-tclsh) << [subst -nocommand {
	    puts [apply [list {} $probe]]
	}]
	::sshcomm::dlog 2 probe-remote-port $cmd
	update
	set rport [lindex [split [exec -ignorestderr {*}$cmd] \n] end]
	update idletask
	set rport
    }

    method sshcmd args {
        set sshcmd [if {$options(-sshcmd) ne ""} {
            list {*}$options(-sshcmd) {*}$args
	} else {
	    $self $::tcl_platform(platform) sshcmd {*}$args
	}]
        ::sshcomm::dlog 3 sshcmd $sshcmd
        set sshcmd
    }
    option -strict-host-key-checking yes
    option -forwardx11 yes
    option -prefer-git-ssh yes
    option -ssh-options ""
    method {unix sshcmd} {args} {
        set host [lindex $args end]
        set prefix [lreplace $args end end]

        set vn ::env(GIT_SSH)
        set cmd [if {$options(-prefer-git-ssh) && [info exists $vn]} {
            list [set $vn]
        } else {
            list ssh
        }]
        lappend cmd {*}$options(-ssh-options)
        lappend cmd -o \
            StrictHostKeyChecking=$options(-strict-host-key-checking)\
            -T
	if {$options(-forwardx11)
	    && [info exists ::env(DISPLAY)]
	    && $::env(DISPLAY) ne ""} {
	    lappend cmd -Y
	} else {
	    lappend cmd -x
	}
        lassign [parse-host-port $host] host port
        if {$port ne ""} {
            lappend cmd -p $port
        }
	list {*}$cmd {*}$prefix $host
    }
    method {windows sshcmd} {args} {
        set host [lindex $args end]
        set prefix [lreplace $args end end]
        set cmd [list plink]
        lassign [parse-host-port $host] host port
        if {$port ne ""} {
            lappend cmd -P $port
        }
	list {*}$cmd {*}$prefix $host
    }

    proc parse-host-port hostSpec {
        if {[regexp {^([^:]+):(\d+)$} $hostSpec -> host port]} {
            list $host $port
        } else {
            list $hostSpec
        }
    }
}

snit::method sshcomm::connection {rchan open} {cid fileName {access "r"}} {
    if {$access ne "r"} {
        error "Currently only access=r is supported"
    }
    
    $self rchan reader $cid [list apply {fileName {
        open $fileName
    }} $fileName]
}

snit::method sshcomm::connection {rchan reader} {cid script} {
    
    set remoteChan [::comm::comm send $cid $script]
    
    ::sshcomm::dlog 3 rchan reader remoteChan $remoteChan

    lassign [$self rchan socketpair] localSock remoteSock

    set chs [list $remoteChan $remoteSock]

    ::comm::comm send $cid [list apply {chs {
        lassign $chs fh sock
        chan close $sock read
        
        chan copy $fh $sock -command [list ::sshcomm::close-all $chs]

    }} $chs]

    return $localSock
}

snit::method sshcomm::connection {rchan socketpair} {} {

    set localSock [$self forward new raw]

    lassign [gets $localSock] _ remoteSock
    
    ::sshcomm::dlog 3 rchan socketpair received remoteSock $remoteSock

    list $localSock $remoteSock
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
    array set seen {}
    set result {}
    foreach ns [list $ns {*}$args] {
	if {[info exists seen($ns)]} continue
	set seen($ns) 1
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

	if {![cookie-del $cookie kind]} {
	    incr attackers($addr,$port)
	    close $sock
	    dputs " -> no such cookie, closed"
	    return
	}
	
        set cmdName ::sshcomm::remote::accept__$kind
	dputs accept handler $cmdName
        if {[info commands $cmdName] eq ""} {
            error "Can't find accept handler for kind $kind: $sock $addr $port"
        }
        $cmdName $sock $addr $port

	dputs connected
    } error]

    if {$rc && $rc != 2} {
	after idle [list apply [list {sock error ei} {
	    puts "ERROR(remote::accept): $error\n$ei"
	    close $sock
	}] $sock $error $::errorInfo]
    }
}

proc ::sshcomm::remote::accept__raw {sock addr port} {
    puts $sock [list raw $sock $addr $port]
    flush $sock
}

proc ::sshcomm::remote::accept__comm {sock addr port} {
    # new だけじゃ、 commCollect が set されない！
    # commNewConn を呼ぶ必要がある
    # それは commConnect か, commIncoming か、どちらかから呼ばれる
    ::comm::comm new $sock
    dputs "Now channels = $::comm::comm(chans)"
    ::comm::commIncoming ::$sock $sock $addr $port
}

proc ::sshcomm::remote::cookie-add {cookie {spec "comm"}} {
    variable authCookie
    set authCookie($cookie) [list $spec [clock seconds]]
    set spec
}

proc ::sshcomm::remote::cookie-del {cookie {specVar ""}} {
    if {$specVar ne ""} {
        upvar 1 $specVar spec
    }
    variable authCookie
    set vn authCookie($cookie)
    if {[info exists $vn]} {
        lassign [set $vn] spec
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

package provide sshcomm 0.4

