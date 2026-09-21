[**QUERE Jean-Marc**](https://www.abandonware-magazines.org/affiche_mag.php?mag=167&num=18774&album=oui)

---

# Awk

*Language of the month...*

## Overview

Everyday file-handling tasks often require writing one-off "throwaway" scripts. Development languages need many lines of code just to open input and output streams, parse the collected data, and format it properly. Moreover, such environments — generally quite large — must first be installed. The ideal would be a scripting language that is simple to use, compact, and geared toward searching and analyzing sequences and expressions.

This problem caught the attention of some particularly brilliant minds. Alfred V. Aho (an expert in compilation), Peter J. Weinberger (polynomial factorization, ...) and Brian W. Kernighan (also known for creating C) set out to solve it by implementing a new language. Named after the initials of its designers, the first version of AWK — in the form of an interpreter — was completed in 1977. As it came into use, the language's features evolved at a steady pace. New versions followed one another until 1985, when the state of the art was universally recognized as a standard. The most significant improvements at that point concerned the ability to create user-defined functions, support for multiple streams, and support for regular expressions. Widely distributed in the Unix world (bundled with the System V distribution), AWK earned its stripes when its features were incorporated into the "command language and utilities" section of the POSIX standard (specifically, 1003.2).

At Richard Stallman's (GNU) initiative, a free implementation of AWK (also interpreted) appeared as early as 1986. It evolved, and continues to evolve, through the work of its contributors, gaining improvements and necessary refinements along the way. GAWK is available for many operating systems from the GNU site (http://www.gnu.org). Commercial variants are also distributed, notably TAWK (http://www.tasoft.com). Particularly comprehensive, this distribution forms a genuine development toolchain (command-line based) enabling the generation of native executables for DOS, OS/2, Solaris, and Windows (with support for sockets and DLLs).

## In practice

An AWK program is written "by hand", using a text editor: "notepad" on Windows or "vi" on Unix work perfectly well. Three functional blocks are available (though none is mandatory): "BEGIN", "regular expression", and "END". The instructions in the "BEGIN" and "END" blocks run at the start and end of the program respectively; those attached to a regular expression run whenever the required conditions for that expression are met.

**ex000.awk**
```awk
BEGIN {
  print "DEBUT"
  CPT=0
}
/A/ {
  CPT++
}
END {
  print "NB DE LIGNE(S) AVEC UN 'A' : " CPT
}
```

The example above counts the number of lines containing an "A". It is run from the command line using the command `awk -f ex000.awk`. The message "DEBUT" is displayed on the console. You can then type a few lines of text, separated by carriage returns, and when finished press [CTRL]-Z (F6 key on Windows), then Enter. Since AWK's real strength lies in file handling, the command can be extended with the names of the files to process.

**ex000.txt**
```
A
B
BA
```

The command `awk -f ex000.awk ex000.txt` returns "DEBUT", then "NB DE LIGNE(S) AVEC UN 'A' : 2". The list of files to process can include wildcards, for example: `*.bat`.

Regular expressions ("/A/" in the example above) let you restrict the execution of the associated instructions to only the matching lines, i.e. those containing the described sequence. The main writing rules are as follows: "." (the dot) matches any character; "[ABC]" lists the characters (A or B or C); "[A-Z]" defines the set of characters from A to Z (for example); "*", "+" and "?" indicate, respectively, a repetition of 0 to n, 1 to n, and 0 to 1. The pattern can be anchored to the start of the line (prefixed with "^") or the end (suffixed with "$").

**ex001.awk**
```awk
/BA*/ { printf "1" }
/A+/ { printf "2" }
/B?/ { printf "3" }
/B[AB]/ { printf "4" }
// { print "" }
```

The command `awk -f ex001.awk ex000.txt` displays "23", "13", "1234". The expression "//" (which can be omitted) matches every line; here it is used to skip a line. AWK's other key strength is its ability to split each line read (denoted `$0`) into fields (`$1` through `$n`), based on a field separator (a space by default) and a line separator (a carriage return by default).

**Windows 2000 only**
```
dir | awk "/:/ { print $1 \" \" $4 }"
```

The command above captures the output (pipe) from the `dir` command and displays the date and name of each file (or directory). The space acts as the concatenation operator. The other example, adapted for the Windows 95 version of `dir`, extracts directories only.

**Windows 9x only**
```
dir | awk "/<REP>/ { print $1 }"
```

AWK variables are untyped: their nature is determined by the operators used on them. `BEGIN { A="12"; B=35; print A B; print A+B }` displays "1235", then "47". The concatenation operator causes B to be converted to a string. Addition causes the value of string A to be interpreted numerically. Variables can also be used as arrays without any prior declaration. Indices can be, as needed, numeric or alphanumeric values (or both). The `for` loop even has a variant specifically for arrays, `for (variant in array)`, allowing you to iterate over them.

**ex003.awk**
```awk
BEGIN {
  split("CECI EST UN TEST",tab," ")
  for (i in tab) {
    print i,tab[i]
    idx[tab[i]]=i
  }
  for (i in idx) {
    print i,idx[i]
  }
}
```

AWK includes many data-processing instructions. One of the best known is `split`, which breaks a string (here "CECI ...") into an array (`tab`) using the given separator (a space by default).

The lack of variable typing allows generic functions to be written. `max` returns the larger of two values, whatever their type. With a typed language, two separate functions would have been needed; on the other hand, the lack of typing can produce rather unexpected results. Example: `max(100, "34")` returns... 34! When a comparison operator involves a string, all the compared values are converted to strings, and "100" turns out to be smaller than "34" ("1" comes before "3" in the ASCII table).

**ex004.awk**
```awk
function max(v1,v2) {
  return v1>v2 ? v1 : v2;
}
BEGIN {
  print max("12","34");
  print max(100,34);
}
```

## Revolutionary

Innovative in its time, AWK introduced two specific concepts: regular expressions and event-driven handling. In its "pure" form (meaning original, not derived), it is used only alongside the command interpreters of various operating systems.

---

**Illustrations**

![AWK en action](awk-1.png)

![l'aide de gawk (une référence)](awk-2.png)

![a version GNU (libre, interpréteur) d'AWK](awk-3.png)

![la version — la plus aboutie — d'AWK (commerciale, interpréteur et compilateur)](awk-4.png)
