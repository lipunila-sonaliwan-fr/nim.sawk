# Manuel de l'interpréteur AWK (sawk.nim)
CC BY-NC-SA 4.0 - jean-marc "jihem" quere 2026 (sonaliwan.fr)

## Introduction

Mes premiers travaux de recherche **en TAL** au milieu des années 90 m’ont conduit à utiliser le langage **AWK**, un outil dédié à la manipulation de texte. Conçu pour écrire rapidement de petits programmes - parfois une simple ligne de commande - capables d’extraire, transformer ou réorganiser du texte à la volée, AWK s’est imposé comme un standard. Créé par **Alfred Aho** (co‑inventeur avec Margaret Corasick de l’algorithme de recherche de motifs éponyme), **Peter Weinberger** (l’un des auteurs de Fortran 77) et **Brian Kernighan** (après sa participation à l’invention du C), il est aujourd’hui présent sur tous les systèmes d’exploitation.

L’un de mes projets nécessitait l’**interfaçage avec des cartes électroniques** dédiées à la captation de signaux HF. Sous **OS/2**, l’interpréteur AWK se révélait trop lent et ne permettait pas d’accéder facilement aux bibliothèques du driver de ces cartes. Pressé par le temps - un prototype devait être présenté pour débloquer des enveloppes budgétaires - j’ai effectué une recherche sur un Internet encore balbutiant. Cela m’a permis de contacter **Pat**(rick) **Thompson** et d’utiliser leur remarquable **TAWK Compiler**.

Ce compilateur produisait des exécutables pour DOS, Windows et OS/2, et pouvait être étendu via des bibliothèques dynamiques en C, Delphi, etc. J’ai contribué à cette solution (profilage), qui m’a accompagné pendant près de dix ans. C’est précisément pour cette raison que, suite à l’arrêt d’activité de Tasoft.com et en l’absence d’alternative équivalente, j’ai entrepris de réaliser une version de **AWK en Nim**. Elle offre un confort d’utilisation similaire, et la fréquence des processeurs actuels permet d’obtenir des performances plus que satisfaisantes, même avec cette version interprétée.

Ce document décrit donc le dialecte AWK implémenté par `sawk.nim` : toutes les constructions du langage, toutes les variables spéciales, toutes les fonctions intégrées et toutes les options de ligne de commande, chacune accompagnée d'un exemple exécutable.

Jean-Marc Quéré


## Sommaire

1. [Invocation](#1-invocation)
2. [Structure d'un programme](#2-structure-dun-programme)
3. [Motifs (patterns)](#3-motifs-patterns)
4. [Champs](#4-champs)
5. [Types et conversions](#5-types-et-conversions)
6. [Variables spéciales](#6-variables-spéciales)
7. [Opérateurs](#7-opérateurs)
8. [Instructions de contrôle](#8-instructions-de-contrôle)
9. [Tableaux associatifs](#9-tableaux-associatifs)
10. [Fonctions définies par l'utilisateur](#10-fonctions-définies-par-lutilisateur)
11. [Fonctions intégrées](#11-fonctions-intégrées)
12. [print / printf et redirections](#12-print--printf-et-redirections)
13. [getline](#13-getline)
14. [Options de ligne de commande](#14-options-de-ligne-de-commande)
15. [Limitations connues](#15-limitations-connues)

---

## 1. Invocation

```bash
sawk [-F fs] [-v var=val ...] 'programme' [fichier ...]
sawk [-F fs] [-v var=val ...] -f prog.awk [fichier ...]
```

Exemple :

```bash
$ echo -e "a b\nc d" | ./sawk '{print $2, $1}'
b a
d c
```

---

## 2. Structure d'un programme

Un programme AWK est une suite de règles `motif { action }`. Le motif ou
l'action peuvent être omis (mais pas les deux) :

- `motif { action }` — l'action s'exécute si le motif est vrai.
- `motif` seul — équivaut à `motif { print $0 }`.
- `{ action }` seul — l'action s'exécute pour chaque enregistrement.

```awk
BEGIN { print "début" }
/erreur/ { print "ligne suspecte:", $0 }
{ total++ }
END   { print "total =", total }
```

---

## 3. Motifs (patterns)

| Motif | Sens | Exemple |
|---|---|---|
| `BEGIN` | exécuté une fois avant toute lecture | `BEGIN { print "start" }` |
| `END` | exécuté une fois après la dernière lecture | `END { print NR, "lignes" }` |
| *expression* | vrai si l'expression est vraie pour l'enregistrement | `NR % 2 == 0 { print }` |
| `/regex/` | vrai si `$0` correspond à la regex | `/^#/ { next }` |
| `expr1, expr2` | motif de plage : actif de la ligne où `expr1` devient vrai jusqu'à celle où `expr2` devient vrai (inclus) | `/START/,/END/ { print }` |
| *(vide)* | toujours vrai | `{ print NR }` |

---

## 4. Champs

`$0` est l'enregistrement complet, `$1`..`$NF` ses champs, découpés selon `FS`.

```awk
{ print "premier champ:", $1, "- nombre de champs:", NF }
```

Affecter un champ reconstruit `$0` (avec `OFS`) ; affecter `$0` redécoupe
les champs :

```awk
{ $2 = "X"; print }        # remplace le 2e champ, reconstruit $0
{ $0 = "a:b:c"; print $2 } # redécoupe selon FS courant
```

Réduire ou augmenter `NF` tronque ou étend l'enregistrement :

```awk
{ NF = 3; print }          # ne garde que les 3 premiers champs
```

Un champ au-delà de `NF` renvoie une chaîne vide ; l'écrire l'étend :

```awk
{ $6 = "fin"; print NF, $0 }
```

---

## 5. Types et conversions

Une valeur AWK est soit un nombre, soit une chaîne, soit une
"chaîne numérique" (`strnum`, provenant des champs, de `getline`, des
arguments `-v`/`ARGV`) qui se compare numériquement si elle ressemble à un
nombre. Les conversions implicites nombre → chaîne utilisent `CONVFMT`
(ou `OFMT` pour `print`).

```awk
BEGIN {
  x = "3" + "4"      # 7        (numérique)
  y = "3" "4"        # "34"     (concaténation de chaînes)
  print x, y
}
```

```awk
BEGIN { CONVFMT = "%.2f"; z = 1/3; print z "" }   # "0.33"
```

---

## 6. Variables spéciales

| Variable | Rôle | Défaut |
|---|---|---|
| `NF` | nombre de champs de l'enregistrement courant | — |
| `NR` | numéro d'enregistrement global depuis le début | `0` |
| `FNR` | numéro d'enregistrement dans le fichier courant | `0` |
| `FS` | séparateur de champs (1 car. = littéral, `" "` = espaces, >1 car. = regex, `""` = par caractère) | `" "` |
| `OFS` | séparateur de champs en sortie (reconstruction de `$0`, `print`) | `" "` |
| `RS` | séparateur d'enregistrements (1 car., `""` = mode paragraphe, sinon regex) | `"\n"` |
| `ORS` | terminateur d'enregistrement pour `print` | `"\n"` |
| `SUBSEP` | séparateur des indices multiples de tableau | `"\x1c"` |
| `CONVFMT` | format nombre→chaîne implicite | `"%.6g"` |
| `OFMT` | format nombre→chaîne pour `print` | `"%.6g"` |
| `FILENAME` | nom du fichier en cours de lecture | `""` |
| `RSTART` / `RLENGTH` | positionnés par `match()` | `0` / `-1` |
| `ARGC` / `ARGV` | nombre et tableau des arguments (fichiers) | — |
| `ENVIRON` | tableau des variables d'environnement | — |

```awk
BEGIN { FS = ":"; OFS = "-" }
{ print $1, $NF }         # champs séparés par ':', affichés séparés par '-'
```

```bash
$ ./sawk -F, '{print NR": "$1}' fichier.csv
```

```awk
BEGIN {
  for (k in ENVIRON) if (k == "HOME") print ENVIRON[k]
  for (i = 1; i < ARGC; i++) print "fichier:", ARGV[i]
}
```

---

## 7. Opérateurs

### Arithmétiques

| Op. | Exemple |
|---|---|
| `+` `-` `*` `/` `%` `^` (ou `**`) | `BEGIN { print 2^10, 7 % 3 }` |

### Comparaison (numérique ou lexicographique selon les opérandes)

```awk
BEGIN { if (3 < 10) print "num"; if ("abc" < "abd") print "str" }
```

### Logiques

```awk
BEGIN { if (1 && !0 || 0) print "vrai" }
```

### Concaténation (juxtaposition)

```awk
BEGIN { print "valeur=" 42 }
```

### Affectation

```awk
BEGIN { x = 5; x += 3; x -= 1; x *= 2; x /= 7; x %= 3; x ^= 2; print x }
```

### Incrémentation / décrémentation

```awk
BEGIN { i = 0; print i++, ++i, i--, --i }
```

### Ternaire

```awk
BEGIN { print (NR % 2 == 0) ? "pair" : "impair" }
```

### Correspondance regex

```awk
$0 ~ /^INFO/  { print "log info" }
$0 !~ /^INFO/ { print "autre" }
```

### Appartenance à un tableau

```awk
BEGIN {
  a["x"] = 1
  if ("x" in a) print "présent"
  if (!("y" in a)) print "absent"
}
```

### Indices multiples (via SUBSEP)

```awk
BEGIN {
  m[1,2] = "a"
  if ((1,2) in m) print m[1,2]
}
```

---

## 8. Instructions de contrôle

### if / else

```awk
{ if ($1 > 10) print "grand"; else print "petit" }
```

### while

```awk
BEGIN { i = 0; while (i < 3) { print i; i++ } }
```

### do-while

```awk
BEGIN { i = 0; do { print i; i++ } while (i < 3) }
```

### for (classique)

```awk
BEGIN { for (i = 1; i <= 5; i++) print i }
```

### for (in) — parcours d'un tableau

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

### next — passe à l'enregistrement suivant

```awk
/^#/ { next }
{ print }
```

### nextfile — passe au fichier suivant

```awk
FNR == 1 { print "==>", FILENAME }
FNR > 3  { nextfile }
```

### exit — termine (exécute quand même END, sauf si exit est dans END)

```awk
NR > 100 { exit 1 }
END { print "fin, NR =", NR }
```

### return (dans une fonction)

```awk
function carre(x) { return x * x }
BEGIN { print carre(6) }
```

### delete

```awk
BEGIN {
  a["x"] = 1
  delete a["x"]      # supprime un élément
  a["y"] = 2
  delete a           # vide tout le tableau
}
```

---

## 9. Tableaux associatifs

Les tableaux sont créés à la première utilisation, indexés par chaîne.

```awk
{ count[$1]++ }
END { for (k in count) print k, count[k] }
```

```awk
BEGIN { split("a:b:c", parts, ":"); for (i = 1; i <= 3; i++) print parts[i] }
```

---

## 10. Fonctions définies par l'utilisateur

```awk
function max(a, b) {
  return a > b ? a : b
}
BEGIN { print max(3, 9) }
```

Les paramètres supplémentaires (non fournis à l'appel) servent de
variables locales. Un nom de variable simple passé en argument est
transmis par référence s'il est utilisé comme tableau dans la fonction :

```awk
function remplit(arr) {
  arr["a"] = 1
  arr["b"] = 2
}
BEGIN {
  remplit(t)
  for (k in t) print k, t[k]   # t a été modifié par la fonction
}
```

```awk
function fact(n,   acc) {   # 'acc' est une variable locale
  acc = 1
  while (n > 1) { acc *= n; n-- }
  return acc
}
BEGIN { print fact(5) }
```

---

## 11. Fonctions intégrées

| Fonction | Exemple |
|---|---|
| `length([s\|arr])` | `BEGIN { print length("bonjour") }` |
| `substr(s, m[, n])` | `BEGIN { print substr("bonjour", 2, 3) }` |
| `index(s, t)` | `BEGIN { print index("bonjour", "jour") }` |
| `split(s, arr[, fs])` | `BEGIN { n = split("a,b,c", t, ","); print n, t[2] }` |
| `sub(re, repl[, cible])` | `BEGIN { s = "bonjour"; sub(/o/, "0", s); print s }` |
| `gsub(re, repl[, cible])` | `BEGIN { s = "bonjour"; gsub(/o/, "0", s); print s }` |
| `match(s, re)` | `BEGIN { if (match("bonjour", /jou/)) print RSTART, RLENGTH }` |
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
| `tolower(s)` | `BEGIN { print tolower("BONJOUR") }` |
| `toupper(s)` | `BEGIN { print toupper("bonjour") }` |
| `system(cmd)` | `BEGIN { system("date") }` |
| `close(nom)` | `BEGIN { print "x" > "f.txt"; close("f.txt") }` |
| `fflush([nom])` | `BEGIN { print "x"; fflush() }` |

### Détails sur `sub`/`gsub`/`match`

Le premier argument peut être une regex littérale `/re/` ou une chaîne
utilisée comme regex. `&` dans la chaîne de remplacement insère le texte
trouvé, `\&` insère un `&` littéral :

```awk
BEGIN { s = "chat"; gsub(/a/, "[&]", s); print s }   # ch[a]t
```

### `sprintf` / `printf` : spécificateurs supportés

`%d %i %o %x %X %u %c %s %e %E %f %F %g %G %%`, avec drapeaux
`- 0 + espace #`, largeur et précision :

```awk
BEGIN { printf("%-10s|%6.2f|%03d\n", "abc", 3.14159, 7) }
```

---

## 12. print / printf et redirections

```awk
{ print }                       # affiche $0
{ print $1, $2 }                # affiche séparé par OFS
{ print $1 > "sortie.txt" }     # écrit (tronque au 1er accès)
{ print $1 >> "log.txt" }       # ajoute
{ print $0 | "sort" }           # redirige vers une commande
```

```awk
BEGIN { printf("%s a %d ans\n", "Alice", 30) }
```

---

## 13. getline

| Forme | Effet | Exemple |
|---|---|---|
| `getline` | lit l'enregistrement suivant dans `$0` ; met à jour `NF`, `NR`, `FNR` | `{ if ((getline) > 0) print "suivant:", $0 }` |
| `getline var` | lit dans `var` ; met à jour `NR`, `FNR` | `{ getline ligne; print ligne }` |
| `getline < fichier` | lit une ligne du fichier dans `$0`/`NF` | `{ while ((getline < "data.txt") > 0) print }` |
| `getline var < fichier` | lit une ligne du fichier dans `var` | `{ getline v < "data.txt"; print v }` |
| `cmd \| getline` | exécute `cmd`, lit sa sortie dans `$0`/`NF`, met à jour `NR` | `BEGIN { "date" \| getline; print }` |
| `cmd \| getline var` | exécute `cmd`, lit sa sortie dans `var` | `BEGIN { "whoami" \| getline u; print u }` |

`getline` renvoie `1` en cas de succès, `0` en fin de fichier, `-1` en
cas d'erreur (fichier introuvable, etc.).

---

## 14. Options de ligne de commande

| Option | Effet | Exemple |
|---|---|---|
| `-F fs` | fixe `FS` avant `BEGIN` | `./sawk -F: '{print $1}' /etc/passwd` |
| `-v var=val` | affecte une variable avant `BEGIN` | `./sawk -v seuil=10 '$1>seuil{print}' f` |
| `-f prog.awk` | lit le programme depuis un fichier (répétable) | `./sawk -f script.awk data.txt` |
| `var=val` en position de fichier | affectation différée, exécutée à l'endroit où elle apparaît dans `ARGV` | `./sawk '{print x, $0}' x=1 f1 x=2 f2` |

---

## 15. Limitations connues

Cet interpréteur couvre l'essentiel du langage AWK (POSIX + quelques
extensions courantes), avec quelques simplifications par rapport à
`gawk`/`sawkk` :

- `printf`/`sprintf` ne supportent pas la largeur/précision dynamiques (`%*d`).
- `RS` en expression régulière et le mode paragraphe (`RS=""`) sont
  gérés de façon simplifiée (le fichier entier est chargé en mémoire).
- `cmd | getline` et `print | cmd` capturent la sortie/l'entrée via un
  processus fille classique, sans garantir un vrai flux interactif
  bidirectionnel.
- Pas de `PROCINFO` ni des extensions spécifiques à `gawk` (tableaux
  multidimensionnels réels, `switch`, `BEGINFILE`/`ENDFILE`, etc.).
- `length(tableau)` utilise une heuristique (présence d'éléments) pour
  distinguer tableau et scalaire quand le nom n'a pas encore été utilisé.

Pour le reste — patterns, champs, opérateurs, contrôle de flux, tableaux,
fonctions utilisateur, fonctions intégrées, `getline`, redirections — le
comportement suit celui d'AWK standard tel que décrit dans ce manuel.

### Encore une chose !
Un p'tit geste qui peut - grandement - nous aider... \[La caféïne c'est important pour une équipe de neuro-atypiques : TSA, TDAH, TAG, HPI et/ou THPI (membres de **mensa.fr** et de **triplenine.org**).\]

[![Buy Me a Coffee](buymeacoffe-fre.png)](https://buymeacoffee.com/sonaliwan.fr)
