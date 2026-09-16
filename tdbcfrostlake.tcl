# A TDBC driver for Frostlake: TDBC's connection, statement and result set
# classes over the frostlake package's HTTP connection.
#
#     package require tdbc::frostlake
#     tdbc::frostlake::connection create db frostlake://localhost:18082/MY_DB
#     db allrows {SELECT name FROM people WHERE id = :id} {id 1}
#     db close
#
# Modelled on tdbc::sqlite3, the pure-Tcl driver that ships with TDBC: the
# connection forwards statementCreate to the statement class, the statement
# forwards resultSetCreate to the result set class, and TDBC's base classes
# supply prepare, allrows, foreach, transaction and the rest.
#
# Where TDBC's conventions and Snowflake SQL disagree, the SQL wins, because a
# driver that rewrites valid SQL behind the caller's back is worse than one
# that asks for a different spelling:
#
#  * Only `:name` is a bound variable. TDBC's tokenizer also takes `$name` and
#    `@name`, but in Snowflake SQL `$name` reads a session variable and `@name`
#    names a stage, so both reach the engine untouched. So does `?`, which only
#    a Scripting cursor uses, and every colon that is a cast (`::`), an
#    assignment (`:=`), a path step (`v:field`) or a positional reference
#    (`:1`). The scanner is the frostlake package's own, which also knows the
#    backslash escapes and `$$` bodies that TDBC's tokenizer does not.
#  * Values are inlined as literals, because the HTTP protocol has no
#    server-side binding.
#
# Everything else is TDBC's contract as written: a variable that is not bound
# is NULL, a NULL is an empty string in a list row and an absent key in a dict
# row, and a DML statement answers with no columns and a rowcount.
#
# The one place that contract bites Snowflake SQL: a `:name` inside a bare
# BEGIN ... END block is a TDBC variable too, so a Scripting block that reads
# its own variables that way belongs inside EXECUTE IMMEDIATE $$ ... $$.

package require Tcl 8.6
package require tdbc 1.0
package require frostlake 0.2.0

package provide tdbc::frostlake 0.2.0

namespace eval ::tdbc::frostlake {
    namespace export connection

    # What the native connection is told to hand back for SQL NULL.
    # tdbc::sqlite3 uses a lone U+FFFD for the same purpose; the process id and
    # a clock reading make this one unguessable, so no stored value -- not even
    # one written to look like the stand-in -- can read back as NULL.
    variable NULL "\ufffdNULL:[pid]:[clock clicks]\ufffd"

    # TDBC's parameter types, and the native literal each one is rendered as.
    variable LITERALS {
        bigint number  decimal number  double number  float number
        integer number  numeric number  real number  smallint number
        tinyint number  bit boolean  char string  varchar string
        longvarchar string  binary binary  varbinary binary
        longvarbinary binary  date date  time time  timestamp timestamp
    }

    # TDBC's own connection options, then the native connection's, which keep
    # their native spelling and may only be given at connect time.
    variable TDBC_OPTIONS {-encoding -isolation -readonly -timeout}
    variable NATIVE_OPTIONS {
        -cacert -connecttimeout -database -idlelimit -role -schema -verify
        -warehouse
    }
}

# Raises a failure the way TDBC spells one, `TDBC class sqlstate FROSTLAKE
# detail...`, with the class taken from TDBC's own SQLSTATE table.
proc ::tdbc::frostlake::Fail {sqlstate detail message} {
    return -code error -errorcode [list TDBC [::tdbc::mapSqlState $sqlstate] \
                                       $sqlstate FROSTLAKE {*}$detail] $message
}

# Runs a native command, turning its failure into a TDBC one. The native kind
# and detail dict ride along after the driver name, so `lindex $::errorCode 5`
# still reaches a refused statement's text.
#
# The HTTP protocol carries no SQLSTATE, so a refused statement is HY000. A
# transport failure reports `connectionState`: 08001 while the connection is
# being made, 08006 once it is up.
proc ::tdbc::frostlake::Call {connectionState args} {
    try {
        return [uplevel 1 $args]
    } trap {FROSTLAKE} {message options} {
        lassign [dict get $options -errorcode] - kind detail
        set sqlstate HY000
        if {$kind eq "CONNECTION"} { set sqlstate $connectionState }
        Fail $sqlstate [list $kind $detail] $message
    }
}

# One option name, completed the way Tcl completes any unique prefix.
proc ::tdbc::frostlake::Option {option choices} {
    if {[catch {::tcl::prefix match -message option $choices $option} full]} {
        Fail HY000 [list BADOPTION $option] $full
    }
    return $full
}

# Checks one of TDBC's options and answers its value normalised. Nothing is
# sent: -encoding, -isolation and -readonly each have only one value that can
# be honoured here, so checking them is the whole of applying them.
proc ::tdbc::frostlake::Setting {option value} {
    switch -- $option {
        -encoding {
            if {[string tolower $value] ni {utf-8 utf8}} {
                Fail 0A000 [list ENCODING $value] "-encoding cannot be\
                    \"$value\": the engine speaks JSON, which is always UTF-8"
            }
            return utf-8
        }
        -isolation {
            if {[catch {::tcl::prefix match -message "isolation level" {
                readuncommitted readcommitted repeatableread serializable
                readonly
            } $value} level]} {
                Fail HY000 [list BADISOLATION $value] $level
            }
            # TDBC replaces a level the database lacks with the next stronger
            # one, and refuses a level that cannot be had. Frostlake isolates
            # at read committed, as Snowflake does, and at nothing stronger.
            if {$level ni {readuncommitted readcommitted}} {
                Fail 0A000 [list ISOLATION $level] "isolation level \"$level\"\
                    cannot be had: Frostlake isolates transactions at\
                    readcommitted, as Snowflake does"
            }
            return readcommitted
        }
        -readonly {
            if {![string is boolean -strict $value]} {
                Fail 22018 [list READONLY $value] \
                    "expected boolean but got \"$value\""
            }
            if {$value} {
                Fail 0A000 {READONLY} "Frostlake has no read-only connections"
            }
            return 0
        }
        -timeout {
            # Digits only, and read as decimal: `expr` takes 08 for octal.
            if {![regexp {^[0-9]+$} $value]} {
                Fail 22018 [list TIMEOUT $value] "expected a whole number of\
                    milliseconds but got \"$value\""
            }
            set ms [string trimleft $value 0]
            if {$ms eq ""} { return 0 }
            return $ms
        }
    }
}

# Renders one bound value as the literal the native renderer writes for its
# TDBC type.
#
# The native renderer reads a value equal to its NULL stand-in as NULL. TDBC
# signals NULL by absence alone -- a value that is present is data, whatever
# it holds -- so the renderer is handed a stand-in no value can equal: the
# value itself, one character longer.
proc ::tdbc::frostlake::Literal {value type} {
    variable LITERALS
    try {
        return [::frostlake::value::literal $value [dict get $LITERALS $type] \
                    "$value\x00"]
    } trap {FROSTLAKE USAGE} {message} {
        Fail 22018 [list BADVALUE $type] $message
    }
}

# Copies the fields of a SHOW row into the names TDBC gives them. A NULL was
# never in the row, so it stays absent, which is how TDBC reports one.
proc ::tdbc::frostlake::Rename {row pairs} {
    set out [dict create]
    foreach {from to} $pairs {
        if {[dict exists $row $from]} { dict set out $to [dict get $row $from] }
    }
    return $out
}

# The TDBC name for a type as INFORMATION_SCHEMA spells it. Every timestamp
# flavour is TDBC's one `timestamp`; a type TDBC has no name for keeps its
# own, lower-cased, as the TDBC manual allows.
proc ::tdbc::frostlake::TypeName {datatype} {
    switch -- [string toupper $datatype] {
        NUMBER    { return decimal }
        FLOAT     { return double }
        TEXT      { return varchar }
        BOOLEAN   { return bit }
        DATE      { return date }
        TIME      { return time }
        BINARY    { return varbinary }
        TIMESTAMP_NTZ - TIMESTAMP_LTZ - TIMESTAMP_TZ { return timestamp }
    }
    return [string tolower $datatype]
}

# The values of `keys` in a row, with "" for any the row does not carry.
proc ::tdbc::frostlake::Fields {row keys} {
    set out {}
    foreach key $keys {
        if {[dict exists $row $key]} {
            lappend out [dict get $row $key]
        } else {
            lappend out ""
        }
    }
    return $out
}

# Orders key rows the way TDBC's own INFORMATION_SCHEMA query does: by the
# constraint's identity, then by position within the constraint.
proc ::tdbc::frostlake::Ordered {rows identity} {
    set keyed {}
    foreach row $rows {
        lappend keyed [list [Fields $row $identity] \
                           [dict get $row ordinalPosition] $row]
    }
    set out {}
    foreach entry [lsort -index 0 [lsort -integer -index 1 $keyed]] {
        lappend out [lindex $entry 2]
    }
    return $out
}

# ------------------------------------------------------------------ connection

# A connection to a Frostlake HTTP server, and the engine session behind it.
#
#     tdbc::frostlake::connection create db DSN ?-option value ...?
#
# The DSN is the native package's, frostlake://host[:port][/DATABASE][?...].
# The options are TDBC's -encoding, -isolation, -readonly and -timeout (in
# milliseconds, as TDBC has it), and the native connection's -connecttimeout,
# -idlelimit, -database, -schema, -role, -warehouse, -cacert and -verify.
::oo::class create ::tdbc::frostlake::connection {

    superclass ::tdbc::connection

    # The native frostlake connection this one drives.
    variable Db

    constructor {dsn args} {
        variable ::tdbc::frostlake::NULL
        variable ::tdbc::frostlake::TDBC_OPTIONS
        variable ::tdbc::frostlake::NATIVE_OPTIONS
        next
        if {[llength $args] % 2} {
            ::tdbc::frostlake::Fail HY000 {WRONGNUMARGS} "wrong # args: should\
                be \"tdbc::frostlake::connection create name dsn\
                ?-option value?...\""
        }
        # Every option is checked before the server is contacted, so a
        # connection that could not honour its options is never opened.
        set native [list -nullvalue $NULL]
        set choices [lsort [concat $TDBC_OPTIONS $NATIVE_OPTIONS]]
        foreach {option value} $args {
            set option [::tdbc::frostlake::Option $option $choices]
            if {$option in $NATIVE_OPTIONS} {
                lappend native $option $value
            } elseif {$option eq "-timeout"} {
                lappend native -timeout \
                    "[::tdbc::frostlake::Setting -timeout $value]ms"
            } else {
                ::tdbc::frostlake::Setting $option $value
            }
        }
        set Db [::tdbc::frostlake::Call 08001 \
                    ::frostlake::connect $dsn {*}$native]
    }

    # TDBC rolls back what a closing connection left open. The engine would
    # otherwise hold that transaction until its idle sweep took the session.
    destructor {
        if {![info exists Db]} { return }
        if {![catch {$Db intransaction} open] && $open} {
            catch {$Db rollback}
        }
        catch {$Db close}
    }

    forward statementCreate ::tdbc::frostlake::statement create

    # The native connection, for anything TDBC has no word for.
    method getDBhandle {} {
        return $Db
    }

    # Queries or sets TDBC's options. Only -timeout holds any state: the other
    # three each have one value that can be honoured, and any other is refused.
    method configure {args} {
        variable ::tdbc::frostlake::TDBC_OPTIONS
        if {![llength $args]} {
            return [list -encoding utf-8 -isolation readcommitted -readonly 0 \
                         -timeout [$Db timeout]]
        }
        if {[llength $args] == 1} {
            set option [::tdbc::frostlake::Option [lindex $args 0] $TDBC_OPTIONS]
            return [dict get [my configure] $option]
        }
        if {[llength $args] % 2} {
            ::tdbc::frostlake::Fail HY000 {WRONGNUMARGS} "wrong # args: should\
                be \"[self] configure ?-option value?...\""
        }
        # Every pair is checked before any is applied, so a bad one leaves the
        # connection as it was.
        set settings {}
        foreach {option value} $args {
            set option [::tdbc::frostlake::Option $option $TDBC_OPTIONS]
            lappend settings $option [::tdbc::frostlake::Setting $option $value]
        }
        if {[dict exists $settings -timeout]} {
            $Db timeout "[dict get $settings -timeout]ms"
        }
        return
    }

    # --------------------------------------------------------- transactions

    # TDBC refuses a second begintransaction unless the database nests
    # transactions. Snowflake does not, and the engine accepts a BEGIN inside a
    # transaction without complaint, so a second one here would silently join
    # the first.
    method begintransaction {} {
        if {[$Db intransaction]} {
            ::tdbc::frostlake::Fail 25001 {NESTED} "a transaction is already\
                open on this connection, and Frostlake does not nest them"
        }
        ::tdbc::frostlake::Call 08006 $Db begin
        return
    }

    method commit {} {
        ::tdbc::frostlake::Call 08006 $Db commit
        return
    }

    method rollback {} {
        ::tdbc::frostlake::Call 08006 $Db rollback
        return
    }

    # Prepares `?resultvar =? procname(?arg, ...?)` as a CALL. The arguments
    # are bound like any statement's; the result variable is an output
    # parameter, answered by the result set's `outputparams`.
    method preparecall {call} {
        my variable statementSeq
        if {![regexp {^\s*(?::?([A-Za-z_][A-Za-z0-9_]*)\s*=)?\s*([^=(]+\(.*\))\s*;?\s*$} \
                  $call -> result body]} {
            ::tdbc::frostlake::Fail 42000 {BADCALL} "a call must read\
                \"?resultvar =? procname(?arg, ...?)\", got \"$call\""
        }
        return [my statementCreate Stmt::[incr statementSeq] [self] \
                    "CALL [string trim $body]" $result]
    }

    # -------------------------------------------------------- introspection
    #
    # All four look in the current schema and read a table name the way the
    # engine resolves one: as written when a table has exactly that name, and
    # otherwise upper-cased, the way an unquoted identifier folds. So `people`
    # finds PEOPLE, and a table created as "people" is still reachable.

    # The tables and views whose names match `pattern`, a LIKE pattern matched
    # regardless of case, as SHOW TABLES LIKE matches.
    method tables {{pattern %}} {
        set out [dict create]
        foreach row [my allrows {
            SELECT TABLE_CATALOG AS "tableCatalog",
                   TABLE_SCHEMA AS "tableSchema",
                   TABLE_NAME AS "tableName",
                   TABLE_TYPE AS "tableType",
                   COMMENT AS "comment"
            FROM INFORMATION_SCHEMA.TABLES
            WHERE TABLE_SCHEMA = CURRENT_SCHEMA() AND TABLE_NAME ILIKE :pattern
            ORDER BY TABLE_NAME
        } [dict create pattern $pattern]] {
            dict set out [dict get $row tableName] $row
        }
        return $out
    }

    # The columns of one table whose names match `pattern`, in table order.
    # Each carries TDBC's type, precision, scale and nullable, plus `name` and
    # the engine's own `datatype`, which TDBC's type names flatten.
    method columns {table {pattern %}} {
        set where [my ResolveTable $table]
        if {![llength $where]} { return {} }
        set out [dict create]
        foreach row [my allrows -as lists {
            SELECT COLUMN_NAME, DATA_TYPE, NUMERIC_PRECISION, NUMERIC_SCALE,
                   CHARACTER_MAXIMUM_LENGTH, IS_NULLABLE
            FROM INFORMATION_SCHEMA.COLUMNS
            WHERE TABLE_SCHEMA = :schema AND TABLE_NAME = :name
              AND COLUMN_NAME ILIKE :pattern
            ORDER BY ORDINAL_POSITION
        } [dict create schema [lindex $where 1] name [lindex $where 2] \
               pattern $pattern]] {
            lassign $row name datatype precision scale length nullable
            # A string or binary column's width is its precision, in TDBC.
            if {$precision eq ""} { set precision $length }
            if {$precision eq ""} { set precision 0 }
            if {$scale eq ""} { set scale 0 }
            dict set out $name [dict create name $name \
                type [::tdbc::frostlake::TypeName $datatype] \
                precision $precision scale $scale \
                nullable [expr {$nullable eq "YES"}] datatype $datatype]
        }
        return $out
    }

    method primarykeys {table} {
        set where [my ResolveTable $table]
        if {![llength $where]} { return {} }
        set keys {}
        foreach row [my allrows \
                         "SHOW PRIMARY KEYS IN TABLE [my Qualified $where]"] {
            lappend keys [::tdbc::frostlake::Rename $row {
                database_name tableCatalog   schema_name tableSchema
                table_name tableName         database_name constraintCatalog
                schema_name constraintSchema constraint_name constraintName
                column_name columnName       key_sequence ordinalPosition
            }]
        }
        return [::tdbc::frostlake::Ordered $keys \
                    {constraintCatalog constraintSchema constraintName}]
    }

    # The foreign keys declared on the table named by -foreign, those that
    # refer to the table named by -primary, or both; with neither, every
    # foreign key in the current database.
    method foreignkeys {args} {
        if {[llength $args] % 2} {
            ::tdbc::frostlake::Fail HY000 {WRONGNUMARGS} "wrong # args: should\
                be \"[self] foreignkeys ?-primary table? ?-foreign table?\""
        }
        set wanted [dict create]
        foreach {option value} $args {
            if {$option ni {-primary -foreign}} {
                ::tdbc::frostlake::Fail HY000 [list BADOPTION $option] \
                    "bad option \"$option\": must be -primary or -foreign"
            }
            if {[dict exists $wanted $option]} {
                ::tdbc::frostlake::Fail HY000 [list DUPOPTION $option] \
                    "duplicate option \"$option\" supplied"
            }
            dict set wanted $option [my ResolveTable $value]
            if {![llength [dict get $wanted $option]]} { return {} }
        }
        set scope "IN DATABASE"
        if {[dict exists $wanted -foreign]} {
            set scope "IN TABLE [my Qualified [dict get $wanted -foreign]]"
        }
        set keys {}
        foreach row [my allrows "SHOW IMPORTED KEYS $scope"] {
            set key [::tdbc::frostlake::Rename $row {
                fk_database_name foreignConstraintCatalog
                fk_schema_name foreignConstraintSchema
                fk_name foreignConstraintName
                pk_database_name primaryConstraintCatalog
                pk_schema_name primaryConstraintSchema
                pk_name primaryConstraintName
                update_rule updateAction  delete_rule deleteAction
                pk_database_name primaryCatalog  pk_schema_name primarySchema
                pk_table_name primaryTable  pk_column_name primaryColumn
                fk_database_name foreignCatalog  fk_schema_name foreignSchema
                fk_table_name foreignTable  fk_column_name foreignColumn
                key_sequence ordinalPosition
            }]
            if {[dict exists $wanted -primary]
                && [::tdbc::frostlake::Fields $key \
                        {primaryCatalog primarySchema primaryTable}]
                   ne [dict get $wanted -primary]} {
                continue
            }
            lappend keys $key
        }
        return [::tdbc::frostlake::Ordered $keys {
            foreignConstraintCatalog foreignConstraintSchema
            foreignConstraintName
        }]
    }

    # A table of the current schema, found by name: its catalog, schema and
    # name, or nothing when there is no such table.
    method ResolveTable {table} {
        set found [my allrows -as lists {
            SELECT TABLE_CATALOG, TABLE_SCHEMA, TABLE_NAME
            FROM INFORMATION_SCHEMA.TABLES
            WHERE TABLE_SCHEMA = CURRENT_SCHEMA()
              AND TABLE_NAME IN (:table, UPPER(:table))
        } [dict create table $table]]
        foreach wanted [list $table [string toupper $table]] {
            foreach row $found {
                if {[lindex $row 2] eq $wanted} { return $row }
            }
        }
        return {}
    }

    # A resolved table as a fully quoted name, for a SHOW statement.
    method Qualified {where} {
        set parts {}
        foreach part $where {
            lappend parts [::frostlake::value::identifier $part]
        }
        return [join $parts .]
    }
}

# TDBC's description of a parameter the driver has not been told the type of:
# a string, bound as a string literal.
proc ::tdbc::frostlake::Param {direction} {
    return [dict create direction $direction type varchar precision 0 \
                scale 0 nullable 1]
}

# ------------------------------------------------------------------- statement

# A prepared statement: the SQL as written, where its bound variables sit, and
# how each one is to be written into it.
::oo::class create ::tdbc::frostlake::statement {

    superclass ::tdbc::statement

    # The native connection, the SQL, each bound variable's {start stop name}
    # span in it, and TDBC's description of every parameter.
    variable Db Sql Sites Params

    # `output` names a call's result variable, for a statement prepared by
    # preparecall.
    constructor {connection sql {output ""}} {
        next
        set Db [$connection getDBhandle]
        set Sql $sql
        set Sites {}
        set Params [dict create]
        if {$output ne ""} {
            dict set Params $output [::tdbc::frostlake::Param out]
        }
        foreach site [::frostlake::bind::sites $sql] {
            lassign $site start stop name
            # A `?` is the server's: only a Scripting cursor uses one.
            if {$name eq ""} { continue }
            # The scanner folds a name to upper case; TDBC binds a Tcl
            # variable, whose name keeps the case it was written in.
            set name [string range $sql [expr {$start + 1}] [expr {$stop - 1}]]
            lappend Sites [list $start $stop $name]
            if {![dict exists $Params $name]} {
                dict set Params $name [::tdbc::frostlake::Param in]
            }
        }
    }

    forward resultSetCreate ::tdbc::frostlake::resultset create

    method params {} {
        return $Params
    }

    # `paramtype name ?direction? type ?precision? ?scale?` -- how a bound
    # value is written into the statement. A numeric type is what makes a
    # value a bare numeral; undeclared, every value is a string literal, which
    # the engine coerces wherever a string may stand for its type.
    method paramtype {name args} {
        variable ::tdbc::frostlake::LITERALS
        if {![dict exists $Params $name]} {
            ::tdbc::frostlake::Fail HY000 [list BADPARAM $name] \
                "the statement has no parameter named \"$name\""
        }
        set direction [dict get $Params $name direction]
        if {[lindex $args 0] in {in out inout}} {
            if {[lindex $args 0] ne $direction} {
                ::tdbc::frostlake::Fail 0A000 [list DIRECTION [lindex $args 0]] \
                    "\"$name\" is an $direction parameter: the HTTP protocol\
                     has no output parameters beyond a call's result"
            }
            set args [lrange $args 1 end]
        }
        if {[llength $args] < 1 || [llength $args] > 3} {
            ::tdbc::frostlake::Fail HY000 {WRONGNUMARGS} "wrong # args: should\
                be \"[self] paramtype name ?direction? type ?precision? ?scale?\""
        }
        lassign $args type precision scale
        set type [string tolower $type]
        if {![dict exists $LITERALS $type]} {
            ::tdbc::frostlake::Fail HY000 [list BADTYPE $type] "unknown type\
                \"$type\": must be one of [join [lsort [dict keys $LITERALS]] {, }]"
        }
        foreach {key value} [list precision $precision scale $scale] {
            if {$value eq ""} { set value 0 }
            if {![string is integer -strict $value]} {
                ::tdbc::frostlake::Fail 22018 [list BADVALUE $key $value] \
                    "expected an integer $key but got \"$value\""
            }
            dict set Params $name $key $value
        }
        dict set Params $name type $type
        return
    }

    # The statement with every bound variable inlined, as it would be sent:
    # from `dictionary` if one is given, and otherwise from the caller's
    # variables. A variable with no value is NULL, as TDBC has it.
    #
    # Useful for logging, but like the native connection's `render` it holds
    # bound values verbatim, so a bound password appears in it in the clear.
    method render {args} {
        if {[llength $args] > 1} {
            ::tdbc::frostlake::Fail HY000 {WRONGNUMARGS} \
                "wrong # args: should be \"[self] render ?dictionary?\""
        }
        set out ""
        set cursor 0
        foreach site $Sites {
            lassign $site start stop name
            append out [string range $Sql $cursor [expr {$start - 1}]]
            if {[llength $args]} {
                set bound [dict exists [lindex $args 0] $name]
                if {$bound} { set value [dict get [lindex $args 0] $name] }
            } else {
                set bound [uplevel 1 [list info exists $name]]
                if {$bound} { set value [uplevel 1 [list set $name]] }
            }
            if {$bound} {
                append out [::tdbc::frostlake::Literal $value \
                                [dict get $Params $name type]]
            } else {
                append out NULL
            }
            set cursor $stop
        }
        append out [string range $Sql $cursor end]
        return $out
    }

    method getDBhandle {} {
        return $Db
    }

    method getSql {} {
        return $Sql
    }
}

# ------------------------------------------------------------------ result set

# What one execution answered: every result set the request produced, walked
# with nextresults.
::oo::class create ::tdbc::frostlake::resultset {

    superclass ::tdbc::resultset

    # The native results, the one being read, the next row within it, whether
    # nextresults has run off the end, and a call's output parameters.
    variable Results Index Cursor Exhausted Output

    constructor {statement args} {
        variable ::tdbc::frostlake::NULL
        next
        if {[llength $args] > 1} {
            ::tdbc::frostlake::Fail HY000 {WRONGNUMARGS} \
                "wrong # args: should be \"statement execute ?dictionary?\""
        }
        # Without a dictionary, TDBC reads bound variables in the scope that
        # called `execute`, which is the level this constructor runs for.
        if {[llength $args]} {
            set sql [$statement render [lindex $args 0]]
        } else {
            set sql [uplevel 1 [list $statement render]]
        }
        set Results [::tdbc::frostlake::Call 08006 \
                         [$statement getDBhandle] executeall $sql]
        set Index 0
        set Cursor 0
        set Exhausted 0
        # A call's result variable takes the one value a CALL answers with.
        set Output [dict create]
        dict for {name param} [$statement params] {
            if {[dict get $param direction] ne "out"} { continue }
            set rows [dict get [lindex $Results 0] rows]
            if {[llength $rows] && [lindex $rows 0 0] ne $NULL} {
                dict set Output $name [lindex $rows 0 0]
            }
        }
    }

    # The result being read. TDBC makes it an error to read on once
    # nextresults has answered 0.
    method Current {} {
        if {$Exhausted} {
            ::tdbc::frostlake::Fail HY010 {FUNCTIONSEQ} \
                "Function sequence error: result set is exhausted."
        }
        return [lindex $Results $Index]
    }

    # The rows TDBC sees. A DML statement answers a status grid, which TDBC
    # would not recognise as one -- it expects no columns and a rowcount -- so
    # the grid reads as empty here; the native result keeps it.
    method Rows {result} {
        if {[::frostlake::result isupdate $result]} { return {} }
        return [dict get $result rows]
    }

    method columns {} {
        set result [my Current]
        if {[::frostlake::result isupdate $result]} { return {} }
        return [::frostlake::result names $result]
    }

    # Rows affected by DML, and -1 for a statement that answered with data,
    # whose count TDBC leaves unspecified.
    method rowcount {} {
        return [::frostlake::result updatecount [my Current]]
    }

    method nextlist {varName} {
        variable ::tdbc::frostlake::NULL
        upvar 1 $varName row
        set rows [my Rows [my Current]]
        if {$Cursor >= [llength $rows]} { return 0 }
        set row {}
        foreach cell [lindex $rows $Cursor] {
            if {$cell eq $NULL} {
                lappend row {}
            } else {
                lappend row $cell
            }
        }
        incr Cursor
        return 1
    }

    method nextdict {varName} {
        variable ::tdbc::frostlake::NULL
        upvar 1 $varName row
        set result [my Current]
        set rows [my Rows $result]
        if {$Cursor >= [llength $rows]} { return 0 }
        set row [dict create]
        foreach name [::frostlake::result names $result] \
                cell [lindex $rows $Cursor] {
            if {$cell ne $NULL} { dict set row $name $cell }
        }
        incr Cursor
        return 1
    }

    # Moves to the next result set of a request that produced several.
    method nextresults {} {
        if {!$Exhausted && $Index + 1 < [llength $Results]} {
            incr Index
            set Cursor 0
            return 1
        }
        set Exhausted 1
        return 0
    }

    method outputparams {} {
        return $Output
    }
}
