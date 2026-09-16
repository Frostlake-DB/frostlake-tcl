# frostlake-tcl

A [Tcl](https://www.tcl-lang.org/) driver for [Frostlake](https://frostlake.dev),
speaking the engine's HTTP protocol against a running `DatabaseHttpServer`.

Nothing outside the Tcl core is needed. The JSON reader, the DSN parser, the SQL
scanner and the HTTP client are all here; TclTLS is required only for an
`https://` DSN. Tcl 8.6 or newer.

```tcl
lappend auto_path /path/to/frostlake-tcl
package require frostlake

set conn [frostlake::connect frostlake://localhost:18082/MY_DB?schema=PUBLIC]

$conn execute {CREATE TABLE people (id INTEGER, name VARCHAR)}
$conn execute {INSERT INTO people VALUES (?, ?)} {1 Ada}

set res [$conn execute {SELECT name FROM people WHERE id = ?} {1}]
frostlake::result value $res          ;# Ada

$conn close
```

## What a result is

A result is a **plain Tcl dict**, not an object. It has no lifetime to manage:
store it, pass it, compare it, put it in a list. `dict get` is the whole reading
API, and the `frostlake::result` ensemble covers what `dict get` cannot.

| key | what it holds |
| --- | --- |
| `columns` | one dict per column: `name`, `datatype`, `nullable`, `precision`, `scale`, `length` |
| `rows` | a list of rows, each a list of cells aligned with `columns` |
| `updatecount` | rows affected by DML, or `-1` when the statement returned data |
| `counters` | the raw `number of rows ...` counters behind `updatecount` |

```tcl
set res [$conn execute {SELECT id, name FROM people ORDER BY id}]

dict get $res rows                      ;# {1 Ada} {2 Grace}
frostlake::result names $res            ;# ID NAME
frostlake::result value $res            ;# 1        -- first cell of first row
frostlake::result rowcount $res         ;# 2
frostlake::result dicts $res            ;# {ID 1 NAME Ada} {ID 2 NAME Grace}
frostlake::result cell $res 1 NAME      ;# Grace
frostlake::result column $res NAME      ;# name NAME datatype VARCHAR ...

foreach row [dict get $res rows] {
    lassign $row id name
    puts "$id is $name"
}
```

`length` is the declared width of a text or binary column -- characters for
`VARCHAR`, bytes for `BINARY`, and `16777216` for an unbounded one, which is the
most it could hold. Every other type has no width and reports `""`, as does a
field an older engine never sent; `0` is never invented for it.

`updatecount`, `isupdate` and `counters` read a DML answer. Frostlake reports DML
as a status grid (`number of rows inserted`), and the driver keeps that grid *and*
sums it:

```tcl
set res [$conn execute {DELETE FROM people WHERE id > 10}]
frostlake::result isupdate $res         ;# 1
frostlake::result updatecount $res      ;# 4
frostlake::result counters $res         ;# {number of rows deleted} 4
```

## Values are text, exactly as the engine wrote them

Tcl's every value is a string, so the driver does not convert cells on the way
back — the text the engine sent **is** the Tcl value. Nothing is rounded,
reformatted, or given a time zone it never had:

```tcl
set big [frostlake::result value [$conn execute {SELECT 12345678901234567890123456789}]]
expr {$big + 1}     ;# 12345678901234567890123456790 -- exact; Tcl 8.6 integers are arbitrary precision
```

| the engine's type | what you get |
| --- | --- |
| `NUMBER`, `FLOAT` | the digits as sent, at any width |
| `BOOLEAN` | `true` / `false` — both of which `expr` accepts as booleans |
| `DATE`, `TIME`, `TIMESTAMP*` | the engine's own text, e.g. `2024-01-15 10:30:00.000 +0100` |
| `BINARY` | upper-case hex, e.g. `AB0102` |
| `VARIANT`, `OBJECT`, `ARRAY` | the engine's JSON text |
| `NULL` | the connection's `-nullvalue` (default: the empty string) |

`frostlake::value` converts when you want it to, rather than behind your back:

```tcl
frostlake::value parsetimestamp {2024-01-15 10:30:00.5 +01:00}
#  seconds 1705311000 nanos 500000000 offset 3600
frostlake::value formattimestamp 1705311000 500000000 3600
#  2024-01-15 10:30:00.5 +01:00
frostlake::value hextobinary AB0102        ;# a 3-byte Tcl byte array
frostlake::value binarytohex $bytes        ;# AB0102
```

### NULL

Tcl has no null, so the connection names a stand-in — used in **both**
directions, so the same string means NULL coming back and going in:

```tcl
set conn [frostlake::connect $dsn -nullvalue "(null)"]
frostlake::result value [$conn execute {SELECT NULL}]     ;# the sentinel
$conn execute {INSERT INTO t VALUES (?)} [list "(null)"]   ;# inserts NULL
```

The default is the empty string, which is the convention TDBC uses and the right
one for most scripts. It does mean an empty string binds as NULL — pick a
sentinel if you need to store both.

## Parameters

The HTTP protocol has no server-side binding, so parameters are inlined as
literals by the driver, skipping anything inside a string, a quoted identifier,
a dollar-quoted body or a comment.

```tcl
$conn execute {INSERT INTO people VALUES (?, ?)} {1 Ada}
$conn execute {SELECT :a + :b AS total} {a 2 b 40}
```

Whether the parameters are read as a **list** (for `?`) or a **dict** (for
`:name`) is decided by the *statement*, not by the argument — in Tcl those are
the same value, so letting the statement decide is the only unambiguous reading.

### Types

Every bind is a **string literal** unless you say otherwise. That is the only
default that cannot silently change a value: the engine coerces freely in
expressions, so `WHERE id = '42'` finds the row with id 42, but a bare `007` is
the number seven and storing it in a `VARCHAR` gives back `7`.

Where SQL syntax needs a real numeric literal, `-types` says so:

```tcl
$conn execute {SELECT * FROM t LIMIT ?} 5 -types number
$conn execute {SELECT ?, ?, ?} {5 true abc} -types {number boolean string}
$conn execute {SELECT :n} {n 5} -types {n number}
```

One type applies to every placeholder; a list applies one to one. The types are
`string` (default), `number`, `boolean`, `null`, `binary`, `date`, `time`,
`timestamp`, `timestampntz`, `timestamptz`, `variant`, and `raw` — which is
inserted verbatim and is therefore yours to make safe.

For an identifier assembled at runtime, quote it rather than reaching for `raw`:

```tcl
$conn execute "SELECT * FROM [frostlake::value identifier $table]"
```

`$conn render` shows what a bind produced, without sending it:

```tcl
$conn render {SELECT ?} [list "O'Reilly"]     ;# SELECT 'O''Reilly'
```

A statement given **no** parameters passes through untouched, so the server's own
`?` and `:name` — Snowflake Scripting variables, `OPEN ... USING` cursor
placeholders — still reach it.

## Transactions

```tcl
$conn transaction {
    $conn execute {INSERT INTO acc VALUES (1)}
    $conn execute {INSERT INTO acc VALUES (2)}
}
```

The script runs in the caller's scope between `BEGIN` and `COMMIT`, rolls back if
it fails, and re-raises the original error either way. `$conn begin`,
`$conn commit` and `$conn rollback` are there for hand-rolled control.

A transaction lives on the *session*, so anything else run on this same
connection meanwhile joins it. Give a transaction its own connection if that is
not what you want.

## Failures

Failures carry a Tcl `-errorcode`, which `try ... trap` matches by prefix:

```tcl
try {
    $conn execute $sql
} trap {FROSTLAKE QUERY} {message} {
    # the engine refused the statement; `message` is its own wording
} trap {FROSTLAKE CONNECTION} {message} {
    # the request never became an answer
} trap {FROSTLAKE USAGE} {message} {
    # the driver never sent it: a bad DSN, a closed connection, a bad bind
}
```

`trap {FROSTLAKE}` catches all three. Each code carries a third element, a dict
of detail — `endpoint` and `status` for a connection failure, `statement` and
`status` for a query failure:

```tcl
} trap {FROSTLAKE QUERY} {message options} {
    set detail [frostlake::detail [dict get $options -errorcode]]
    dict get $detail statement
}
```

A `CONNECTION` failure has an **unknown** fate: the request may have arrived and
run before the connection broke, so the driver never re-sends it, and neither
should you without checking.

> Binding is client-side, so the `statement` in a `QUERY` detail holds the SQL
> *after* substitution — a bound password appears in it verbatim. The message
> carries none of it, so log the message freely and treat the detail as
> sensitive.

## Connecting

```
frostlake://host[:port][/DATABASE][?param=value&...]
```

`http://` and `https://` are accepted too and mean the same thing. The default
port is 18082. The server authenticates nobody, so a DSN carrying credentials is
refused rather than having them silently dropped.

The server is contacted before `connect` returns: its health endpoint is called
and the DSN's scope is selected, so a database that does not exist is reported
there rather than surfacing later on whichever query happened to run first.

| DSN parameter | option | meaning |
| --- | --- | --- |
| `schema` `role` `warehouse` | `-schema` `-role` `-warehouse` | the session's scope |
| | `-database` | the database, if not in the path |
| `timeout` | `-timeout` | how long one statement may take (default 300s) |
| `connectTimeout` | `-connecttimeout` | how long to wait for the socket (default 10s) |
| `idleLimit` | `-idlelimit` | how long a connection may idle before its scope is re-applied (default 30m) |
| `tls` | | speak HTTPS over a `frostlake://` DSN |
| | `-nullvalue` | the stand-in for SQL NULL (default `""`) |
| | `-cacert` `-verify` | HTTPS trust settings |

Durations are written `30s`, `500ms`, `5m`, `1h`, or as a bare number of
seconds; `0` removes the bound. An explicit option outranks the DSN.

`-idlelimit` exists because the engine reclaims an idle session and then quietly
builds a fresh one for the id the driver keeps sending — losing the scope it
selected, with nothing in the reply to give it away. Past the limit the driver
re-applies the DSN's scope. It does not do so once you have selected a scope
yourself, because putting its defaults over your choice would be its own
surprise.

### One socket per connection

A connection opens **one** socket and keeps it for its whole life; every
statement rides it. This matters more than it sounds: a driver that opens a
socket per statement burns an ephemeral TCP port per statement, and a few
thousand statements will exhaust a machine's port range and start failing
connections that have nothing to do with the query.

If the far side closes an idle keep-alive socket, the driver notices *before*
writing and opens a fresh one. It never re-sends a statement it has already
written — a torn connection is reported, not retried, because a re-sent `INSERT`
inserts twice.

The socket is non-blocking and the event loop does the waiting, so `-timeout`
bounds the whole exchange rather than any one read. An application with its own
file events will see them fire while a statement is in flight — the same bargain
Tcl's core `http` package makes.

## Other commands

```tcl
$conn executeall {SELECT 1; SELECT 2}   ;# every result set, in order
$conn ping                              ;# is an engine still answering?
$conn sessionid                         ;# the engine's id for this session
$conn intransaction                     ;# is a transaction open?
$conn baseurl                           ;# scheme://host:port
$conn config                            ;# the parsed DSN, as a dict
$conn timeout ?duration?                ;# read or move the per-statement bound
$conn applyscope                        ;# re-select the DSN's scope
$conn close                             ;# release the socket, remove the command
```

`execute` returns the first result set; `executeall` returns them all. A
statement that returns no grid at all — DDL, a bare `USE` — still answers with
one empty result, so `execute` always has something to hand back.

### Several statements in one request

The engine refuses a request holding more statements than it was told to expect.
`-multistatementcount` says how many this one request holds:

```tcl
$conn executeall {SELECT 1; SELECT 2} -multistatementcount 2
```

`0` means any number. The count travels with that one request and outranks the
session's `MULTI_STATEMENT_COUNT` without changing it, so nothing has to be saved
and put back, and two connections sharing nothing but the server cannot disturb
each other. Leave the option out and no count is sent at all — the session's
value decides, exactly as before.

`frostlake::json`, `frostlake::dsn`, `frostlake::sql` and `frostlake::bind` are
the driver's own parts, usable on their own if you have a reason to.

## TDBC

`tdbc::frostlake` is a [TDBC](https://core.tcl-lang.org/tdbc/) driver built on
the same connection, so code written against Tcl's standard database interface
runs unchanged. It needs the `tdbc` package, which ships with Tcl's source
distribution and is packaged separately on some systems (Debian:
`tcl8.6-tdbc`). It is modelled on `tdbc::sqlite3`, the pure-Tcl driver that
comes with TDBC.

```tcl
package require tdbc::frostlake

tdbc::frostlake::connection create db frostlake://localhost:18082/MY_DB?schema=PUBLIC

db allrows {CREATE TABLE people (id INTEGER, name VARCHAR)}
db allrows {INSERT INTO people VALUES (:id, :name)} {id 1 name Ada}

set id 1
db foreach row {SELECT name FROM people WHERE id = :id} {
    puts [dict get $row NAME]
}

db transaction {
    db allrows {INSERT INTO people VALUES (:id, :name)} {id 2 name Grace}
}
db close
```

It keeps TDBC's contract rather than the native API's:

- A bound variable is `:name`, read from the dictionary argument or, without
  one, from the caller's variables. A missing one is NULL, which is how TDBC
  binds a NULL; an empty string is a string.
- A NULL comes back as an empty string in a list row and as an absent key in
  a dict row.
- An INSERT, UPDATE, DELETE or MERGE answers no columns and a `rowcount`. The
  native API keeps the status grid those statements answer with.
- Failures carry TDBC's `-errorcode`, `TDBC class sqlstate FROSTLAKE ...`. The
  HTTP protocol has no SQLSTATE, so a refused statement is
  `GENERAL_ERROR HY000`. The native kind and detail dict follow the driver
  name, so `lindex $::errorCode 5` holds a refused statement's text.

Where TDBC's conventions would rewrite valid Snowflake SQL, the SQL wins. TDBC's
tokenizer also reads `$name` and `@name` as variables, but here they are session
variables and stage references, so they reach the engine as written. So do `?`,
`::` casts, `v:field` paths and `$$` bodies.

A `:name` inside a bare `BEGIN ... END` block is still a TDBC variable, so a
Scripting block that reads its own variables that way gets NULL. Wrap the block
in `EXECUTE IMMEDIATE $$ ... $$`, whose body the driver leaves alone, or run it
through the native API, which leaves `:name` to the server when it is given no
parameters.

| option | meaning |
| --- | --- |
| `-timeout ms` | how long one statement may take, in milliseconds as TDBC has it |
| `-isolation` | `readcommitted`, the only level Frostlake has; `readuncommitted` is raised to it and anything stronger is refused |
| `-readonly` | `0` only |
| `-encoding` | `utf-8` only |

The native connect options (`-schema`, `-connecttimeout` and the rest) are
accepted when the connection is created, and `db getDBhandle` hands over the
native connection itself.

`$stmt paramtype name integer`, or any other TDBC type, writes that variable
as a bare numeral or a typed literal. Undeclared, a value is a string literal,
which the engine coerces. `db preparecall {res = myproc(:a)}` runs
`CALL myproc(...)` and reports the result through the result set's
`outputparams`.

`tables`, `columns`, `primarykeys` and `foreignkeys` look in the current
schema. A table name is read the way the engine resolves one: as written if a
table has exactly that name, otherwise upper-cased, so `people` finds `PEOPLE`.

`db begintransaction` refuses to nest, because Frostlake does not nest
transactions, and closing a connection rolls back whatever it left open.

## Tests

```bash
tclsh tests/all.tcl
```

runs the unit tests — the JSON reader, DSN parsing, the SQL scanner, binding,
value helpers, results, and the transport against an in-process server that can
be made to chunk a body, close a keep-alive socket, answer something that is not
JSON, or never answer at all. The TDBC driver's cases need the `tdbc` package
too, and skip without it.

The engine-backed tests need a real engine:

```bash
JAVA_HOME=/path/to/jdk FROSTLAKE_CLASSPATH='/path/to/engine/lib/*' tclsh tests/all.tcl
```

Without `FROSTLAKE_CLASSPATH` those cases skip rather than passing on a stub.

tcltest's own options work too: `tclsh tests/all.tcl -file binding.test`,
`-match bind-3.*`.

## Layout

The package files sit at the top of the repository, so the directory is itself a
package directory: dropping it into any directory on `auto_path` is enough, and
`tests/` and `examples/` beside them carry no `pkgIndex.tcl` and are never
scanned.

```
pkgIndex.tcl      what `package require` reads first
frostlake.tcl     the package: sources the parts below, in dependency order
errors.tcl        the three failure kinds, and the -errorcode they carry
json.tcl          a JSON reader that keeps every number's digits and every value's type
dsn.tcl           frostlake://host:port/DB?params -> a config dict
sql.tcl           the scanner both binding and scope-tracking read
values.tcl        Tcl values -> SQL literals, and the engine's text back again
binding.tcl       ? and :name placeholders, inlined client-side
result.tcl        what a statement answered with, as a plain dict
http.tcl          one keep-alive socket, with the caller's deadline on it
connection.tcl    the object that owns a socket and an engine session
tdbcfrostlake.tcl tdbc::frostlake, the TDBC driver over that object
```

## Licence

Apache-2.0. See [LICENSE](LICENSE).
