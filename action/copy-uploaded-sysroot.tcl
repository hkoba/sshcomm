rule copy-uploaded-sysroot {
    -title "This copies /root/upload/sysroot/* to /"
    -prefix   ""
    -uploaded /root/upload/sysroot
    -sysroot  /
} {
    
    method uploaded-files {} {
	set result {}
	foreach fn [split [exec find $options(-uploaded) -type f -print0] \0] {
	    if {$fn eq ""} continue
	    set pure [string range $fn \
			  [expr {[string length $options(-uploaded)]+1}]\
			  end]
	    lappend result $pure
	}
	set result
    }

    method source-for fn {
	return $options(-uploaded)$options(-sysroot)$fn
    }
    
    method destination-for fn {
	return $options(-prefix)$options(-sysroot)$fn
    }

    target copied {
	check {
	    set rest [$self uploaded-files]
	    while {[llength $rest]} {
		set rest [lassign $rest fn]
		set dst [$self destination-for $fn]
		if {[file exists $dst]} continue
		$self dappend $fn [list dst $dst rest $rest]
		return 0
	    }
	    return 1
	}
	
	action {
	    foreach fn [$self uploaded-files] {
		set dst [$self destination-for $fn]
		set src [$self source-for $fn]
		if {[file exists $dst]} continue
		file copy -force $src $dst
	    }
	}
    }
}
