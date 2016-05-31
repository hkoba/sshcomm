# -*- coding: utf-8 -*-

rule etc-git {
    -title "This rule ensures /etc to be managed with git."
    -prefix ""
    -etc /etc

    {-user
	help "This will used as git config user.name (in remote)"
	subst {[exec git config user.name]}
    } ""
    {-email
	help "This will used as git config user.email (in remote)"
	subst {[exec git config user.email]}
    } ""

    -commit-msg auto

    {-gitignore
	help "Initial .gitignore"
	type textarea
    } "
/mtab
/lvm
/blkid
/adjtime
/*-
/*.cache
/*.db
*~
*.lock
*.bak
*.OLD
*.old
*.O
*rpmorig
*rpmnew
"
} {
    
    
    target gitignore {
	doc "This adds proper /etc/.gitignore"

	ensure {
	    file exists [set fn $options(-prefix)$options(-etc)/.gitignore]
	}

	action {
	    write_file $fn $options(-gitignore)
	}
    }

    target git-init {
	doc "This inits /etc/.git"

	require "gitignore"

	ensure {
	    # XXX: Should check permissions too.
	    file exists [set fn $options(-prefix)$options(-etc)]/.git
	}
	
	action {
	    exec git init --shared=0600 $fn
	}
    }
    
    target git-config {
	doc "This ensures git config user.name and user.email"
	
	require "git-init"

	ensure {
	    set cwd [pwd]
	    cd $options(-prefix)$options(-etc)
	    scope_guard cwd [list cd $cwd]

	    foreach {key cf} {
		name -user
		email -email
	    } {
		if {[catch {exec git config user.$key} res]} {
		    return [list 0 [list git config user.$key] ERROR: $res]
		} elseif {$res ne $options($cf)} {
		    return [list 0 [list Not matched: user.$key] \
				want $options($cf) got: $res]
		}
	    }
	    list 1
	}
	
	action {
	    exec git config user.name $options(-user)
	    exec git config user.email $options(-email)
	}
    }

    target commit-all {
	doc "This commits all unsaved changes"
	
	require "git-config"

	ensure {
	    set cwd [pwd]
	    cd $options(-prefix)$options(-etc)
	    scope_guard cwd [list cd $cwd]

	    if {[set status [exec git status -su]] eq ""} {
		list 1
	    } else {
		list 0 $status
	    }
	}
	
	action {
	    exec git add -A
	    exec git commit -m $options(-commit-msg)
	}
    }
}
