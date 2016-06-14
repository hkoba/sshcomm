# -*- coding: utf-8 -*-

rule sshd_config {
    -title  "This disables password logins for sshd"
    -prefix ""
    -file   /etc/ssh/sshd_config
} {
    

    variable stateConfigData ""
    
    initially {
	$self read
    }

    finally {
	$self write
	$self restart
    }

    method restart {} {
	if {[set fn [auto_execok systemctl]] ne ""} {
	    exec $fn restart sshd
	} elseif {[set fn [auto_execok service]] ne ""} {
	    exec $fn sshd restart
	} else {
	    error "Can't find systemctl/service"
	}
    }

    method data {} {
	set stateConfigData
    }

    method write {} {
	set bak [set fn $options(-prefix)$options(-file)].bak
	write_file $bak $stateConfigData
	file rename -force $bak $fn
    }

    method read {} {
	set stateConfigData [read_file $options(-prefix)$options(-file)]
	if {[string index $stateConfigData end] ne "\n"} {
	    append stateConfigData \n
	}
    }

    method test {name value} {
	set re [$self regexp-for $name]
	if {[llength [set ls [regexp -inline {*}$re $stateConfigData]]] >= 2} {
	    error "Too many config: $ls"
	} elseif {[llength $ls] == 0} {
	    list APPEND
	} elseif {[lindex $ls 0 1] ne $value} {
	    list REPLACE
	} else {
	    list OK
	}
    }

    #----------------------------------------
    method regexp-for config {
	set re [string map [list @KW@ $config] {^@KW@\s+(?:\S[^\n]*)}]
	list -all -nocase -line $re
    }

    method {do APPEND} target {
	append stateConfigData $target\n
    }
    
    method {do REPLACE} target {
	set re [$self regexp-for [lindex $target 0]]
	if {![regsub {*}$re $stateConfigData $target stateConfigData]} {
	    error "Can't replace $target"
	}
    }
    
    method {do OK} target {}


    #========================================

    proc is {x y} {string equal $x $y}

    set template {
	check {
	    is OK [set action [$self test {*}$target]]
	}
	
	action {
	    $self do $action $target
	}
    }

    target {PasswordAuthentication no} $template

    target {ChallengeResponseAuthentication no} $template
    
    target {PermitEmptyPasswords no} $template

    target {PermitRootLogin yes} $template
    
}
