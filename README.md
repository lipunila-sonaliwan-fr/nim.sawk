# AWK Interpreter Manual (sawk.nim)
CC BY-NC-SA 4.0 - jean-marc "jihem" quere 2026 (sonaliwan.fr)

## Introduction

My first research work **in NLP** in the mid-90s led me to use the **AWK** language, a tool dedicated to text manipulation. Designed to quickly write small programs - sometimes a simple one-line command - capable of extracting, transforming, or reorganizing text on the fly, AWK established itself as a standard. Created by **Alfred Aho** (co-inventor, with Margaret Corasick, of the eponymous pattern-matching algorithm), **Peter Weinberger** (one of the authors of Fortran 77), and **Brian Kernighan** (after his part in inventing C), it is present today on every operating system.

One of my projects required **interfacing with electronic boards** dedicated to capturing HF signals. Under **OS/2**, the AWK interpreter proved too slow and did not make it easy to access those boards' driver libraries. Pressed for time - a prototype had to be presented to unlock budget funding - I did some research on a still-nascent Internet. That allowed me to get in touch with **Pat(rick) Thompson** and to use their remarkable **TAWK Compiler**.

That compiler produced executables for DOS, Windows, and OS/2, and could be extended via dynamic libraries written in C, Delphi, etc. I contributed to that solution (profiling), which stayed with me for nearly ten years. That is precisely why, following Tasoft.com ceasing operations and in the absence of an equivalent alternative, I set out to build a version of **AWK implementation in Nim**. It offers similar ease of use, and the clock speed of today's processors delivers more than satisfactory performance, even with this interpreted version.

This document therefore describes the AWK dialect implemented by `sawk.nim`: every language construct, every special variable, every built-in function, and every command-line option, each accompanied by a runnable example.

Jean-Marc Quéré


## Table of Contents

1. [Invocation](#1-invocation)
2. [Program structure](#2-program-structure)
3. [Patterns](#3-patterns)
4. [Fields](#4-fields)
5. [Types and conversions](#5-types-and-conversions)
6. [Special variables](#6-special-variables)
7. [Operators](#7-operators)
8. [Control statements](#8-control-statements)
9. [Associative arrays](#9-associative-arrays)
10. [User-defined functions](#10-user-defined-functions)
11. [Built-in functions](#11-built-in-functions)
12. [print / printf and redirections](#12-print--printf-and-redirections)
13. [getline](#13-getline)
14. [Command-line options](#14-command-line-options)
15. [Known limitations](#15-known-limitations)

---

## 1. Invocation

```bash
sawk [-F fs] [-v var=val ...] 'program' [file ...]
sawk [-F fs] [-v var=val ...] -f prog.awk [file ...]
```

Example:

```bash
$ echo -e "a b\nc d" | ./awk '{print $2, $1}'
b a
d c
```

---

## 2. Program structure

An AWK program is a sequence of `pattern { action }` rules. The pattern or
the action may be omitted (but not both):

- `pattern { action }` — the action runs if the pattern is true.
- `pattern` alone — equivalent to `pattern { print $0 }`.
- `{ action }` alone — the action runs for every record.

```awk
BEGIN { print "start" }
/error/ { print "suspicious line:", $0 }
{ total++ }
END   { print "total =", total }
```

---

## 3. Patterns

| Pattern | Meaning | Example |
|---|---|---|
| `BEGIN` | runs once before any reading | `BEGIN { print "start" }` |
| `END` | runs once after the last read | `END { print NR, "lines" }` |
| *expression* | true if the expression is true for the record | `NR % 2 == 0 { print }` |
| `/regex/` | true if `$0` matches the regex | `/^#/ { next }` |
| `expr1, expr2` | range pattern: active from the line where `expr1` becomes true until the line where `expr2` becomes true (inclusive) | `/START/,/END/ { print }` |
| *(empty)* | always true | `{ print NR }` |

---

## 4. Fields

`$0` is the whole record, `$1`..`$NF` its fields, split according to `FS`.

```awk
{ print "first field:", $1, "- field count:", NF }
```

Assigning to a field rebuilds `$0` (using `OFS`); assigning to `$0`
re-splits the fields:

```awk
{ $2 = "X"; print }        # replaces the 2nd field, rebuilds $0
{ $0 = "a:b:c"; print $2 } # re-splits according to the current FS
```

Reducing or increasing `NF` truncates or extends the record:

```awk
{ NF = 3; print }          # keeps only the first 3 fields
```

A field beyond `NF` returns an empty string; writing to it extends the record:

```awk
{ $6 = "end"; print NF, $0 }
```

---

## 5. Types and conversions

An AWK value is either a number, a string, or a
"numeric string" (`strnum`, coming from fields, from `getline`, or from the
`-v`/`ARGV` arguments) which compares numerically if it looks like a
number. Implicit number → string conversions use `CONVFMT`
(or `OFMT` for `print`).

```awk
BEGIN {
  x = "3" + "4"      # 7        (numeric)
  y = "3" "4"        # "34"     (string concatenation)
  print x, y
}
```

```awk
BEGIN { CONVFMT = "%.2f"; z = 1/3; print z "" }   # "0.33"
```

---

## 6. Special variables

| Variable | Role | Default |
|---|---|---|
| `NF` | number of fields in the current record | — |
| `NR` | global record number since the start | `0` |
| `FNR` | record number within the current file | `0` |
| `FS` | field separator (1 char. = literal, `" "` = whitespace, >1 char. = regex, `""` = per-character) | `" "` |
| `OFS` | output field separator (rebuilding `$0`, `print`) | `" "` |
| `RS` | record separator (1 char., `""` = paragraph mode, otherwise regex) | `"\n"` |
| `ORS` | record terminator for `print` | `"\n"` |
| `SUBSEP` | separator for multiple array subscripts | `"\x1c"` |
| `CONVFMT` | implicit number→string format | `"%.6g"` |
| `OFMT` | number→string format for `print` | `"%.6g"` |
| `FILENAME` | name of the file currently being read | `""` |
| `RSTART` / `RLENGTH` | set by `match()` | `0` / `-1` |
| `ARGC` / `ARGV` | number and array of arguments (files) | — |
| `ENVIRON` | array of environment variables | — |

```awk
BEGIN { FS = ":"; OFS = "-" }
{ print $1, $NF }         # fields separated by ':', displayed separated by '-'
```

```bash
$ ./sawk -F, '{print NR": "$1}' file.csv
```

```awk
BEGIN {
  for (k in ENVIRON) if (k == "HOME") print ENVIRON[k]
  for (i = 1; i < ARGC; i++) print "file:", ARGV[i]
}
```

---

## 7. Operators

### Arithmetic

| Op. | Example |
|---|---|
| `+` `-` `*` `/` `%` `^` (or `**`) | `BEGIN { print 2^10, 7 % 3 }` |

### Comparison (numeric or lexicographic depending on the operands)

```awk
BEGIN { if (3 < 10) print "num"; if ("abc" < "abd") print "str" }
```

### Logical

```awk
BEGIN { if (1 && !0 || 0) print "true" }
```

### Concatenation (juxtaposition)

```awk
BEGIN { print "value=" 42 }
```

### Assignment

```awk
BEGIN { x = 5; x += 3; x -= 1; x *= 2; x /= 7; x %= 3; x ^= 2; print x }
```

### Increment / decrement

```awk
BEGIN { i = 0; print i++, ++i, i--, --i }
```

### Ternary

```awk
BEGIN { print (NR % 2 == 0) ? "even" : "odd" }
```

### Regex matching

```awk
$0 ~ /^INFO/  { print "info log" }
$0 !~ /^INFO/ { print "other" }
```

### Array membership

```awk
BEGIN {
  a["x"] = 1
  if ("x" in a) print "present"
  if (!("y" in a)) print "absent"
}
```

### Multiple subscripts (via SUBSEP)

```awk
BEGIN {
  m[1,2] = "a"
  if ((1,2) in m) print m[1,2]
}
```

---

## 8. Control statements

### if / else

```awk
{ if ($1 > 10) print "large"; else print "small" }
```

### while

```awk
BEGIN { i = 0; while (i < 3) { print i; i++ } }
```

### do-while

```awk
BEGIN { i = 0; do { print i; i++ } while (i < 3) }
```

### for (classic)

```awk
BEGIN { for (i = 1; i <= 5; i++) print i }
```

### for (in) — iterating over an array

```awk
BEGIN {
  a["x"] = 1; a["y"] = 2
  for (k in a) print k, a[k]
}
```

### break / continue

```awk
BEGIN {
  for (i = 1; i <= 10; i++) {
    if (i == 5) break
    if (i % 2 == 0) continue
    print i
  }
}
```

### next — moves to the next record

```awk
/^#/ { next }
{ print }
```

### nextfile — moves to the next file

```awk
FNR == 1 { print "==>", FILENAME }
FNR > 3  { nextfile }
```

### exit — terminates (still runs END, unless exit is called from within END)

```awk
NR > 100 { exit 1 }
END { print "end, NR =", NR }
```

### return (inside a function)

```awk
function square(x) { return x * x }
BEGIN { print square(6) }
```

### delete

```awk
BEGIN {
  a["x"] = 1
  delete a["x"]      # removes one element
  a["y"] = 2
  delete a           # empties the whole array
}
```

---

## 9. Associative arrays

Arrays are created on first use, indexed by string.

```awk
{ count[$1]++ }
END { for (k in count) print k, count[k] }
```

```awk
BEGIN { split("a:b:c", parts, ":"); for (i = 1; i <= 3; i++) print parts[i] }
```

---

## 10. User-defined functions

```awk
function max(a, b) {
  return a > b ? a : b
}
BEGIN { print max(3, 9) }
```

Extra parameters (not supplied at call time) act as
local variables. A plain variable name passed as an argument is
passed by reference if it is used as an array inside the function:

```awk
function fill(arr) {
  arr["a"] = 1
  arr["b"] = 2
}
BEGIN {
  fill(t)
  for (k in t) print k, t[k]   # t was modified by the function
}
```

```awk
function fact(n,   acc) {   # 'acc' is a local variable
  acc = 1
  while (n > 1) { acc *= n; n-- }
  return acc
}
BEGIN { print fact(5) }
```

---

## 11. Built-in functions

| Function | Example |
|---|---|
| `length([s\|arr])` | `BEGIN { print length("hello") }` |
| `substr(s, m[, n])` | `BEGIN { print substr("hello", 2, 3) }` |
| `index(s, t)` | `BEGIN { print index("hello", "llo") }` |
| `split(s, arr[, fs])` | `BEGIN { n = split("a,b,c", t, ","); print n, t[2] }` |
| `sub(re, repl[, target])` | `BEGIN { s = "hello"; sub(/e/, "3", s); print s }` |
| `gsub(re, repl[, target])` | `BEGIN { s = "hello"; gsub(/l/, "L", s); print s }` |
| `match(s, re)` | `BEGIN { if (match("hello", /ell/)) print RSTART, RLENGTH }` |
| `sprintf(fmt, ...)` | `BEGIN { print sprintf("%-5s|%05d", "ab", 42) }` |
| `sin(x)` | `BEGIN { print sin(0) }` |
| `cos(x)` | `BEGIN { print cos(0) }` |
| `atan2(y, x)` | `BEGIN { print atan2(1, 1) }` |
| `exp(x)` | `BEGIN { print exp(1) }` |
| `log(x)` | `BEGIN { print log(exp(1)) }` |
| `sqrt(x)` | `BEGIN { print sqrt(2) }` |
| `int(x)` | `BEGIN { print int(3.9), int(-3.9) }` |
| `rand()` | `BEGIN { print rand() }` |
| `srand([x])` | `BEGIN { srand(42); print rand() }` |
| `tolower(s)` | `BEGIN { print tolower("HELLO") }` |
| `toupper(s)` | `BEGIN { print toupper("hello") }` |
| `system(cmd)` | `BEGIN { system("date") }` |
| `close(name)` | `BEGIN { print "x" > "f.txt"; close("f.txt") }` |
| `fflush([name])` | `BEGIN { print "x"; fflush() }` |

### Details on `sub`/`gsub`/`match`

The first argument can be a literal regex `/re/` or a string
used as a regex. `&` in the replacement string inserts the matched
text, `\&` inserts a literal `&`:

```awk
BEGIN { s = "cat"; gsub(/a/, "[&]", s); print s }   # c[a]t
```

### `sprintf` / `printf`: supported conversion specifiers

`%d %i %o %x %X %u %c %s %e %E %f %F %g %G %%`, with flags
`- 0 + space #`, width, and precision:

```awk
BEGIN { printf("%-10s|%6.2f|%03d\n", "abc", 3.14159, 7) }
```

---

## 12. print / printf and redirections

```awk
{ print }                       # prints $0
{ print $1, $2 }                # prints separated by OFS
{ print $1 > "output.txt" }     # writes (truncates on first access)
{ print $1 >> "log.txt" }       # appends
{ print $0 | "sort" }           # pipes to a command
```

```awk
BEGIN { printf("%s is %d years old\n", "Alice", 30) }
```

---

## 13. getline

| Form | Effect | Example |
|---|---|---|
| `getline` | reads the next record into `$0`; updates `NF`, `NR`, `FNR` | `{ if ((getline) > 0) print "next:", $0 }` |
| `getline var` | reads into `var`; updates `NR`, `FNR` | `{ getline line; print line }` |
| `getline < file` | reads a line from the file into `$0`/`NF` | `{ while ((getline < "data.txt") > 0) print }` |
| `getline var < file` | reads a line from the file into `var` | `{ getline v < "data.txt"; print v }` |
| `cmd \| getline` | runs `cmd`, reads its output into `$0`/`NF`, updates `NR` | `BEGIN { "date" \| getline; print }` |
| `cmd \| getline var` | runs `cmd`, reads its output into `var` | `BEGIN { "whoami" \| getline u; print u }` |

`getline` returns `1` on success, `0` at end of file, `-1` on
error (file not found, etc.).

---

## 14. Command-line options

| Option | Effect | Example |
|---|---|---|
| `-F fs` | sets `FS` before `BEGIN` | `./sawk -F: '{print $1}' /etc/passwd` |
| `-v var=val` | assigns a variable before `BEGIN` | `./sawk -v threshold=10 '$1>threshold{print}' f` |
| `-f prog.awk` | reads the program from a file (repeatable) | `./sawk -f script.awk data.txt` |
| `var=val` in file position | deferred assignment, executed at the point where it appears in `ARGV` | `./sawk '{print x, $0}' x=1 f1 x=2 f2` |

---

## 15. Known limitations

This interpreter covers the core of the AWK language (POSIX plus a few
common extensions), with a number of simplifications compared to
`gawk`/`sawkk`:

- `printf`/`sprintf` do not support dynamic width/precision (`%*d`).
- `RS` as a regular expression and paragraph mode (`RS=""`) are
  handled in a simplified way (the entire file is loaded into memory).
- `cmd | getline` and `print | cmd` capture output/input via a
  classic child process, without guaranteeing a true bidirectional
  interactive stream.
- No `PROCINFO` and no `gawk`-specific extensions (real
  multidimensional arrays, `switch`, `BEGINFILE`/`ENDFILE`, etc.).
- `length(array)` uses a heuristic (presence of elements) to
  tell an array from a scalar when the name has not been used yet.

For everything else — patterns, fields, operators, control flow, arrays,
user functions, built-in functions, `getline`, redirections — the
behavior follows that of standard AWK as described in this manual.

### One more thing!
A small gesture that can - greatly - help us... \[Caffeine matters a lot for a team of neurodivergent folks: ASD, ADHD, GAD, HPI and/or THPI (members of **mensa.fr** and **triplenine.org**).\]

[![Buy Me a Coffee](buymeacoffe-eng.png)](https://buymeacoffee.com/sonaliwan.fr)
