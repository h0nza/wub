# Session - handle Session vars stored in a db, indexed by a cookie.
#
# This is to be run in the main thread, and to amend the -session var in
# a request, to be passed along with request to Workers.
#
# ARCHITECTURE:
#
# Cookies shouldn't be sent with a path of /, because it screws up caching of static content.
#
# Session maintains a key in cookie $cookie which is sent within a constrained path.
# (a) how can a cookie within a constrained path be used
# everywhere on a site when it's only sent for a subpath of the site - use a
# web-bug technique - load some file from session domain on every page, don't cache
# that subdomain.  Use Wub to associate the cookie with the whole session.
# (b) how can a cookie within a sub-path impact on the whole page as seen by a
# client?  Javascript.  Send javascript from the web bug.
#
# IMPLEMENTATION:
# Sessions are records in a tdbc table which are mirrored in the corovar scope (uplevel #1)
# the cookie maps to a defined coroutine which is maintained by Session, and in which all
# request processing occurs.

# If the session variables change during processing of the request, changes will
# be rewritten to the database.

package require Debug
Debug define session 10
package require OO
package require md5

package provide Session 4.0
set ::API(Session) {
    {
	Session manager
    }

    lazy {to number of seconds to flush *only* periodically (default: 0 - flush every time.)}
    establish {auto-establish a persistent record for each new session? (default: yes)}

    tdbc {Which TDBC backend type should be used (default: sqlite3)}
    db {an already-connected tdbc db (default none - use $schema to create $table in $file)}
    file {a db file to be created (default none)}
    tdbc_opts {::tdbc::connection creation options (default "")}
    schemafile {a file containing a schema for table creation}
    schema {schema to create the session table, if no $db is specified}
    table {name of the session table for storing session vars (default: $cookie)}
    key {name of the field for session key var / session id (default: $cookie)}

    cookie {session cookie name (default: "session")}
    cpath {session cookie path - this (default "/" is a bad idea.)}
    expires {how long does this cookie live? (default "next month")}
    cookie_args {extra args for cookie creation}
}

class create ::Session {
    # id - the current session id
    classmethod id {} {
	namespace tail [info coroutine]	;# returns the current session's id
    }

    # establish - establish/persist *this* session
    classmethod establish {} {
	Debug.session {called classmethod establish}
	uplevel #1 my establish	;# redirect to Session instance
    }

    # Session variable - map a session variable into local scope
    classmethod variable {args} {
	uplevel 1 [list [uplevel #1 self] variable {*}$args]	;# redirect to Session instance
    }
    method variable {args} {
	Debug.session {Session variable $args}
	if {[llength $args] == 1} {
	    set n [lindex $args 0]
	    uplevel 1 [list upvar #1 $n $n]
	} else {
	    foreach {n v} $args {
		uplevel 1 [list upvar #1 $n $n]
		uplevel 1 [list set $n $v]
	    }
	}
    }

    # active - the activity of active sessions
    method active {} {
	variable active; array get active
    }

    # established - the established state of sessions
    method established {} {
	variable established; array get established
    }

    # sessionvar - return the name of the session variable
    classmethod sessionvar {} {
	uplevel #1 my sessionvar	;# redirect to Session instance
    }
    method sessionvar {} {
	# the name of the session variable
	variable key; return $key
    }

    # close - a session within this Session
    classmethod close {} {	    # close from within a session
	uplevel #1 my close [info coroutine]	;# redirect to Session instance
    }
    method close {session} {
	# close the named session
	variable terminate; set terminate($session) 1
    }

    # /close - Direct Domain closure of this session
    method /close {r} {
	variable ::cookie
	# we are inside the subject domain, so can use their cookie
	my close [my id]
    }

    # idle - return list of sessions idle longer than the proffered time
    method idle {args} {
	if {![llength $args]} {
	    set args {1 day}
	}

	variable active;
	set now [clock seconds]
	set idle {}
	foreach {session when} [lsort -integer -stride 2 -index 1 [array get active]] {
	    if {[clock add $when {*}$args] > $now} {
		lappend idle $session
	    }
	}
	return $idle
    }

    # close_idle - close sessions which have been idle for more than a given time
    method close_idle {args} {
	foreach session [my idle {*}$args] {
	    my close $session
	}
    }

    # variables - the set of session variables
    classmethod variables {} {	# access from within a session
	return [uplevel #1 my variables [info coroutine]]	;# redirect to session instance
    }
    method variables {session} {
	variable variables; return $variables($session)
    }

    # flush_lazy - flush all pending mods to the db
    method flush_lazy {} {
	variable lazy
	if {!$lazy} {
	    error "Can't flush lazy unless the Session is lazy which [self] is not."
	}

	variable varmod
	foreach coro [array names varmod] {
	    my flush [my id] {*}$varmod($coro)
	    unset varmod($coro)
	}

	after [expr {$lazy * 1000}] [list [self] flush_lazy]
    }

    # varmod - record and return all session variable modifications
    method varmod {args} {
	variable varmod
	if {![llength $args]} {
	    if {[info exists varmod([info coroutine])]} {
		Debug.session {varmod summary [info coroutine]/[namespace current] $varmod([info coroutine])}
		set result $varmod([info coroutine])
		unset varmod([info coroutine])
	    } else {
		set result {}
	    }
	    Debug.session {varmod summary [info coroutine] $result}
	    return $result
	}
	if {[catch {
	    lassign $args id name1 name2 op
	    Debug.session {varmod [string toupper $op]: [info coroutine]/[namespace current] $args}
	    # puts stderr "VARMOD [info coroutine] [info frame -1]/[info frame -2]/[info frame -3]"
	    variable key
	    if {$name1 eq $key} {
		# the user has tried to modify the session variable
		# reset it to what it should be, and error.
		set session_var [uplevel #1 [list set $key $id]]
		if {$op eq "unset"} {
		    # have to re-establish the trace
		    uplevel #1 [list ::trace add variable $name1 {write unset} [list [my self] varmod $id]]
		    # we can't error out of an unset ... oh well
		}
		error "if you modify the session variable, you're not gonna have a good time."
	    }
	    variable lazy
	    switch -- $op {
		write {
		    if {$lazy} {
			# store the values for later writing to db
			dict set varmod([info coroutine]) write $name1 [uplevel #1 [list set $name1]]
		    } else {
			dict set varmod([info coroutine]) write $name1 1
		    }
		    catch {dict unset varmod([info coroutine]) unset $name1}
		}
		unset {
		    dict set varmod([info coroutine]) unset $name1 1
		    catch {dict unset varmod([info coroutine]) write $name1}
		}
	    }
	} e eo]} {
	    Debug.error {Session [self] varmod [info coroutine] $id $args ERROR '$e' ($eo)}
	}
    }

    # corodead - the coroutine has died, clean up after it.
    method corodead {coro args} {
	variable varmod; catch {unset varmod($coro)}

	set id [namespace tail $coro]
	variable variables; catch {unset variables($id)}
	variable active; catch {unset active($id)}
	variable terminate; catch {unset terminate($id)}
	variable established; catch {unset established($id)}

	Debug.session {corodead session $id}
    }

    # self - for the shim
    method self {} {
	return [self]
    }

    # prep - prepare a stmt or reused an already cached stmt
    method prep {stmt} {
	variable stmts	;# here are some statements we prepared earlier
	if {![info exists stmts]} {
	    set stmts {}
	}
	variable max_prepcache
	if {[dict exists $stmts $stmt]} {
	    set s [dict get $stmts $stmt]
	    if {$max_prepcache > 0} {
		# move matched element to end of cache (for LRU)
		dict unset stmts $stmt
		dict set stmts $stmt $s
	    }
	} else {
	    set s [my db prepare $stmt]
	    dict set stmts $stmt $s
	    if {$max_prepcache > 0 && [dict size $stmts] > $max_prepcache} {
		Debug.session {removing LRU cached statement}
		set stmts [lrange $stmts 2 end]
	    }
	}
	return $s
    }

    method prep_purge {} {
	variable stmts	;# here are some statements we prepared earlier
	set stmts {}
    }

    # exec - execute a statement over db
    method exec {stmt args} {
	set incomplete 1
	while {$incomplete} {
	    # try to prep a statement - reconnect on connection down
	    set prepped ""
	    while {$prepped eq ""} {
		try {set prepped [my prep $stmt]} trap {TDBC REMOTE_DATABASE_ACCESS_ERROR} {e eo} {
		    variable reconnect
		    if {[llength $reconnect]} {
			my prep_purge
			variable db; {*}$reconnect $db $e $eo
		    } else {
			return -options $eo $e
		    }
		}
	    }

	    # try to execute the script around a prepped statement - reconnect on connection down
	    try {
		set result [uplevel 1 [list $prepped {*}$args]]
	    } trap {TDBC REMOTE_DATABASE_ACCESS_ERROR} {e eo} {
		variable reconnect
		if {[llength $reconnect]} {
		    my prep_purge
		    variable db; {*}$reconnect $db $e $eo
		} else {
		    return -options $eo $e
		}
	    } on error {e eo} {
		return -options $eo $e
	    } on ok {} {
		set incomplete 0
	    }
	}

	return $result
    }

    # flush - write back session variable changes
    method flush {id args} {
	variable established
	if {!$established($id)} {
	    Debug.session {flush $id not established, not flushing}
	    return
	}

	set write {}; set unset {}
	dict with args {}
	if {![llength $write] && ![llength $unset]} {
	    Debug.session {flush $id nothing to flush}
	    return
	}
	variable key

	foreach field [dict keys $unset] {
	    if {$field eq $key} continue
	    lappend vars $field=NULL
	}

	variable lazy
	foreach {field value} $write {
	    if {$field eq $key} continue
	    incr i
	    lappend vars $field=:V$i
	    if {$lazy} {
		dict set values V$i $value
	    } else {
		dict set values V$i [uplevel \#1 [list set $field]]
	    }
	}

	# prepared db command nulls field
	variable table
	variable key
	dict set values key $id
	Debug.session {flush 'UPDATE $table SET [join $vars ,] WHERE $key = $id' over ($values)}
	set result [my exec "UPDATE $table SET [join $vars ,] WHERE $key = :key" allrows -- $values]

	Debug.session {flushed $result}
    }

    # name of all known session $id variables
    method fields {id} {
	variable fields		;# names of all known session variables
	if {![info exists fields]} {
	    variable table; set fields [dict keys [my db columns $table]]
	}
	return $fields
    }

    # shim - coroutine code which indirects to the domain handler, providing a place to store
    # session vars etc.
    # The handler is run in an apply to keep variable scope #1 pristine
    # the [my] command will invoke in this Session instance.
    method shim {args} {
	::apply [list {} {
	    variable active	;# introspection - last session access

	    variable lazy	;# is this session_manager lazy?

	    Debug.session {shim [info coroutine] START}
	    set id [my id]
	    set r {}
	    variable handlers
	    variable terminate
	    while {![info exists terminate($id)]} {
		Debug.session {[info coroutine] yielding}
		set r [::yieldm $r]
		if {![llength $r]} break
		set r [lindex $r 0]
		Debug.session {[info coroutine] running}

		set active($id) [clock seconds]

		# fetch session variables by key
		# do it only when we've got a real request
		variable variables	;# introspect session var names
		variable cookie		;# name of cookie
		variable key
		if {![info exists variables($id)]} {
		    set vars [my fetch $id]
		    dict set vars $key $id	;# the session var always exists
		    Debug.session {coro VARS ([my fields $id]) fetched ($vars)}
		    foreach n [my fields $id] {
			Debug.session {shim var $n}
			catch {uplevel #1 [list ::trace remove variable $n {write unset} [list [my self] varmod $id]]}
			if {[dict exists $vars $n]} {
			    Debug.session {shim var assigning $n<-'[dict get $vars $n]'}
			    uplevel #1 [list set $n [dict get $vars $n]]
			} else {
			    catch {uplevel #1 [list unset $n]}
			}
			uplevel #1 [list ::trace add variable $n {write unset} [list [my self] varmod $id]]
			lappend variables($id) $n
		    }
		}

		# run pre-handler script if any
		variable pre
		if {[info exists pre]} {
		    set r [uplevel 1 [list ::apply [list {r} $pre [namespace current]] $r]]
		}

		# handle the request - if handler disappears, we're done
		Debug.session {coro invoking: $handlers([dict get $r -section])}
		set r [uplevel 1 [list $handlers([dict get $r -section]) do $r]]

		# run post-handler script if any
		variable post
		if {[info exists post]} {
		    set r [uplevel 1 [list ::apply [list {r} $post [namespace current]] $r]]
		}

		if {!$lazy} {
		    Debug.session {assiduous (non-lazy) flush $id}
		    my flush $id {*}[my varmod]	;# write back session variable changes
		}
	    }
	} [namespace current]]
	Debug.session {[info coroutine] TERMINATING}
    }

    # fetch - fetch variables for session $id
    method fetch {id} {
	variable table
	variable key
	set result [lindex [my exec "SELECT * FROM $table WHERE $key = :key" allrows -as dicts -- [list key $id]] 0]
	Debug.session {fetch ($result)}
	return $result
    }

    # check - does session $id have any persistent records?
    method check {id} {
	# check the state of this session
	variable table
	variable key
	set check [lindex [my exec "SELECT count(*) FROM $table WHERE $key = :key" allrows -- [list key $id]] 0]
	Debug.session {CHECK $check}
	return [lindex $check 1]
    }

    # establish - create a minimal record for session
    method establish {{id ""}} {
	if {$id eq ""} {
	    set id [my id]
	} else {
	    set id [namespace tail $id]
	}
	Debug.session {establishing $id}

	variable established
	if {$established($id)} {
	    Debug.session {establish $id - already established}
	    return	;# already established
	}

	variable table
	variable key
	set result [my exec "INSERT INTO $table ($key) VALUES (:key)" allrows -- [list key $id]]
	set established($id) 1

	Debug.session {established 'INSERT INTO $table ($key) VALUES ($id)' -> $result}
    }

    # Establish - set up a session record for $id
    method Establish {id} {
	variable established
	variable key
	set stored [my fetch $id]

	# check the state of the session
	switch -- [my check $id],[dict exists $stored $key] {
	    0,0 {
		# no record for this session
		variable establish
		set established($id) 0
		if {$establish} {
		    Debug.session {No data for $id - make some}
		    my establish $id
		    Debug.session {CHECK [my check $id]}
		} else {
		    Debug.session {No data for $id - no establishment}
		}
	    }
	    1,1 {
		# the session is persistent *and* has data
		Debug.session {session $id has data ($stored)}
		set established($id) 1
	    }
	    1,0 -
	    0,1 -
	    default {
		error "Impossible State ($check,[dict size $stored]) checking session $id"
	    }
	}
    }

    # do - perform the action
    # we get URLs from both our Direct Domain (if it's mounted)
    method do {r} {
	# see if this request is for the Session instance as manager
        variable mount
	if {[info exists mount]
	    && [string match ${mount}* [dict get $r -path]]
	} {
	    # our Direct Domain is mounted and this request is ours
	    Debug.session {passthrough to Direct for [self] $result suffix:$suffix path:$path}
	    return [next $r]	;# the URL is in our Session domain, fall through to Direct
	}

	# the URL is (presumably) in one of the handled subdomains

	# fetch or create a cookie session identifier
	variable cookie
	Debug.session {session cookie $cookie: [Cookies Fetch? $r -name $cookie] / ([dict get $r -cookies])}
	set id [Cookies Fetch? $r -name $cookie]
	variable established
	if {$id eq ""} {
	    # There is no session cookie - create a new session, id, and cookie
	    Debug.session {create new session}

	    # create new session id
	    variable uniq; set id [::md5::md5 -hex [self][incr uniq][clock microseconds]]

	    # create the cookie
	    variable cpath; variable expires; variable cookie_args;
	    set r [Cookies Add $r -path $cpath -expires $expires {*}$cookie_args -name $cookie -value $id]
	    set established($id) 0
	    Debug.session {new session: $id - cookies [dict get $r -cookies]}
	} else {
	    # We have been given the session cookie
	    set id [dict get [Cookies Fetch $r -name $cookie] -value]
	    Debug.session {session cookie: $id}
	}

	# find active session with $id
	set coro [namespace current]::Coros::$id	;# remember session coro name
	if {![llength [info commands $coro]]} {
	    # we don't have an active session for this id - create one
	    variable handlers
	    
	    Debug.session {create coro: $coro for session $id}

	    my Establish $id	; # create a session persistent record

	    ::coroutine $coro [self] shim	;# create coro shim with handler
	    trace add command $coro delete [list [self] corodead]
	} else {
	    # the coro's running
	    variable established
	    Debug.session {existing coro.  established? $established($id)}
	}

	# call the handler shim to process the request
	dict set r -prefix [dict get $r -section]	;# adjust the prefix for indirection
	Debug.session {calling $coro over -section [dict get $r -section]}
	tailcall $coro $r
    }
    
    # new - create a Domain supervised by this Session manager
    # called when the domain is created by Nub, which thinks this Session instance is a class
    method new {domain args} {
	error "Session subdomains must be named"

	set mount [dict get $args mount]
	package require $domain
	variable handlers
	set handlers($mount) [namespace eval ::Domains::$mount [list $domain new {*}$args]]
	return [self]
    }

    # create - create a named Domain supervised by this Session manager
    # called when the domain is created by Nub, which thinks this Session instance is a class
    method create {name args} {
	Debug.session {[self] constructing session handler name:'$name' $args}
	set mount [dict get $args mount]
	set domain [dict get $args domain]
	package require $domain
	variable handlers
	set handlers($name) [$domain create $name {*}$args]
	return [self]
    }

    method / {r} {
	error "Can't get to here"
    }

    superclass Direct
    constructor {args} {
	Debug.session {constructing [self] $args}
	variable tdbc sqlite3		;# TDBC backend
	variable db ""			;# already open db
	variable reconnect {}		;# cmd prefix called if remote DB disconnects
	variable file ""		;# or db file
	variable tdbc_opts {}		;# ::tdbc::connection creation options
	variable schemafile ""		;# file containing schema
	variable schema {}		;# schema for empty dbs
	variable table ""		;# table for session vars
	variable key ""			;# field for session key var

	variable cookie "session"	;# session cookie name
	variable cpath "/"		;# session cookie path - this default is a bad idea.
	variable expires "next month"	;# how long does this cookie live?
	variable cookie_args {}		;# extra args for cookie creation

	variable lazy 0			;# set lazy to number of seconds to flush *only* periodically
	variable establish 1		;# auto-establish a persistent record for each new session?
	#variable pre			;# an apply body to run before domain handling
	#variable post			;# an apply body to run after domain handling

	variable {*}[Site var? Session]	;# allow .config file to modify defaults
	variable {*}$args
	next {*}$args

	if {$table eq ""} {
	    set table $cookie		;# default table is named for cookie
	}
	if {$key eq ""} {
	    set key $cookie		;# default session key field is named for cookie
	}

	variable handlers		;# handlers created by this session manager
	array set handlers {}

	variable terminate		;# terminate this coro peacefully
	array set terminate {}
	variable active			;# activity time per coro
	array set active {}
	variable variables		;# session variables per coro
	array set variables {}
	variable varmod			;# record session var mods per coro
	array set varmod {}
	variable established		;# has this session been persisted?
	array set established {}

	# create the local namespace within which all coros will be created
	namespace eval [namespace current]::Coros {}

	# set up the DB table
	if {$db ne ""} {
	    Debug.session {provided db: '$db'}
	} elseif {$file ne ""} {
	    package require tdbc
	    package require tdbc::$tdbc

	    set ons [namespace current]
	    Debug.session {creating db: tdbc::${tdbc}::connection create [namespace current]::dbI $file $tdbc_opts}
	    file mkdir [file dirname $file]
	    set db [tdbc::${tdbc}::connection new $file {*}$tdbc_opts]
	    oo::objdefine [self] forward db $db	;# make a db command alias
	} else {
	    error "Must provide a db file or an open db"
	}
	oo::objdefine [self] forward db {*}$db

	#Debug.session {db configure: [my db configure]}
	if {[my db tables] eq ""} {
	    # we don't have any tables - apply schema
	    if {$schema eq "" && $schemafile ne ""} {
		set fd [open $schemafile r]
		set schema [read $fd]
		close $fd
	    }
	    if {$schema eq ""} {
		error "Must provide a schema,schemafile or an initialized db"
	    } else {
		Debug.session {schema: $schema}
		my db allrows $schema
	    }
	}

	if {$table ni [my db tables]} {
	    error "Session requires a table named '$table'"
	}

	variable max_prepcache 0	;# no limit to number of cached sql stmts

	# prepare some sql statemtents to NULL and UPDATE session vars
	if {$lazy} {
	    after [expr {$lazy * 1000}] [list [self] flush_lazy]
	}

	package provide [namespace tail [self]] 1.0	;# hack to let Session instances create domains
    }
}

class create SimpleSession {
    # establish - create a minimal record for session
    method establish {id} {
	if {$id eq ""} {
	    set id [my id]
	} else {
	    set id [namespace tail $id]
	}
	Debug.session {establishing $id}

	variable established
	if {$established($id)} {
	    return	;# already established
	} else {
	    set established($id) 1
	}

	variable table
	variable key
	my exec "INSERT INTO $table ($key,name,value) VALUES (:key,$key,:key)" allrows -- [list key $id]
    }

    # fetch - fetch variables for session $id
    method fetch {id} {
	variable table
	variable key
	set record {}
	my exec "SELECT * FROM $table WHERE $key = :key" foreach -as dicts -- rec [list key $id] {
	    dict set record [dict get $rec name] [dict get $rec value]
	}
	variable fields; set fields [dict keys $record]
	return $record
    }

    # check - does session $id have any persistent records?
    method check {id} {
	# check the state of this session
	variable table
	variable key
	set check [lindex [my exec "SELECT count(*) FROM $table WHERE $key = :key" allrows -- [list key $id]] 0]
	Debug.session {CHECK $check}
	return [expr {[lindex $check 1]>0}]
    }

    method fields {id} {
	variable fields
	return $fields($id)
    }

    # flush - write back session variable changes
    method flush {id args} {
	variable established; if {!$established($id)} return

	set write {}; set unset {}
	dict with args {}
	if {![llength $write] && ![llength $unset]} {
	    return
	}

	variable table
	variable key
	my db transaction {
	    foreach field [dict keys $unset] {
		if {$field eq $key} continue	;# skip modifications to cookie var
		lappend result [my exec "DELETE FROM $table SET $field = NULL WHERE $key = :key AND name=:name" allrows -- [list key $id name $field]]
	    }

	    foreach {field value} $write {
		if {$field eq $key} continue	;# skip modifications to cookie var
		if {!$lazy} {
		    set value [uplevel \#1 [list set $field]]
		}
		lappend result [my exec "INSERT OR REPLACE INTO $table ($key,name,value) (:key,:name,:value)" allrows -- [list key $id name $field value $value]]
	    }
	}

	Debug.session {shim wrote back $result}
	return $result
    }

    # variable - map variables to corovars
    method variable {args} {
	variable variables
	Debug.session {Session variable $args}
	set id [my id]
	if {[llength $args] == 1} {
	    set n [lindex $args 0]
	    catch {uplevel #1 [list ::trace remove variable $n {write unset} [list [my self] varmod $id]]}
	    uplevel 1 [list upvar #1 $n $n]
	    uplevel #1 [list ::trace add variable $n {write unset} [list [my self] varmod $id]]
	} else {
	    foreach {n v} $args {
		catch {uplevel #1 [list ::trace remove variable $n {write unset} [list [my self] varmod $id]]}
		uplevel 1 [list upvar #1 $n $n]
		uplevel #1 [list ::trace add variable $n {write unset} [list [my self] varmod $id]]
		uplevel 1 [list set $n $v]
	    }
	}
    }

    superclass Session
    constructor {args} {
	if {![dict exists $args schema]} {
	    dict set args schema {
		DROP TABLE IF EXISTS session;
		CREATE TABLE session (
				      session VARCHAR(32),
				      name TEXT,
				      value TEXT
				      );
	    }
	}

	next {*}$args
    }
}

if {0} {
    # this goes in local.tcl and is accessed as /session
    namespace eval ::TestSession {
	proc / {r} {
	    Debug.session {TestSession running in [info coroutine]}
	    Session variable counter
	    if {[info exists counter]} {
		Debug.session {counter exists: $counter}
	    } else {
		Debug.session {counter does not exist}
	    }
	    incr counter

	    Session variable session
	    return [Http NoCache [Http Ok $r [<p> "COUNT $counter in $session"]]]
	}

	proc /variables {r} {
	    return [Http NoCache [Http Ok $r [<p> "VARIABLES [Session variables]"]]]
	}

	proc /establish/1 {r} {
	    Session establish	;# this makes this session persist
	    Session variable session
	    return [Http NoCache [Http Ok $r [<p> "ESTABLISHED $session"]]]
	}

	proc /establish {r} {
	    puts stderr "Called /establish"
	    Session establish	;# this makes this session persist
	    puts stderr "Called Session establish"
	    return [Http NoCache [Http Ok $r [<p> "ESTABLISHED"]]]
	}

	proc /unset {r} {
	    Session variable counter
	    unset counter

	    Session variable session
	    return [Http NoCache [Http Ok $r [<p> "unset counter in $session"]]]
	}

	proc /badtime/1 {r} {
	    Session variable session
	    catch {unset session} e eo
	    return [Http NoCache [Http Ok $r [<p> "$session - if you unset the session variable, you will have a bad time, but you won't know it."]]]
	}

	proc /badtime/2 {r} {
	    Session variable session
	    catch {set session 1} e eo
	    return [Http NoCache [Http Ok $r [<p> "$session - $e"]]]
	}
    }

    # this goes in site.config
    /session/mgr/ {
	domain {Session test_sm}
	cpath /session/
	file test_session.db
	schema {
	    DROP TABLE IF EXISTS session;
	    CREATE TABLE session (
				  session VARCHAR(32) PRIMARY KEY,
				  counter INTEGER
				  );
	}
    }

    /session/ -session test_sm {
	domain Direct
	namespace ::TestSession
    }

    /session/code {
	# note, not under test_sm session manager, but is under domain, so will get the cookie
	# can interact with its session manager via [Session]
    }
}
