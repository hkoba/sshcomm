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

## How to install

Use git to install sshcomm.

### Per-project installation

The easiest way to use this library is to prepare "libtcl" directory in your project and add sshcomm using "git submodule" like the following:

```sh
# in your project
git submodule add https://github.com/hkoba/sshcomm.git libtcl/sshcomm
```

Then you can use sshcomm in your scripts:

```tcl
lappend ::auto_path [file dirname [file normalize [info script]]]/libtcl

package require sshcomm

# Or you may source it directly
source [file dirname [file normalize [info script]]]/libtcl/sshcomm/sshcomm.tcl
```

### System-wide installation

Alternatively, you may want to install sshcomm system-wide. (System write permission is required)

```tcl
exec git clone https://github.com/hkoba/sshcomm.git [info library]
```
