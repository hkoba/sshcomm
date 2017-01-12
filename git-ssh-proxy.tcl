#!/bin/sh
# -*- mode: tcl; coding: utf-8 -*-
# the next line restarts using tclsh \
exec tclsh -encoding utf-8 "$0" ${1+"$@"}

package require snit

namespace eval ::sshcomm {}
namespace eval ::sshcomm::git-ssh-proxy {
    if {[info commands ::sshcomm::register-plugin] ne ""} {
        ::sshcomm::register-plugin
    }
}

snit::type ::sshcomm::git-ssh-proxy {
    
    option -host ""

    option -tempdir ""
    option -ctrlfmt ssh-%h.%p
    
    option -autoconnect no
    
    constructor args {
        $self configurelist $args
        if {$options(-autoconnect)} {
            $self connect
        }
    }

    method scriptFn {} {
        if {$options(-tempdir) eq ""} {
            set options(-tempdir) [if {[file isdirectory /run/user] &&
                [file isdirectory [set dir /run/user/[exec id -u]]]} {
                set dir
            } elseif {[file isdirectory ~/.ssh]} {
                set dir ~/.ssh/tmp
                if {![file exists $dir]} {file mkdir $dir}
                set dir
            } else {
                error "Can't determine tempdir"
            }]
        }
        if {![file exists $options(-tempdir)]} {
            error "Invalid tempdir: $options(-tempdir)"
        }
        return $options(-tempdir)/git-ssh-$options(-host)
    }

    method ctrl {} {
        return [$self ctrlDir]/$options(-ctrlfmt)
    }

    method ctrlDir {} {
        return [$self scriptFn].d
    }

    method generate {} {
        set script [regsub -all ^\n|\n\$ $ourScriptTemplate {}]
        string map [list \
                        @ORIG_HOST@ $options(-host) \
                        @SSH_CTRL@  [$self ctrl]] $script
    }
    
    destructor {
        if {$mySSH ne ""} {
            close $mySSH
            set mySSH ""
        }
    }

    variable mySSH
    method connect {} {
        set fn [$self rebuild]
        set mySSH [open [list | ssh -A -M -o ControlPath=[$self ctrl] \
                             $options(-host) /bin/sh]]
        set ::env(GIT_SSH) $fn
    }

    method rebuild {} {
        set fh [open [set fn [$self scriptFn]] w]
        puts $fh [$self generate]
        close $fh
        file attribute $fn -permissions 00775
        if {![file isdirectory [set dir [$self ctrlDir]]]} {
            file mkdir $dir
        }
        set fn
    }

    typevariable ourScriptTemplate {
#!/bin/zsh
emulate -L zsh

spec=(
  p=o_port
  x=o_nox
  T=o_notty
  X=o_withx
  Y=o_withxauth

  'o+:=o_opts'
  'L:=o_Lforw'
)
zparseopts -D -K $spec
opts=(
$o_port
$o_nox
$o_notty
$o_withx
$o_withxauth

$o_opts
$o_Lforw
)

host=$1; shift
orig_host=@ORIG_HOST@
if [[ $host == $orig_host ]]; then
  ssh -S @SSH_CTRL@ $opts $host "$@"
else
  ssh -A -S @SSH_CTRL@ $orig_host ssh -q $opts $host "$@"
fi
    }
}

if {![info level] && $::argv0 eq [info script]} {
    ::sshcomm::git-ssh-proxy .obj {*}$::argv
    puts [.obj connect]
    vwait forever
}
