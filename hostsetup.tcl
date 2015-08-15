package require snit

snit::type host-setup {
    variable myRuleList [list]
    variable myRuleDict [dict create]
}

namespace eval ::host-setup {
    namespace import ::sshcomm::utils::*
    namespace export target
    
    set rule_template {
	namespace eval %TYPE% {
	    namespace import ::host-setup::*
	    namespace import ::sshcomm::utils::*
	}

	snit::type %TYPE% {
	    %BODY%
	}
    }

    proc rule {name body} {
	eval [__expand [set ::host-setup::rule_template] \
		  %TYPE% $name %BODY% $body]
    }
    proc __expand {template args} {
	string map $args $template
    }

    snit::macro target {target spec _ENSURE ensure _ACTION action} {
	
	uplevel 1 [list lappend %targets $target]

	method [list check $target] {} $ensure
	
	method [list ensure $target] {} \
	    [string map [list @COND@ $ensure @ACTION@ $action] {
		set rc [catch {@COND@} result]
		if {$rc} {
		    return [list error $rc]
		} elseif {$result} {
		    return met
		} else {
		    @ACTION@
		}
	    }]
    }
    
    foreach fn [glob [file dirname [info script]]/action/*.tcl] {
	source $fn
    }
}
