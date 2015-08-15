package require snit

source [file dirname [info script]]/utils.tcl

# snit::type host-setup {
#     variable myRuleList [list]
#     variable myRuleDict [dict create]
# }

namespace eval ::host-setup {
    namespace import ::sshcomm::utils::*
    namespace export target
    
    set rule_template {
	namespace eval %TYPE% {
	    namespace import ::host-setup::*
	    namespace import ::sshcomm::utils::*
	    namespace export *
	}

	snit::type %TYPE% {
	    set %_target {}

	    %UTILS%

	    %BODY%
	    
	    option -doc [list %DOC%]

	    method {list target} {} [list list {*}[set %_target]]
	    
	}
    }

    proc rule {name doc body} {
	set def [__EXPAND [set ::host-setup::rule_template] \
		     %TYPE% $name \
		     %BODY% $body \
		     %UTILS% [set ::host-setup::utils]\
		     %DOC% [list [string trim $doc]]\
		    ]
	set type [eval $def]
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
		error "Missing entry $key in dict value."
	    }
	}
	
	_proc __EXPAND {template args} {
	    string map $args $template
	}
    }
    

    snit::macro target {target spec} {
	
	set ensure [from spec ensure]
	set action [from spec action]
	set doc    [from spec doc ""]
	set req    [from spec require ""]
	
	if {$spec ne ""} {
	    error "Unknown target spec for $target! $spec"
	}
	
	uplevel 1 [list lappend %_target $target]

	method [list doc $target] {} [list return $doc]

	method [list check $target] {} $ensure
	
	method [list ensure $target] {} [__EXPAND {
	    set rc [catch {@COND@} result]
	    if {$rc} {
		return [list error $rc $result]
	    } elseif {$result} {
		return met
	    } else {
		@ACTION@
	    }
	} @COND@ $ensure @ACTION@ $action]
    }
    
    foreach fn [glob [file dirname [info script]]/action/*.tcl] {
	source $fn
    }
}
