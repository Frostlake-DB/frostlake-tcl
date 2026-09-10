# A JSON reader and the encoding helpers the request payload needs.
#
# Tcl ships no JSON parser -- `json` lives in Tcllib, which is a separate
# install -- so the driver carries its own and stays dependency-free. Owning it
# buys two things the driver actually needs:
#
#  * Numbers keep their source text. A NUMBER(38,0) holds values no IEEE double
#    can name, and `expr {$cell}` on the literal digits is exact in Tcl 8.6,
#    whose integers are arbitrary precision. Reading through a double first
#    would round the value away before anyone saw it.
#  * Every value is tagged with its JSON type. Tcl represents everything as a
#    string, so a decoded `null`, the string "null", `false` and the string
#    "false" would otherwise be one and the same -- and the driver has to tell a
#    SQL NULL from the four characters n-u-l-l.
#
# A decoded value is a two-element list, {TYPE PAYLOAD}:
#
#     null      {null {}}
#     boolean   {bool 1}          {bool 0}
#     number    {number 1.500}    -- the literal text, unrounded
#     string    {string {some text}}
#     array     {array {V1 V2 ...}}      -- a list of tagged values
#     object    {object {K1 V1 K2 V2}}   -- a dict of key -> tagged value
#
# Objects keep their key order, so a re-encoded object reads back the way it
# arrived.

namespace eval ::frostlake::json {
    namespace export parse type value exists at index size keys \
        scalar text encode encode_string
    namespace ensemble create
}

# A cached regular expression per token kind. Scanning with `regexp -start`
# rather than one `string index` per character is what keeps parsing 685 suite
# files off the critical path.
namespace eval ::frostlake::json {
    variable RE_SPACE  {\A[ \t\n\r]+}
    variable RE_NUMBER {\A-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][-+]?[0-9]+)?}
    # The span of a string that needs no unescaping: anything up to the first
    # backslash or closing quote.
    variable RE_PLAIN  {\A[^"\\]+}
}

# ---------------------------------------------------------------- decoding

# Parses one JSON document. Throws a FROSTLAKE JSON error naming the offset
# when the text is not JSON -- the offset is the difference between "malformed"
# and knowing which byte to look at.
proc ::frostlake::json::parse {text} {
    set i 0
    set result [ParseValue $text i]
    SkipSpace $text i
    if {$i < [string length $text]} {
        Fail $text $i "unexpected trailing text"
    }
    return $result
}

proc ::frostlake::json::Fail {text i what} {
    set near [string range $text $i [expr {$i + 30}]]
    return -code error -errorcode [list FROSTLAKE JSON] \
        "invalid JSON at offset $i: $what (near \"$near\")"
}

proc ::frostlake::json::SkipSpace {text iVar} {
    variable RE_SPACE
    upvar 1 $iVar i
    if {[regexp -start $i -indices $RE_SPACE $text span]} {
        set i [expr {[lindex $span 1] + 1}]
    }
}

proc ::frostlake::json::ParseValue {text iVar} {
    variable RE_NUMBER
    upvar 1 $iVar i
    SkipSpace $text i
    set c [string index $text $i]
    switch -- $c {
        "\"" { return [list string [ParseString $text i]] }
        "\{" { return [ParseObject $text i] }
        "\[" { return [ParseArray $text i] }
        "t" {
            if {[string range $text $i [expr {$i + 3}]] ne "true"} {
                Fail $text $i "expected a value"
            }
            incr i 4
            return {bool 1}
        }
        "f" {
            if {[string range $text $i [expr {$i + 4}]] ne "false"} {
                Fail $text $i "expected a value"
            }
            incr i 5
            return {bool 0}
        }
        "n" {
            if {[string range $text $i [expr {$i + 3}]] ne "null"} {
                Fail $text $i "expected a value"
            }
            incr i 4
            return {null {}}
        }
        "" { Fail $text $i "the document ended early" }
    }
    if {[regexp -start $i -indices $RE_NUMBER $text span]} {
        lassign $span from to
        # `regexp -start` anchors \A at the start offset, so a match here always
        # begins at $i.
        set i [expr {$to + 1}]
        return [list number [string range $text $from $to]]
    }
    Fail $text $i "expected a value"
}

# Reads a string literal, unescaping it. The common case -- no backslash at all
# -- is copied in one slice rather than a character at a time.
proc ::frostlake::json::ParseString {text iVar} {
    variable RE_PLAIN
    upvar 1 $iVar i
    incr i ;# past the opening quote
    set out ""
    set n [string length $text]
    while {1} {
        if {$i >= $n} { Fail $text $i "the string is not closed" }
        if {[regexp -start $i -indices $RE_PLAIN $text span]} {
            lassign $span from to
            append out [string range $text $from $to]
            set i [expr {$to + 1}]
            continue
        }
        set c [string index $text $i]
        if {$c eq "\""} {
            incr i
            return $out
        }
        # A backslash: exactly one escape follows.
        incr i
        set e [string index $text $i]
        incr i
        switch -- $e {
            "\"" { append out "\"" }
            "\\" { append out "\\" }
            "/"  { append out "/" }
            b    { append out "\b" }
            f    { append out "\f" }
            n    { append out "\n" }
            r    { append out "\r" }
            t    { append out "\t" }
            u    { append out [ParseEscapedCodepoint $text i] }
            default { Fail $text [expr {$i - 2}] "unknown escape \\$e" }
        }
    }
}

# Reads the four hex digits of a \u escape, joining a surrogate pair into the
# one character it names. A lone high surrogate followed by anything else is
# kept as it is rather than rejected: the value is still readable, and refusing
# it would lose the whole response over one stray character.
proc ::frostlake::json::ParseEscapedCodepoint {text iVar} {
    upvar 1 $iVar i
    set digits [string range $text $i [expr {$i + 3}]]
    if {![regexp {\A[0-9a-fA-F]{4}\Z} $digits]} {
        Fail $text $i "\\u must be followed by four hex digits"
    }
    incr i 4
    scan $digits %4x code
    if {$code >= 0xD800 && $code <= 0xDBFF
        && [string range $text $i [expr {$i + 1}]] eq "\\u"} {
        set low [string range $text [expr {$i + 2}] [expr {$i + 5}]]
        if {[regexp {\A[0-9a-fA-F]{4}\Z} $low]} {
            scan $low %4x lowCode
            if {$lowCode >= 0xDC00 && $lowCode <= 0xDFFF} {
                incr i 6
                # Tcl 8.6 strings are UTF-16 inside: a character past the
                # basic plane IS its two surrogates, and `format %c` of the
                # combined code point answered the replacement character. The
                # pair, kept as a pair, encodes to the right four UTF-8 bytes.
                return "[format %c $code][format %c $lowCode]"
            }
        }
    }
    return [format %c $code]
}

proc ::frostlake::json::ParseArray {text iVar} {
    upvar 1 $iVar i
    incr i ;# past [
    set out {}
    SkipSpace $text i
    if {[string index $text $i] eq "\]"} {
        incr i
        return [list array $out]
    }
    while {1} {
        lappend out [ParseValue $text i]
        SkipSpace $text i
        set c [string index $text $i]
        if {$c eq ","} {
            incr i
            continue
        }
        if {$c eq "\]"} {
            incr i
            return [list array $out]
        }
        Fail $text $i "expected , or \] in an array"
    }
}

proc ::frostlake::json::ParseObject {text iVar} {
    upvar 1 $iVar i
    incr i ;# step over the opening brace
    set out [dict create]
    SkipSpace $text i
    if {[string index $text $i] eq "\}"} {
        incr i
        return [list object $out]
    }
    while {1} {
        SkipSpace $text i
        if {[string index $text $i] ne "\""} {
            Fail $text $i "an object key must be a string"
        }
        set key [ParseString $text i]
        SkipSpace $text i
        if {[string index $text $i] ne ":"} {
            Fail $text $i "expected : after an object key"
        }
        incr i
        dict set out $key [ParseValue $text i]
        SkipSpace $text i
        set c [string index $text $i]
        if {$c eq ","} {
            incr i
            continue
        }
        if {$c eq "\}"} {
            incr i
            return [list object $out]
        }
        Fail $text $i "expected , or \} in an object"
    }
}

# ---------------------------------------------------------------- reading

# The JSON type of a decoded value: null, bool, number, string, array or object.
proc ::frostlake::json::type {json} {
    return [lindex $json 0]
}

# The payload behind the tag: the text of a number or string, 1/0 for a
# boolean, the element list of an array, the dict of an object, {} for null.
proc ::frostlake::json::value {json} {
    return [lindex $json 1]
}

# Whether an object carries this key. Distinct from the key being present and
# null, which is a difference the wire makes and the driver honours.
proc ::frostlake::json::exists {json key} {
    if {[lindex $json 0] ne "object"} { return 0 }
    return [dict exists [lindex $json 1] $key]
}

# An object member as a tagged value; JSON null when the key is absent, so a
# caller reading an optional field needs no guard.
proc ::frostlake::json::at {json key} {
    if {[lindex $json 0] ne "object"} { return {null {}} }
    set members [lindex $json 1]
    if {![dict exists $members $key]} { return {null {}} }
    return [dict get $members $key]
}

# An array element as a tagged value, or JSON null when out of range.
proc ::frostlake::json::index {json i} {
    if {[lindex $json 0] ne "array"} { return {null {}} }
    set elements [lindex $json 1]
    if {$i < 0 || $i >= [llength $elements]} { return {null {}} }
    return [lindex $elements $i]
}

# How many elements an array holds, or members an object; 0 for anything else.
proc ::frostlake::json::size {json} {
    switch -- [lindex $json 0] {
        array  { return [llength [lindex $json 1]] }
        object { return [dict size [lindex $json 1]] }
    }
    return 0
}

# An object's keys, in the order they arrived.
proc ::frostlake::json::keys {json} {
    if {[lindex $json 0] ne "object"} { return {} }
    return [dict keys [lindex $json 1]]
}

# A scalar as the text Tcl works in: numbers keep their digits exactly,
# booleans read `true`/`false` (both of which Tcl's own `expr` accepts), and
# null becomes `$null` -- the caller's chosen stand-in, since Tcl has no null of
# its own. Arrays and objects are re-encoded, which is how the engine renders
# VARIANT anyway.
proc ::frostlake::json::scalar {json {null ""}} {
    lassign $json kind payload
    switch -- $kind {
        null   { return $null }
        bool   { return [expr {$payload ? "true" : "false"}] }
        number -
        string { return $payload }
    }
    return [text $json]
}

# ---------------------------------------------------------------- encoding

# Re-encodes a decoded value as JSON text.
proc ::frostlake::json::text {json} {
    lassign $json kind payload
    switch -- $kind {
        null   { return "null" }
        bool   { return [expr {$payload ? "true" : "false"}] }
        number { return $payload }
        string { return [encode_string $payload] }
        array {
            set parts {}
            foreach element $payload { lappend parts [text $element] }
            return "\[[join $parts ,]\]"
        }
        object {
            set parts {}
            dict for {key element} $payload {
                lappend parts "[encode_string $key]:[text $element]"
            }
            return "\{[join $parts ,]\}"
        }
    }
    return -code error -errorcode [list FROSTLAKE JSON] \
        "cannot encode a value tagged \"$kind\""
}

# The escape table, built once. A JSON string may not carry a raw control
# character, so everything below a space needs a form that is not itself one.
namespace eval ::frostlake::json {
    variable ESCAPES [list \
        "\"" "\\\"" \
        "\\" "\\\\" \
        "\b" "\\b" \
        "\f" "\\f" \
        "\n" "\\n" \
        "\r" "\\r" \
        "\t" "\\t"]
    for {set c 0} {$c <= 0x7F} {incr c} {
        # The C0 block, plus U+007F: that one is legal raw in JSON, but enough
        # readers mishandle it to be worth spelling out alongside the rest.
        if {$c > 0x1F && $c != 0x7F} { continue }
        set ch [format %c $c]
        if {[lsearch -exact $ESCAPES $ch] < 0} {
            lappend ESCAPES $ch [format {\u%04x} $c]
        }
    }
    unset c ch
}

# Renders a Tcl string as a JSON string literal, quotes included.
#
# Non-ASCII characters go out as themselves: the transport encodes the whole
# payload as UTF-8, which is what JSON is defined over, so escaping them would
# only make the request longer.
proc ::frostlake::json::encode_string {text} {
    variable ESCAPES
    return "\"[string map $ESCAPES $text]\""
}

# Renders a Tcl dict of plain strings as a JSON object of strings.
proc ::frostlake::json::encode {pairs} {
    set parts {}
    dict for {key val} $pairs {
        lappend parts "[encode_string $key]:[encode_string $val]"
    }
    return "\{[join $parts ,]\}"
}
