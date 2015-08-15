# -*- coding: utf-8 -*-

rule etc-git "\
This rule ensures /etc to be managed with git.
" {
    
    option -prefix ""
    option -etc /etc

    option -user ""
    option -email ""

    option -commit-msg auto

    option -gitignore "
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
	    cd $options(-prefix)$options(-etc)
	    expr {[catch-exec git config user.name] eq $options(-user)
		  && [catch-exec git config user.email] eq $options(-email)}
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
	    cd $options(-prefix)$options(-etc)
	    expr {[exec git status -su] eq ""}
	}
	
	action {
	    exec git add -A
	    exec git commit -m $options(-commit-msg)
	}
    }
}