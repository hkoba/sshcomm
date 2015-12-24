rule copy-uploaded-sysroot {
    -title "This copies /root/upload/sysroot/* to /"
    -prefix   ""
    -uploaded /root/upload/sysroot
    -sysroot  /
} {
    
    # option -rsync    /usr/bin/rsync

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
	    if {![file exists $options(-uploaded)]} {
		return [list 0 "Not found: $options(-uploaded)"]
	    }
	    # if {![file executable $options(-rsync)]} {
	    # 	return [list 0 "Not executable: $options(-rsync)"]
	    # }
	    set diffs {}
	    foreach fn [$self uploaded-files] {
		set dst [$self destination-for $fn]
		set src [$self source-for $fn]
		if {[file exists $dst]
		    && [file mtime $dst] == [file mtime $src]
		    && [file size $dst] == [file size $src]
		    && [read_file $dst] eq [read_file $src]
		} continue
		lappend diffs $fn
	    }
	    list [expr {$diffs eq ""}] diffs: $diffs
	}
	
	action {
	    foreach fn $diffs {
		set dst [$self destination-for $fn]
		set src [$self source-for $fn]
		set dst_dir [file dirname $dst]
		if {![file exists $dst_dir]} {
		    file mkdir $dst_dir
		    file attributes $dst_dir \
			{*}[file attributes [file dirname $src]]
		}
		file copy -force $src $dst
		file mtime $dst [file mtime $src]
	    }
	}
    }
    
    foreach {perm dir} {
	040700  /root
	040700  /etc/pki/tls/private
	040750  /etc/sudoers.d
    } {
	target [list $perm $dir] {
	    check {
		lassign $target perm dir
		if {![file exists $dir]} {
		    return [list 0 missing: $dir]
		}
		set atts [list -group root -owner root -permissions $perm]
		set diff [dict-left-difference [file attributes $dir] \
			      $atts]
		list [expr {$diff eq ""}] $diff
	    }
	    action {
		file attributes $dir {*}$atts
	    }
	}
    }
}
