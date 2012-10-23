sshcomm -- comm via ssh
====================

This tcl package allows you to do
[comm](http://tcllib.sourceforge.net/doc/comm.html)
based remote scripting via secure shell connection.

Basic usage is like:

```tcl
package require sshcomm
set comm_id [sshcomm::comm $host]
comm::comm send $comm_id {script...}
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
