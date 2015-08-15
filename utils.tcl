# -*- mode: tcl; tab-width: 8; coding: utf-8 -*-

namespace eval ::sshcomm {}
namespace eval ::sshcomm::utils {

    ::sshcomm::register-plugin

    proc lines-of args {
	split [uplevel 1 $args] \n
    }

    proc default {varName {default ""}} {
	upvar 1 $varName var
	if {[info exists var]} {
	    set var
	} else {
	    set default
	}
    }

    proc dict-default {dict key {default ""}} {
	if {[dict exists $dict $key]} {
	    dict get $dict $key
	} else {
	    set default
	}
    }

    proc dict-cut {dictVar key args} {
	upvar 1 $dictVar dict
	if {[dict exists $dict $key]} {
	    set res [dict get $dict $key]
	    dict unset dict $key
	    set res
	} elseif {[llength $args]} {
	    lindex $args 0
	} else {
	    error "No such key: $key"
	}
	
    }

    proc lgrep {pattern list {cmdOrArgs ""} {apply ""}} {
	    set res {}
	if {$cmdOrArgs eq "" && $apply eq ""} {
	    foreach i $list {
		if {![regexp $pattern $i]} continue
		lappend res $i
	    }
	} else {
	    set cmd [if {$apply ne ""} {
		list apply [list $cmdOrArgs $apply]
	    } else {
		list $cmdOrArgs
	    }]
	    foreach i $list {
		if {![llength [set m [regexp -inline $pattern $i]]]} continue
		lappend res [{*}$cmd {*}$m]
	    }
	}
	set res
    }

    proc file-has {pattern fn args} {
	llength [filelist-having $pattern $fn {*}$args]
    }

    proc filelist-having {pattern fn args} {
	set found {}
	foreach fn [linsert $args 0 $fn] {
	    set fh [open $fn]
	    scope_guard fh [list close $fh]
	    for-chan-line line $fh {
		if {![regexp $pattern $line]} continue
		lappend found $fn
		break
	    }
	    unset fh
	}
	set found
    }

    proc for-chan-line {lineVar chan command} {
	upvar $lineVar line
	while {[gets $chan line] >= 0} {
	    uplevel 1 $command
	}
    }

    proc read_file {fn args} {
	set fh [open $fn]
	scope_guard fh [list close $fh]
	if {[llength $args]} {
	    fconfigure $fh {*}$args
	}
	read $fh
    }

    proc shell-quote-string string {
	# XXX: Is this enough for /bin/sh's "...string..." quoting?
	# $
	# backslash
	# `
	# "
	# !
	regsub -all {[$\\`\"!]} $string {\\&}
    }

    proc text-of-list-of-list {ll {sep " "} {eos "\n"}} {
	set list {}
	foreach i $ll {
	    lappend list [join $i $sep]
	}
	return [join $list \n]$eos
    }

    proc append_file {fn data args} {
	write_file $fn $data {*}$args -access a
    }

    proc write_file {fn data args} {
	set data [string trim $data]
	regsub {\n*\Z} $data \n data
	write_file_raw $fn $data {*}$args
    }

    proc write_file_raw {fn data args} {
	set access [dict-cut args -access w]
	if {![regexp {^[wa]} $access]} {
	    error "Invalid access flag to write_file $fn: $access"
	}
	set attlist {}
	set rest {}
	if {[set perm [dict-cut args -permissions ""]] ne ""} {
	    if {[string is integer $perm]} {
		lappend rest $perm
	    } else {
		lappend attlist -permissions $perm
	    }
	}
	foreach att [list -group -owner] {
	    if {[set val [dict-cut args $att ""]] ne ""} {
		lappend attlist $att $val
	    }
	}
	set fh [open $fn $access {*}$rest]
	if {$attlist ne ""} {
	    file attributes $fn {*}$attlist
	}
	scope_guard fh [list close $fh]
	if {[llength $args]} {
	    fconfigure $fh {*}$args
	}
	puts -nonewline $fh $data
	set fn
    }

    proc scope_guard {varName command} {
	upvar 1 $varName var
	uplevel 1 [list trace add variable $varName unset \
		       [list apply [list args $command]]]
    }
    
    proc catch-exec args {
	set rc [catch [list exec {*}$args] result]
	set result
    }
}

# More specific commands
namespace eval ::sshcomm::utils {
    # To use this, you must disable "requiretty" by visudo.
    proc create-echopass {password {setenv SUDO_ASKPASS}} {
	set uid [exec id -u]
	set rand [format %x [expr {int(rand() * 1000000)}]]
	set path /run/user/$uid/echopass-[pid]-$rand.sh
	write_file $path [join [list #![info nameofexecutable] \
				    [list puts $password]] \n] \
	    -permissions 0700
	if {$setenv ne ""} {
	    set ::env($setenv) $path
	}
	set path
    }
}

namespace eval ::sshcomm::utils {
    namespace export *
}
