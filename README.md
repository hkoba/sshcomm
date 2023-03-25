sshcomm -- comm via ssh
====================

This tcl package allows you to do
[comm](https://core.tcl-lang.org/tcllib/doc/trunk/embedded/md/tcllib/files/modules/comm/comm.md)
based remote scripting via secure shell connection.

Basic usage is like:

```tcl
package require sshcomm
set cid [sshcomm::comm $host]
comm::comm send $cid {script...}

# or simply. (But note, in this form, arguments are evaluated **locally**!)
$cid command args...

```

Or more configurable, multi-comm style:

```tcl
set ssh [sshcomm::ssh $host]
# or set ssh [sshcomm::connection %AUTO% -host $host]
set c1 [$ssh comm new]
set c2 [$ssh comm new]
comm::comm send -async $c1 {script...}
comm::comm send -async $c2 {script...}
```

To send namespace/snit::type
--------------------

```tcl
namespace eval foo {proc x {} {list X}}
snit::type Dog {
  option -name "no name";
  method bark {} {return "$options(-name) barks."}
}

comm::comm send $cid [sshcomm::definition ::foo ::Dog]

# Then

$cid foo::x
# => X
$cid Dog d -name Hachi
# ::d
$cid d bark
# => Hachi barks.
```

## Installation Instructions for sshcomm

sshcomm is only available via git, at least for now.
(Please let me know if you know a GitHub workflow to build a tcl package release.)
To install the sshcomm library, follow the instructions below.

### Prerequisites

- Git must be installed on your system.
- You should have a working knowledge of the command-line interface.

### Per-project Installation

1. Navigate to the root directory of your project. For example, `cd ~/project`.

2. If your project is not yet under git version control, run the following command:
   ```
   git init
   ```
3. Create a `libtcl` directory within your project:
   ```
   mkdir -p libtcl
   ```
4. Use `git submodule` to add the sshcomm library to your project:
   ```sh
   git submodule add https://github.com/hkoba/sshcomm.git libtcl/sshcomm
   ```
5. Launch Tclsh: `tclsh`.
6. Add the `libtcl` directory to the Tcl auto_path: `lappend ::auto_path [pwd]/libtcl`.
7. Load the sshcomm package: `package require sshcomm`.

To use sshcomm in your scripts within the project, add the following line before `package require sshcomm`:

```tcl
lappend ::auto_path [file dirname [file normalize [info script]]]/libtcl
```

Alternatively, you can set the TCLLIBPATH environment variable before running the script, but the method to achieve this depends on your shell (bash, zsh, etc.).

Instead of using package require, you can also use `[source]` command:

```tcl
source [file dirname [file normalize [info script]]]/libtcl/sshcomm/sshcomm.tcl
```

## System-wide Installation
To install sshcomm system-wide, run the following command with administrator permissions:


```tcl
exec git clone https://github.com/hkoba/sshcomm.git [info library] sshcomm
```

Note that this method requires system write permission.
