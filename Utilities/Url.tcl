# Url - support for URL manipulation

if {[catch {package require Debug}]} {
    proc Debug.url {args} {}
    #proc Debug.url {args} {puts stderr url@[uplevel subst $args]}
} else {
    Debug define url 10
}

catch {package require Query}	;# reduced functionality - no redir

package provide Url 1.0

set ::API(Utilities/Url) {
    {
	Url manipulation utility
    }
}

namespace eval ::Url {

    # Support for x-www-urlencoded character mapping
    # The spec says: "non-alphanumeric characters are replaced by '%HH'"
    variable dmap {%0D%0A \n %0d%0a \n %% %}
    #+ " "

    # set up non-alpha map
    for {set i 0} {$i < 256} {incr i} {
	set c [format %c $i]
	lappend dmap %[format %.2X $i] [binary format c $i]
	lappend dmap %[format %.2x $i] [binary format c $i]
    }

    # decode
    #
    #	This decodes data in www-url-encoded format.
    #
    # Arguments:
    #	An encoded value
    #
    # Results:
    #	The decoded value

    proc decode {str} {
	Debug.url {decode '$str'} 10
	variable dmap
	set str [string map $dmap $str]
	Debug.url {mapped '$str' ([binary encode hex $str])} 10
	set str [encoding convertfrom utf-8 $str]
	Debug.url {decoded '$str' ([binary encode hex $str])} 10

	return $str
    }

    # order - lsort command to order URLs
    proc order {k1 k2} {
	# make shorter lists come later in the order
	set l1 [split [string trim $k1 /] /]
	set l2 [split [string trim $k2 /] /]
	set diff [expr {[llength $l2] - [llength $l1]}]
	if {$diff != 0} {
	    #Debug.nub {urlorder '$k1'=[llength $l1] '$k2'=[llength $l2] -> $diff}
	    return $diff
	}

	# make wildcards come later in the order for the same length
	if {[string map {* ~~} $k1] >= [string map {* ~~} $k2]} {
	    #Debug.nub {urlorder '$k1' '$k2' -> 1}
	    return 1
	} else {
	    #Debug.nub {urlorder '$k1' '$k2' -> -1}
	    return -1
	}
    }

    # normalize --
    #
    #	collapse and normalize //, ../ and . components to avoid tricks
    #	like //cgi-bin that fail to match the /cgi-bin prefix
    #	and ../ that escape domains
    #
    # Arguments:
    #	args	url to normalize
    #
    # Results:
    #	normalized url
    #
    # Side Effects:
    #	none

    proc normalize {url} {
	#set url [decode $url]
	while {[set new [regsub -all {(/+)|(^[.][.]/)|(^/[.][.])|(/[^/]+/[.][.]$)|(/[^/]+/[.][.]/)|(^[.]/)|(/[.]$)|(/[.]/)|(^[.][.]$)|(^[.]$)} $url /]] ne $url} {
	    set url $new
	}
	return "/[string trimleft $url /]"
    }

    # strip off path prefix - from ::fileutil
    proc pstrip {prefix path} {
	Debug.url {pstrip prefix:'$prefix' path:'$path'}

	# [split] is used to generate a canonical form for both
	# paths, for easy comparison, and also one which is easy to modify
	# using list commands.
	set trailing [expr {([string index $path end] eq "/")?"/":""}]

	# canonicalise the paths: no bracketing /, no multiple /
	set prefix [string trim $prefix /]
	set path [string trim $path /]
	Debug.url {pstrip canon prefix:'$prefix' path:'$path'}

	if {[string equal $prefix $path]} {
	    return "/"	;# if the paths are canonically string equal, we're sweet
	}

	# split the paths into components
	set prefix [split $prefix /]
	set npath [split $path /]
	Debug.url {pstrip prolog prefix:'$prefix' path:'$path' npath:'$npath'}

	# strip non-matching prolog
	while {[llength $npath] && ![string match ${prefix}* $npath]} {
	    set npath [lrange $npath 1 end]	;# trim off an element
	}
	# $npath is empty or they match.

	# now check if there's a match
	if {[llength $npath]} {
	    # ergo there's a match - preserve dir suffix
	    set match [join [lrange $npath [llength $prefix] end] /]$trailing
	    Debug.url {pstrip match '$npath' - '[join $prefix /]' + '[join $npath /]' -> '$match'}
	    return $match
	} else {
	    # the prefix doesn't match ... try stripping some leading prefix
	    Debug.url {pstrip no match '[join $prefix /]' path:$path}
	    return /$path
	}
    }

    # find the suffix part of a URL-parsed request given a mount point
    proc urlsuffix {r mount} {
	# remember which mount we're using - this allows several
	# domains to share the same namespace, differentiating by
	# reference to -prefix value.
	if {[catch {dict size $r}]} {
	    # accept a single URL instead of a request
	    if {[llength $r] != 1} {
		error "Url urlsuffix requires a request dict or a URL as a first arg"
	    }
	    set r [list -path $r]	;# pretend it's a request
	}

	dict set r -prefix $mount
	set path [dict get $r -path]

	if {[dict exists $r -suffix]} {
	    # caller has munged path already
	    set suffix [dict get $r -suffix]
	} else {
	    # assume we've been parsed by package Url
	    # remove the specified prefix from path, giving suffix
	    set suffix [Url pstrip $mount [string trimleft $path /]]
	    Debug.url {urlsuffix - suffix:'$suffix' url:'$mount'}
	    if {($suffix ne "/") && [string match "/*" $suffix]} {
		# path isn't inside our domain suffix - error
		Debug.url {urlsuffix - '$path' is outside domain suffix '$suffix'}
		return [list 0 [Http NotFound $r]]
	    }
	    dict set r -suffix $suffix
	}

	# calculate .ext of URL
	set ext [split $suffix .]
	if {[llength $ext] == 1} {
	    set ext ""
	} else {
	    set ext [lindex $ext end]
	}
	dict set r -extension $ext

	return [list 1 $r $suffix $path]
    }

    # parsePath --
    #
    #	parse a url path+fragment+query into its constituent parts
    #
    # Arguments:
    #	args	url to parse
    #
    # Results:
    #	array form of parsed URL elements
    #
    # Side Effects:
    #	none

    proc parsePath {url {normalize 1}} {
	Debug.url {Url parsePath $url - norm? $normalize}
	array set x {}
	regexp {^([^?\#]*)([?]([^\#]*))?(\#(.*))?$} $url \
	    -> x(-path) . x(-query) . x(-fragment)

	Debug.url {Url parsePath 1: $url -> [array get x]}

	if {$normalize} {
	    set x(-path) [normalize [decode $x(-path)]]	;# fix up oddities in URLs
	    set x(-normalized) 1
	}

	foreach n [array names x] {
	    if {$x($n) eq ""} {
		unset x($n)
	    }
	}

	Debug.url {Url parsePath: $url -> [array get x]}

	return [array get x]
    }

    # parse --
    #
    #	parse a url into its constituent parts
    #
    # Arguments:
    #	args	url to parse
    #
    # Results:
    #	array form of parsed URL elements
    #
    # Side Effects:
    #	none

    proc parse {url {normalize 1}} {
	Debug.url {Url parse $url - norm? $normalize}
	array set x {}
	regexp {^(([^:/?\#]+):)?(//([^/?\#]*))?([^?\#]*)([?]([^\#]*))?(\#(.*))?$} $url \
	    -> . x(-scheme) . x(-authority) x(-path) . x(-query) . x(-fragment)
	regexp {^(([^@]+)@)?([^@:]+)?(:([0-9]+))?$} $x(-authority) \
	    -> . x(-authority) x(-host) . x(-port)

	if {$normalize} {
	    set x(-path) [normalize [decode $x(-path)]]	;# fix up oddities in URLs
            #set x(-query) [decode $x(-query)]
	    set x(-normalized) 1
	}

	foreach n [array names x] {
	    if {$x($n) eq ""} {
		unset x($n)
	    }
	}

	Debug.url {Url parse $url -> [array get x]}

        if {[info exists x(-host)]} {
            # clean up host - check its validity?
            set x(-host) [string tolower $x(-host)]
        }

        if {[info exists x(-scheme)]} {
            # clean up scheme - check its validity?
            set x(-scheme) [string tolower $x(-scheme)]
        } else {
            set x(-scheme) http
        }

	Debug.url {Url parse post regexp: [array get x]}

	if {[info exists x(-scheme)]} {
	    set x(-url) [url [array get x]]
	} else {
	    #set x(-scheme) http
	}

	Debug.url {Url parse: $url -> [array get x]}

	return [array get x]
    }

    # Parse - parse without silly leading -* on names
    proc Parse {url} {
	set result {}
	dict for {k v} [parse $url] {
	    lappend result [string trim $k -] $v
	}
	return $result
    }

    proc url {args} {
	if {[llength $args] == 1} {
	    set args [lindex $args 0]
	}
	Debug.url {Url url $args}
        if {![dict exists $args -scheme]} {
            dict set args -scheme http	;# need a default.
        }

	# minimize -port
	if {[dict exists $args -port]} {
	    if {[dict get $args -port] eq ""} {
		dict unset args -port
	    } elseif {[dict get $args -scheme] eq "http" && [dict get $args -port] eq "80"} {
		dict unset args -port
	    } elseif {[dict get $args -scheme] eq "https" && [dict get $args -port] eq "443"} {
		dict unset args -port
	    } elseif {[dict get $args -scheme] eq "ftp" && [dict get $args -port] eq "21"} {
		dict unset args -port
	    }
	}

	foreach {part pre post} {
	    -scheme "" :/
	    -host / ""
	    -port : ""
	    -path "" ""
	} {
	    if {[dict exists $args $part]} {
		append result "${pre}[dict get $args $part]${post}"
	    }
	}

	Debug.url {Url url $args -> $result}
	return $result
    }

    proc uri {x args} {
	if {[llength $args] == 1} {
	    set args [lindex $args 0]
	}
	set result [url $x]

	foreach {part pre post} {
	    -query ? ""
	    -fragment \# ""
	} {
	    if {[dict exists $x $part]} {
		append result "${pre}[dict get $x $part]${post}"
	    }
	}
	return $result
    }

    # localuri - return a local uri, no host scheme or port
    proc localuri {x args} {
	if {[llength $args] == 1} {
	    set args [lindex $args 0]
	}
	set result [dict get $x -path]

	foreach {part pre post} {
	    -query ? ""
	    -fragment \# ""
	} {
	    if {[dict exists $x $part]} {
		append result "${pre}[dict get $x $part]${post}"
	    }
	}
	return $result
    }

    # freeparse - parse a free form url-ish string
    proc freeparse {urlish args} {
        if {[llength $args] == 1} {
            set args [lindex $args 0]
        }

        # set defaults in url dict from args
        set result {scheme http}
        foreach {f def} {scheme host port} {
            if {[dict exists $args -$f]} {
                dict set result -$f [dict get $args -$f]
            }
        }

        switch -nocase -glob -- $urlish {
            http* {
                # full URL
                set result [parse $urlish]
            }
            //* {
                # host-absolute path-absolute - parse+normalize
                set urlish /[join [lassign [split $urlish /] -> host] /]
                set result [dict merge $result [list -host $host] [parsePath $urlish]]
            }
            /* {
                # host-relative path-absolute - parse+normalize
                set result [dict merge $result [parsePath $urlish]]
            }
            default {
                # host-relative path-relative - parse but don't normalize
                set result [dict merge $result [parsePath $urlish 0]]
            }
        }
        return $result
    }

    # process a possibly local URI for redirection
    # provides a limited ability to add query $args
    # limits: overwrites existing args, ignores and removes duplicates
    proc redir {defaults to args} {
	Debug.url {redir defaults:$defaults to:$to args:$args}
	#puts stderr "redir defaults:($defaults) to:$to args:$args"
	if {[llength $args] == 1} {
	    set args [lindex $args 0]
	}

	set todict [freeparse $to $defaults]	;# parse the destination URL

	if {[dict exists $todict -query]} {
	    foreach {n v} [Query flatten [Query parse $todict]] {
		dict set query $n $v
	    }
	} else {
	    set query {}
	}

	# parse args as additional -query elements
	foreach {name val} $args {
	    dict set query $name $val
	}

	set q ""
	dict for {n v} $query {
	    if {$v ne ""} {
		lappend q "$n=[Query encode $v]"
	    } else {
		lappend q $n
	    }
	}
	if {$q ne {}} {
	    dict set todict -query [join $q &]
	}

	if {([dict get? $todict -host] ni [list "" [dict get? $defaults -host]])
	    || ([dict get? $todict -port] ni [list "" [dict get? $defaults -port]])
	} {
	    # this is a remote URL
	    set to [uri $todict]
	} else {
	    # local URL - no scheme, host, port, etc.
	    set to [localuri $todict]
	}

	Debug.url {redir to: $to}
	return $to
    }

    # construct the host part of a URL dict
    proc host {x} {
	if {[dict exists $x -port]
	    && [dict get $x -port] ne {}
	    && [dict get $x -port] != 80} {
	    return "[dict get $x -host]:[dict get $x -port]"
	} else {
	    return "[dict get $x -host]"
	}
    }

    # construct a URL from a URL dict
    proc http {x args} {
	Debug.url {Url http $x}

	set result ""
	foreach {part pre post} {
	    -path "" ""
	    -fragment \# ""
	    -query ? ""
	} {
	    if {[dict exists $x $part]} {
		append result "${pre}[dict get $x $part]${post}"
	    }
	}
	Debug.url {Url http $x -> $result}
	return $result
    }

    # insert a fully expanded path, uri and url into a request
    proc path {req path} {
	dict set req -path $path
	dict set req -url [url $req]
	dict set req -uri [uri $req]
	return $req
    }

    # flatten the -path into a -suffix
    proc flatten {req} {
	dict set req -suffix [lindex [split [string trimright [dict get $req -path] /] /] end]
	return $req
    }

    # d2url - given a dict URL and some query args,
    # return a URL
    proc d2url {dict args} {
	Debug.url {d2url dict:$dict args:$args}
	if {[llength $args] == 1} {
	    set args [lindex $args 0]
	}

	if {[dict exists $dict -query]} {
            # get a dict var {{val meta} ...}
	    set query [Query parse $dict]
	} else {
	    set query {}
	}

	# parse args as additional -query elements
        # replacing elements with the same name
	foreach {name val} $args {
	    set query [Query replace $query $name $val]
	}

        # generate an encoded URL query fragment
        set q [Query query_encode $query]
	if {$q ne ""} {
	    dict set dict -query $q
	}

        set to [uri $dict]
	Debug.url {d2url to: $to}
	return $to
    }

    # change the suffix of a request
    proc suffix {x suffix} {
	dict set x -suffix $suffix
	dict set x -path [join [list {*}[dict get $x -prefix] {*}$suffix]]
	dict set x -url [url $x]
	dict set x -uri [uri $x]
	return $x
    }

    proc range {url from to} {
	Debug.url {Url range: '$url' -> '[join [lrange [split $url /] $from $to] /]'}
	return [join [lrange [split $url /] $from $to] /]
    }

    proc tail {url} {
	Debug.url {Url tail: '$url' -> '[lindex [split $url /] end]'}
	return [lindex [split $url /] end]
    }

    namespace export -clear *
    namespace ensemble create -subcommands {}
}

if {[info exists argv0] && ($argv0 eq [info script])} {
    # test normalization
    foreach {i o exp} {
	example.com http://example.com/ "A URI with a missing scheme is normalized to a http URI"
	http://example.com http://example.com/ "An empty path component is normalized to a slash"
	https://example.com/ https://example.com/ "https URIs remain https URIs"
	http://example.com/user http://example.com/user "No trailing slash is added to non-empty path components"
	http://example.com/user/ http://example.com/user/ "Trailing slashes are preserved on non-empty path components"
	http://example.com/ http://example.com/ "Trailing slashes are preserved when the path is empty"
	=example =example "Normalized XRIs start with a global context symbol"
	xri://=example =example "Normalized XRIs start with a global context symbol"
    } {
	set d [Url parse $i]
	if {[Url uri $d] ne $o} {
	    puts stderr "'[Url uri $d]' doesn't match $o.  Assertion failed: $exp over ($d)"
	}
    }
}
# vim: ts=8:sw=4:noet
