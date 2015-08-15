package require snit

source [file dirname [info script]]/utils.tcl

# snit::type host-setup {
#     variable myRuleList [list]
#     variable myRuleDict [dict create]
# }

namespace eval ::host-setup {
    ::sshcomm::register-plugin

    namespace import ::sshcomm::utils::*
    namespace export target
    
    set type_template {
	snit::type %TYPE% {
	    set %_target {}

	    %UTILS%

	    method finalize {} {}; # empty default

	    %BODY%
	    
	    option -doc [list %DOC%]

	    option -debug 0
	    variable myDebugMsgs ""
	    method dappend {value {msg ""}} {
		lappend myDebugMsgs [list $value $msg]
		set value
	    }

	    method {debug clear} {} {set myDebugMsgs ""}

	    method {debug show} {} {
		set myDebugMsgs
	    }

	    method {list target} {} [list list {*}[set %_target]]
	    
	    method check-all {} {
		set succeed {}
		foreach tg [$self list target] {
		    if {![$self check $tg]} {
			return [list NG $tg OK $succeed DEBUG $myDebugMsgs]
		    }
		    lappend succeed $tg
		}
		list OK $succeed NG {} DEBUG $myDebugMsgs
	    }
	    
	    method apply-all {} {
		set succeed {}
		foreach tg [$self list target] {
		    if {![$self ensure $tg]} {
			return [list NG $tg OK $succeed DEBUG $myDebugMsgs]
		    }
		    lappend succeed $tg
		}
		list OK $succeed NG {} DEBUG $myDebugMsgs
	    }
	}
    }

    proc rule {name doc body} {
	namespace eval $name {
	    namespace import ::host-setup::*
	    namespace import ::sshcomm::utils::*
	    namespace export *
	}

	set def [__EXPAND [set ::host-setup::type_template] \
		     %TYPE% $name \
		     %BODY% $body \
		     %UTILS% [set ::host-setup::utils]\
		     %DOC% [list [string trim $doc]]\
		    ]
	if {[catch $def res]} {
	    set vn ::env(DEBUG_HOSTSETUP)
	    if {[info exists $vn] && [set $vn]} {
		lassign $def snit name body
		error [list compile-error $res \
			   {*}[snit::compile type $name $body]]
	    } else {
		error "compile-error $res"
	    }
	} else {
	    set res
	}
    }

    proc __EXPAND {template args} {
	string map $args $template
    }
    
    set utils {
	# Procs used in snit::macro must be defined by [_proc], not [proc]
	_proc from {dictVar key args} {
	    upvar 1 $dictVar dict
	    if {[dict exists $dict $key]} {
		set result [dict get $dict $key]
		dict unset dict $key
		set result
	    } elseif {[llength $args]} {
		lindex $args 0
	    } else {
		error "Missing entry '$key' in dict value."
	    }
	}
	
	_proc __EXPAND {template args} {
	    string map $args $template
	}
    }
    

    snit::macro target {target spec} {
	
	set ensure [from spec ensure ""]
	set check  [from spec check ""]
	if {$ensure eq "" && $check eq ""} {
	    error "ensure (or check) is required!"
	} elseif {$ensure eq ""} {
	    set ensure $check
	}
	set action [from spec action]
	set doc    [from spec doc ""]
	set req    [from spec require ""]
	
	if {$spec ne ""} {
	    error "Unknown target spec for $target! $spec"
	}
	
	set targName [join $target _]
	set arglist [list [list target $target] \
			 [list _target $targName]]

	uplevel 1 [list lappend %_target $targName]

	method [list doc $targName] {} [list return $doc]

	method [list check $targName] $arglist $ensure
	
	method [list ensure $targName] $arglist [__EXPAND {
	    set rc [catch {@COND@} result]
	    if {$rc} {
		return [list error $rc $result]
	    } elseif {$result} {
		return yes
	    } else {
		@ACTION@
		$self check [join $target _]
	    }
	} @COND@ $ensure @ACTION@ $action]
    }
    
    snit::macro finally body {
	method finalize {} $body
    }

    foreach fn [glob [file dirname [info script]]/action/*.tcl] {
	source $fn
    }
}
