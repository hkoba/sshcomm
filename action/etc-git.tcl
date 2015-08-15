# -*- coding: utf-8 -*-

rule etc-git {
    
    option -prefix ""
    option -etc /etc
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
    } ensure {
	file exists [set fn $options(-prefix)$options(-etc)/.gitignore]
    } action {
	write_file $fn $options(-gitignore)
    }

    target git-init {
	doc "This inits /etc/.git"
    } ensure {
	file exists [set fn $options(-prefix)$options(-etc)]/.git
    } action {
	exec git init --shared=0600 $fn
    }

}

