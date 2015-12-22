package require snit

source [file dirname [info script]]/utils.tcl

namespace eval ::host-setup {
    ::variable ourRuleList [list]
    ::variable ourRuleDict [dict create]
    ::variable ourSourceDict [dict create]

    ::sshcomm::register-plugin

    namespace import ::sshcomm::utils::*
    namespace export target
    
    set type_template {
	snit::type %TYPE% {
	    set %_target {}

	    %UTILS%

	    %OPTS%

	    method finalize {} {}; # empty default

	    %BODY%
	    
	    typemethod {list target} {} [list list {*}[set %_target]]
	    
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
		    if {![lindex [set all [$self ensure $tg]] 0]} {
			return [list NG $tg OK $succeed DEBUG $myDebugMsgs \
				    FAILURE [lrange $all 1 end]]
		    }
		    lappend succeed $tg
		}
		list OK $succeed NG {} DEBUG $myDebugMsgs
	    }
	}
    }

    proc rule-new {name args} {
	[find-type-of-rule $name] %AUTO% {*}$args
    }
    proc find-type-of-rule rule {
	dict get [find-rule $rule] nsname
    }
    proc find-rule rule {
	::variable ourRuleDict
	dict get $ourRuleDict $rule
    }

    proc list-targets-of-rule rule {
	[find-type-of-rule $rule] list target
    }

    proc list-rules {} {
	::variable ourRuleList
	set ourRuleList
    }

    proc build-opts {opts {outVar ""}} {
	if {$outVar ne ""} {
	    upvar 1 $outVar dict
	    set dict [dict create]
	}
	set result {}
	foreach {spec value} $opts {
	    set rest [lassign $spec name]
	    dict set dict $name [if {[llength $rest] <= 1} {
		dict create help [lindex $rest 0] default $value
	    } elseif {[llength $rest] % 2 != 0} {
		error "Invalid option spec($rest)"
	    } elseif {![dict exists $rest help]} {
		error "Option spec doesn't have \"help\" entry"
	    } else {
		if {[set subst [dict-default $rest subst ""]] ne ""} {
		    set value [subst $subst]
		}
		dict merge $rest [dict create default $value]
	    }]
	    append result [list option $name $value]\n
	}
	set result
    }

    proc rule {name opts body} {
	::variable ourRuleList
	::variable ourRuleDict

	set inFile [uplevel 1 [list info script]]
	if {$name eq "__FILE__"} {
	    set name [file rootname [file tail $inFile]]
	}

	if {[dict exists $ourRuleDict $name]} {
	    error "Redefinition of rule $name in $inFile. \n\
 (Previously in [dict get $ourRuleDict $name file])"
	}

	if {[set title [dict-cut opts -title ""]] eq ""} {
	    error "Option -title is required for $name in $inFile!"
	}

	namespace eval $name {
	    namespace import ::host-setup::*
	    namespace import ::sshcomm::utils::*
	    namespace export *
	}

	if {[set fn [dict-cut opts -import ""]] ne ""} {
	    import-into $name $fn
	}

	set def [__EXPAND [set ::host-setup::type_template] \
		     %TYPE% $name \
		     %BODY% $body \
		     %UTILS% [set ::host-setup::utils]\
		     %OPTS% [::host-setup::build-opts $opts optsInfo]
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
	    lappend ourRuleList $name
	    dict set ourRuleDict $name [dict create file $inFile nsname $res \
					   title $title options $optsInfo]
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
	    if {$rc ni [list 0 2]} {
		return [list no error $rc $result]
	    } elseif {[lindex $result 0]} {
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

    proc reset-rules {} {
	::variable ourRuleList [list]
	::variable ourRuleDict [dict create]
	::variable ourSourceDict [dict create]
    }

    proc import-into {target source {glob *}} {
	set ns [uplevel 1 [list source-once $source]]
	uplevel 1 [list namespace eval $target \
		       [list namespace import ${ns}::$glob]]
    }
    
    proc source-once source {
	::variable ourSourceDict
	if {[file pathtype [set sn $source]] ne "absolute"} {
	    set dir [file dirname [file normalize \
				       [uplevel 1 [list info script]]]]
	    set source [file normalize [file join $dir $source]]
	    # puts "Change source path $sn to $source"
	}
	set vn ourSourceDict($source)
	if {[info exists $vn]} {
	    set vn
	} else {
	    set vn [uplevel 1 [list source $source]]
	}
    }

    proc load-builtin-actions {} {
	::variable ourBuiltinActions
	load-actions $ourBuiltinActions
    }

    proc load-actions glob {
	foreach fn [glob -nocomplain $glob] {
	    source $fn
	}
    }

    ::variable ourBuiltinActions [file dirname [info script]]/action/*.tcl
}
