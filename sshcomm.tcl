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

    # EXPERIMENTAL: the plugin mechanism (register-plugin + `-plugins`
    # transfer to the remote) has had no real usage for ~10 years.
    # Kept but untested. See docs/improvement-notes.md (status: experimental).
    # NOTE: utils.tcl still registers here, but its utilities are used
    # directly by the core (askpass-helper); only the *plugin transfer* is dormant.
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

    # Classify one line received on the control channel. Pure function (no I/O),
    # so it is unit-testable from strings. Used by the Phase 3 demux reader.
    #   {reply $seq $rcode $result}  -- a remote eval reply
    #   {keepalive $pid $time}       -- a liveness ping
    #   {other $line}                -- anything else (logged, ignored)
    proc classify-control-line line {
        switch -- [lindex $line 0] {
            reply {
                lassign $line _ seq rcode result
                list reply $seq $rcode $result
            }
            keepalive {
                list keepalive [lindex $line 1] [lindex $line 2]
            }
            default {
                list other $line
            }
        }
    }

    proc value value {
        set value
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
    option -ssh-args ""
    option -ssh-verbose no
    option -autoconnect yes
    option -tclsh tclsh

    option -sudo no
    option -sudo-askpass-path "";    # external helper
    option -sudo-askpass-command ""; # tcl callback
    option -env-lang ""

    option -debug no
    option -remote-config {}
    option -plugins {};	# EXPERIMENTAL: plugin transfer to remote; ~10y unused, untested

    # "pipe"   : control runs over the SSH stdin/stdout pipe (original behavior).
    # "socket" : after connect, hand control off to a dedicated forwarded socket
    #            so the remote tclsh's stdout becomes free for the application.
    option -control-channel pipe

    variable mySSH ""; # SSH process pipe (stdin/stdout of the remote tclsh)
    variable myCtrlChan ""; # control I/O target: $mySSH (pipe), or a dedicated
			    # socket after the control-channel handoff (Phase 3).
    variable myCtrlMode pipe;	# pipe | socket | dead
    variable myCtrlPending "";	# partial control-socket message being accumulated
    variable myReply;	array set myReply {};	# seq -> {reply seq rcode result}
    variable myPending;	array set myPending {};	# seq -> 1 while a remote eval awaits it
    variable myLastKeepalive "";# clock seconds of the last keepalive (watchdog)
    constructor args {
	$self configurelist $args
        if {$options(-debug)} {
            set options(-ssh-verbose) yes
            lappend options(-remote-config) -verbose yes
            ::sshcomm::configure -debuglevel 3 -debugchan stderr
            if {[string is integer $options(-debug)]
                && $options(-debug) >= 3} {
                set ::comm::comm(debug) 1
            }
        }
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

	    set sshpids [pid $mySSH]
	    ::sshcomm::dlog 2 closing $mySSH pid $sshpids

	    if {$myCtrlMode eq "socket" && $myCtrlChan ne $mySSH} {
		# After the handoff the remote's stdin is detached, so "exit"
		# must go over the control socket (a "exit" on the pipe would
		# never be read). Deliver it blocking, then drop the socket.
		logged_safe_do 2 chan configure $myCtrlChan -blocking 1
		logged_safe_do 2 puts $myCtrlChan "exit"
		logged_safe_do 2 flush $myCtrlChan
		logged_safe_do 2 close $myCtrlChan
		# The remote tclsh now exits, but the ssh client can linger on
		# its forwarded channels, so a plain blocking [close $mySSH]
		# would wait forever. Reap the ssh child explicitly. (Unix only;
		# socket mode is a unix feature. SIGTERM, then close.)
		logged_safe_do 2 exec kill {*}$sshpids
	    } else {
		logged_safe_do 2 puts $myCtrlChan "exit"
		logged_safe_do 2 flush $myCtrlChan
	    }

            set rc [catch {
                close $mySSH
            } msg]
            ::sshcomm::dlog 2 closed $mySSH rc $rc msg $msg
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
	
	set cmd [$self sshcmd {*}[$self forwarder] \
                     {*}$options(-ssh-args) \
                     {*}$host]
        if {$options(-ssh-verbose) && $options(-sshcmd-platform) eq ""} {
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
	# Until the optional control-channel handoff (Phase 3), all control I/O
	# (remote eval/lread/puts) runs over the SSH pipe.
	set myCtrlChan $mySSH

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
	if {$myCtrlMode eq "dead"} {
	    error "control channel is dead: $options(-host)"
	}
	set seq [incr myEvalCnt]
	::sshcomm::dlog 2 remote eval $seq [if {[string length $command] >= 200} {
            value [string range $command 0 200]...
        } else {
            set command
        }]

	# The reply is tagged "reply" and sent to the remote's control-output
	# channel ($::sshcomm::remote::ctrlOut). During the early handshake that
	# namespace does not exist yet, so fall back to stdout. After the Phase 3
	# handoff ctrlOut is the control socket; in pipe mode it stays stdout.
	puts $myCtrlChan [list apply [list {seq command} {
	    set rc [catch $command res]
	    set ch [expr {[info exists ::sshcomm::remote::ctrlOut]
			  ? $::sshcomm::remote::ctrlOut : "stdout"}]
	    puts $ch [list reply $seq $rc $res]
	    flush $ch
	}] $seq  $command]
        flush $myCtrlChan

	# In socket mode the reply is delivered asynchronously by the demux
	# reader ([control-readable]) keyed by $seq; otherwise read it back
	# synchronously from the pipe.
	set reply [if {$myCtrlMode eq "socket"} {
	    $self ctrl-await $seq
	} else {
	    $self remote lread
	}]
	if {[lindex $reply 0] ne "reply"} {
	    error "Remote Eval expected reply tag, got: $reply"
	}
	::sshcomm::dlog 2 remote eval GOT: $reply
	lassign $reply _tag rseq rcode result
	if {$rseq != $seq} {
	    error "Remote Eval seqno mismatch! $reply"
	}
	if {$rcode in {0 2}} {
	    return $result
	} else {
	    return -code $rcode $result
	}
    }

    # Wait (via the event loop) for the demux to deliver seq's reply, or for a
    # teardown sentinel set by [ctrl-lost]. Per-seq array element so concurrent
    # / out-of-order replies are safe (the pattern comm itself uses).
    method ctrl-await seq {
	set myPending($seq) 1
	if {![info exists myReply($seq)]} {
	    vwait [myvar myReply]($seq)
	}
	unset -nocomplain myPending($seq)
	set reply $myReply($seq)
	unset myReply($seq)
	set reply
    }

    # Demux reader for the control socket. Accumulates complete (possibly
    # multi-line) messages, classifies them, and routes replies to their seq.
    method control-readable sock {
	while {[gets $sock line] >= 0} {
	    append myCtrlPending $line \n
	    if {![info complete $myCtrlPending]} continue
	    set msg [string trimright $myCtrlPending \n]
	    set myCtrlPending ""
	    lassign [::sshcomm::classify-control-line $msg] kind a b c
	    switch -- $kind {
		reply { set myReply($a) [list reply $a $b $c] }
		keepalive {
		    set myLastKeepalive [clock seconds]
		    ::sshcomm::dlog 4 keepalive from $options(-host) $a $b
		}
		default { ::sshcomm::dlog 4 control other $options(-host) $a }
	    }
	}
	if {[eof $sock]} {
	    $self ctrl-lost "control socket eof"
	}
    }

    # The control channel died: stop reading and fail every pending remote eval
    # with an error so its vwait unwinds instead of hanging forever.
    method ctrl-lost reason {
	if {$myCtrlMode eq "dead"} return
	::sshcomm::dlog 1 control lost $options(-host) $reason
	set myCtrlMode dead
	catch {fileevent $myCtrlChan readable {}}
	foreach seq [array names myPending] {
	    if {![info exists myReply($seq)]} {
		set myReply($seq) [list reply $seq 1 "control channel lost: $reason"]
	    }
	}
    }

    method {remote lread} {} {
	set reply ""
	while {[gets $myCtrlChan line] >= 0} {
	    append reply $line
	    if {[info complete $reply]} break
	}
        set reply
    }

    method {remote puts} text {
	::sshcomm::dlog 3 remote puts [if {[string length $text] >= 200} {
            value [string range $text 0 200]...
        } else {
            set text
        }]
	puts $myCtrlChan $text
	flush $myCtrlChan
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
        if {[set rc [$self remote eval {list ok}]] ne "ok"} {
            error "Remote eval does not return 'ok': rc=$rc"
        }
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
        $self remote puts {
	    fconfigure stdout -buffering line
	    fconfigure stderr -buffering line
	}
	$self remote redefine
        $self remote puts [list ::sshcomm::remote::setup $options(-rport) \
                               {*}$options(-remote-config) {*}$args]
        set line [$self remote lread]
        ::sshcomm::dlog 3 remote::setup result $line
	# XXX: Should record remote pid
	if {$line ne "OK port $options(-rport)"} {
	    error "Unknown result: $line"
	}
	if {$options(-control-channel) eq "socket"} {
	    # Hand control off to a dedicated socket while the pipe is still
	    # quiet (no async handler yet, first keepalive is 30s away), then let
	    # the pipe carry the remote tclsh's stdout for the application.
	    $self control-handoff
	    fileevent $mySSH readable [list $self remote app-output]
	} else {
	    fileevent $mySSH readable [list $self remote readable]
	}
	update idletask
        ::sshcomm::dlog 3 remote::setup success
	set mySSH
    }

    # Move the control channel from the SSH pipe onto a dedicated, cookie-
    # authenticated forwarded socket. Runs while still in pipe mode, so the
    # cookie-add round-trip inside [forward new] uses the (quiet) pipe.
    method control-handoff {} {
	set sock [$self forward new control]
	# Read the confirmation line synchronously: nothing else is on this
	# socket yet (cf. [rchan socketpair] reading accept__raw's line).
	set line [gets $sock]
	if {[lindex $line 0] ne "control" || [lindex $line 1] ne "ready"} {
	    catch {close $sock}
	    error "control-channel handoff failed, got: $line"
	}
	::sshcomm::dlog 2 control handoff ok $options(-host) remote-pid [lindex $line 2]
	fconfigure $sock -blocking 0 -buffering line -translation lf -encoding utf-8
	set myCtrlChan $sock
	set myCtrlMode socket
	fileevent $sock readable [list $self control-readable $sock]
	set sock
    }

    # In socket mode the SSH pipe carries the remote tclsh's stdout. Drain it
    # (so it never blocks) and detect ssh death. The per-line app callback is
    # added in Phase 4; for now lines are just logged.
    method {remote app-output} {} {
	if {[gets $mySSH line] >= 0} {
	    ::sshcomm::dlog 4 app-output $options(-host) $line
	}
	if {[eof $mySSH]} {
	    ::sshcomm::dlog 2 app-output eof $options(-host)
	    $self ctrl-lost "ssh pipe eof"
	}
    }

    method {forward new} spec {
	set cookie [clock seconds].[expr {int(100000000 * rand())}]

	# [1] Register cookie via established ssh channel
        $self remote eval [list ::sshcomm::remote::cookie-add $cookie $spec]

	# [2] Open forwarding socket
	set sock [socket $options(-localhost) $options(-lport)]
	::sshcomm::dlog 3 new forward localSock $sock opened for $options(-host)

	# [3] Send the cookie. Without it, remote will reject connection.
        ::sshcomm::dlog 3 emit cookie $cookie
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
	set cmd [$self sshcmd {*}$host]
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
            set platform [if {$options(-sshcmd-platform) ne ""} {
                set options(-sshcmd-platform)
            } else {
                set ::tcl_platform(platform)
            }]
	    $self $platform sshcmd {*}$args
	}]
        ::sshcomm::dlog 3 sshcmd $sshcmd
        set sshcmd
    }
    option -sshcmd-platform ""
    option -sshcmd-platform-options "";	# EXPERIMENTAL: mainly for [gcloud sshcmd]; rarely used, untested
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

    # EXPERIMENTAL: [gcloud sshcmd] is rarely used and intentionally has no
    # test coverage. See docs/improvement-notes.md (status: experimental).
    method {gcloud sshcmd} args {
        # puts [list args: $args]
        set host [lindex $args end]
        set forwarder [lreplace $args end end]
        # puts [list -> host: $host prefix: $prefix]

        set vn ::env(GIT_SSH)
        set cmd [if {$options(-prefer-git-ssh) && [info exists $vn]} {
            list [set $vn]
        } else {
            list gcloud compute ssh {*}$options(-sshcmd-platform-options)
        }]

        if {$forwarder ne ""} {
            lappend cmd --ssh-flag=[join $forwarder]
        }

        lappend opts {*}$options(-ssh-options)
        lappend opts -o \
            StrictHostKeyChecking=$options(-strict-host-key-checking)\
            -T
        if {$options(-forwardx11)
            && [info exists ::env(DISPLAY)]
            && $::env(DISPLAY) ne ""} {
            lappend opts -X
        } else {
            lappend opts -x
        }
        lassign [parse-host-port $host] host port
        if {$port ne ""} {
            lappend opts -p $port
        }
        list {*}$cmd $host -- {*}$opts
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

    ::variable myCommandLine {}

    variable cookieReader; array set cookieReader {}

    # Where control-channel output (remote eval replies, keepalive) is written.
    # Defaults to stdout (the SSH pipe); rebound to the control socket by
    # [accept__control] after the Phase 3 handoff.
    variable ctrlOut stdout
}

proc ::sshcomm::remote::x args {
    dputs "remote-server: $args"
    uplevel 1 $args
}
proc ::sshcomm::remote::setup {port args} {
    variable config; array set config $args

    x package require comm
    x comm::comm destroy

#    interp bgerror {} [list apply {{msg dict} {
#	puts "ERROR($msg) $dict"
#	exit
#    }}]

    variable myServerSock [x socket -server [namespace current]::accept $port]

    x after 30000 [list [namespace current]::keepalive 30000]
    x fileevent stdin readable [list [namespace current]::control stdin]
    x puts [list OK port $port]

    # ↓Required to avoid reading from stdin
    x vwait [namespace current]::forever
}

proc ::sshcomm::remote::accept {sock addr port} {
    dputs "connected from $addr:$port"
    variable attackers
    if {! ($addr in {0.0.0.0 127.0.0.1})} {
	incr attackers($addr)
	close $sock
	dputs " -> closed"
	return
    }
    # Read the cookie without blocking the event loop, with a length cap and a
    # timeout: a hostile (but local) peer must not stall the server nor send an
    # unbounded line. Dispatch continues in [accept-cookie].
    read-cookie $sock [list [namespace current]::accept-cookie $sock $addr $port]
}

proc ::sshcomm::remote::accept-cookie {sock addr port status cookie} {
    variable attackers
    set rc [catch {
	if {$status ne "ok"} {
	    incr attackers($addr,$port)
	    close $sock
	    dputs " -> cookie read $status, closed"
	    return
	}
	dputs " -> got cookie: $cookie"

	if {![cookie-del $cookie kind]} {
	    incr attackers($addr,$port)
	    close $sock
	    dputs " -> no such cookie, closed"
	    return
	}

	# Hand a plain blocking socket to the kind handler, as before
	# (read-cookie left it non-blocking).
	fconfigure $sock -blocking 1

        set cmdName ::sshcomm::remote::accept__$kind
	dputs accept handler $cmdName
        if {[info commands $cmdName] eq ""} {
            error "Can't find accept handler for kind $kind: $sock $addr $port"
        }
        $cmdName $sock $addr $port

	dputs connected
    } error]

    if {$rc && $rc != 2} {
        dputs $error
	after idle [list apply [list {sock error ei} {
	    puts "ERROR(remote::accept): $error\n$ei"
	    close $sock
	}] $sock $error $::errorInfo]
    }
}

# Read one newline-terminated cookie line from $sock without blocking the event
# loop, capped at $maxlen bytes and giving up after $timeout ms. Eventually
# calls: {*}$doneCmd <status> <cookie>   status: ok | overflow | timeout | eof
# (a complete line at eof without trailing newline still reports "ok", matching
#  the original blocking [gets]; a truly empty close reports "eof").
proc ::sshcomm::remote::read-cookie {sock doneCmd {maxlen 4096} {timeout 10000}} {
    variable cookieReader
    fconfigure $sock -blocking 0 -buffering line -translation auto
    set cookieReader($sock,done) $doneCmd
    set cookieReader($sock,timer) [after $timeout \
        [list [namespace current]::read-cookie-finish $sock timeout]]
    fileevent $sock readable [list [namespace current]::read-cookie-step $sock $maxlen]
}

proc ::sshcomm::remote::read-cookie-step {sock maxlen} {
    set n [gets $sock line]
    if {$n >= 0} {
	read-cookie-finish $sock ok [string trimright $line \r]
    } elseif {[eof $sock]} {
	read-cookie-finish $sock eof
    } elseif {[chan pending input $sock] > $maxlen} {
	read-cookie-finish $sock overflow
    }
}

proc ::sshcomm::remote::read-cookie-finish {sock status {cookie ""}} {
    variable cookieReader
    if {![info exists cookieReader($sock,done)]} return
    after cancel $cookieReader($sock,timer)
    catch {fileevent $sock readable {}}
    set doneCmd $cookieReader($sock,done)
    array unset cookieReader $sock,*
    uplevel #0 [list {*}$doneCmd $status $cookie]
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

# Promote this socket to *the* control channel (the Phase 3 handoff): control
# commands now arrive here instead of stdin, and control output (remote eval
# replies + keepalive) is redirected here from stdout. stdin is released so the
# remote tclsh's stdin/stdout become free for the application.
proc ::sshcomm::remote::accept__control {sock addr port} {
    variable ctrlOut
    fconfigure $sock -blocking 0 -buffering line -translation lf -encoding utf-8
    set ctrlOut $sock
    fileevent stdin readable {}
    fileevent $sock readable [list [namespace current]::control $sock]
    # Confirmation line the local side reads (blocking) to know the handoff took.
    puts $sock [list control ready [pid]]
    flush $sock
    dputs "control channel handoff: stdin released, ctrlOut=$sock"
}

proc ::sshcomm::remote::cookie-add {cookie {spec "comm"}} {
    variable authCookie
    x set authCookie($cookie) [list $spec [clock seconds]]
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
    puts stderr [join $args]
}

proc ::sshcomm::remote::keepalive msec {
    variable ctrlOut
    puts $ctrlOut [list keepalive [pid] [clock seconds]]
    flush $ctrlOut
    after $msec [list [namespace current]::keepalive $msec]
}

proc ::sshcomm::remote::control {fh args} {
    variable myCommandLine

    set count [gets $fh line]
    if {$count < 0} {
	# On a non-blocking socket (the control channel), gets returns -1 both
	# for a partial line (still buffering) and for real eof. Only exit on
	# real eof; a partial line just waits for the next readable event.
	if {[eof $fh]} {
	    close $fh
	    exit
	}
	return
    }
    if {$count == 0} return
    dputs "control got line: $line"

    append myCommandLine $line\n

    if {$myCommandLine ne "" && [info complete $myCommandLine]} {
        set cmd $myCommandLine
        set myCommandLine {}
        dputs "control eval command: $cmd"
	set rc [catch [list uplevel \#0 $cmd] error]
	if {$rc} {
	    puts stderr "ERROR($error) $::errorInfo"
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

