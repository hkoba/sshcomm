# -*- coding: utf-8 -*-

rule sshd_config "\
This disables password logins for sshd
" {
    
    option -prefix ""
    option -file   /etc/ssh/sshd_config

    variable myConfigData ""
    
    constructor args {
	$self configurelist $args
	$self read
    }
    
    method restart {} {
	if {[catch-exec-noerror which systemctl]} {
	    exec systemctl restart sshd
	} elseif {[catch-exec-noerror which service]} {
	    exec service sshd restart
	} else {
	    error "Can't find systemctl/service"
	}
    }

    method write {} {
	set bak [set fn $options(-prefix)$options(-file)].bak
	write_file $bak $myConfigData
	file rename -force $bak $fn
    }

    method read {} {
	set myConfigData [read_file $options(-prefix)$options(-file)]
	if {[string index $myConfigData end] ne "\n"} {
	    append myConfigData \n
	}
    }

    method test {name value} {
	set re [$self regexp-for $name]
	if {[llength [set ls [regexp -inline {*}$re $myConfigData]]] >= 2} {
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
	append myConfigData $target\n
    }
    
    method {do REPLACE} target {
	set re [$self regexp-for [lindex $target 0]]
	if {![regsub {*}$re $myConfigData $target myConfigData]} {
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
    
    finally {
	$self write
	$self restart
    }
}
