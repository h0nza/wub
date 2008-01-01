package require fileutil

package provide Block 2.0

namespace eval Block {
    variable blocked; array set blocked {}
    variable logdir ""

    proc block {ipaddr {reason ""}} {
	variable blocked
	set blocked($ipaddr) [list [clock seconds] $reason]
	::fileutil::appendToFile [file join $logdir blocked] "$ipaddr [list $blocked($ipaddr)]\n"
	Debug.block {BLOCKING: $ipaddr $reason}
    }

    proc blocked? {ipaddr} {
	variable blocked
	return [info exists blocked($ipaddr)]
    }

    proc init {args} {
	variable {*}$args
	variable blocked
	array set blocked [fileutil::cat [file join $logdir blocked]]
    }

    proc blocklist {} {
	variable blocked
	return [array get blocked]
    }

    namespace export -clear *
    namespace ensemble create -subcommands {}
}
