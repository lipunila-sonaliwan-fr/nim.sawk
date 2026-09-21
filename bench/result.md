# Practical AWK Benchmarking
## Performance Analysis (with Pareto Frontier tests suite: [AwkLab](https://awklab.com/practical-awk-benchmarking))

The workload consisted of a 179 MB CSV dataset containing 1.5 million lines and 14 fields: [1500000\ Sales\ Records.csv](https://excelbianalytics.com/wp/wp-content/uploads/2017/07/1500000%20Sales%20Records.zip). Place the downloaded file in the "bench" folder to run the test yourself (from this folder).

**mac mini M1, macOS Tahoe 26.6.2, native AWK 20200816 → macOS**

awk --version
```
awk version 20200816
```

**mac mini M1, macOS Tahoe 26.6.2, Nim AWK 1.0.2 → sawk.nim**

../awk --version
```
                   _
 _____      ____ _| | __
/ __\ \ /\ / / _` | |/ /
\__ \\ V  V / (_| |   < https://lipunila.sonaliwan.fr
|___/ \_/\_/ \__,_|_|\_\1.0.2
usage: sawk [-F fs] [-v var=val] 'program' [file ...]
       sawk [-F fs] [-v var=val] -f progfile [file ...]
```

## 1 Benchmark: duplicate lines

**macOS**

time awk -F, 'x\[$0\]++ { i++ } END { print i }' 1500000\ Sales\ Records.csv
```
108603
5.30s user 0.08s system 99% cpu 5.393 total
```

**sawk.nim**

time ../sawk -F, 'x\[$0\]++ { i++ } END { print i }' 1500000\ Sales\ Records.csv
```
108603
3.09s user 0.09s system 99% cpu 3.190 total
```

## 2 Benchmark: most units sold by country

**macOS**

time awk -F, 'NR > 1 && !x\[$0\]++ { u\[$2\] += $9 } END { for (i in u) if (u\[i\] > u_max) { u_max = u\[i\]; c = i }  print c, u_max }' 1500000\ Sales\ Records.csv
```
New Zealand 38560755
5.52s user 0.10s system 99% cpu 5.630 total
```
**sawk.nim**

time ../sawk -F, 'NR > 1 && !x\[$0\]++ { u\[$2\] += $9 } END { for (i in u) if (u\[i\] > u_max) { u_max = u\[i\]; c = i }  print c, u_max }' 1500000\ Sales\ Records.csv
```
New Zealand 38560755
4.42s user 0.11s system 99% cpu 4.537 total
```

## 3 Benchmark: highest profit margin

**macOS**

time awk -F, 'NR > 1 { pm = ($10 - $11) / $10; if (pm > pm_max) { pm_max = pm; id = $7 }} END { print id }' 1500000\ Sales\ Records.csv
```
667593514
4.22s user 0.07s system 99% cpu 4.305 total
```
**sawk.nim**

time ../sawk -F, 'NR > 1 { pm = ($10 - $11) / $10; if (pm > pm_max) { pm_max = pm; id = $7 }} END { print id }' 1500000\ Sales\ Records.csv
```
667593514
2.62s user 0.06s system 99% cpu 2.685 total
```

## 4 Benchmark: count European countries

**macOS**

time awk -F, '$1 == "Europe" { eu[$2]++ } END { for (country in eu) n++; print n }' 1500000\ Sales\ Records.csv
```
48
4.28s user 0.05s system 99% cpu 4.336 total
```
**sawk.nim**

time sawk -F, '$1 == "Europe" { eu[$2]++ } END { for (country in eu) n++; print n }' 1500000\ Sales\ Records.csv
```
48
2.07s user 0.06s system 99% cpu 2.136 total
```

## 5 Benchmark: count European countries (regex)

**macOS**

time awk -F, '$1 ~ /Europe/ { eu\[$2\]++ } END { for (country in eu) n++; print n }' 1500000\ Sales\ Records.csv
```
48
4.31s user 0.06s system 99% cpu 4.378 total
```
**sawk.nim**

time ../sawk -F, '$1 ~ /Europe/ { eu[$2]++ } END { for (country in eu) n++; print n }' 1500000\ Sales\ Records.csv
```
48
2.72s user 0.06s system 99% cpu 2.790 total
```

## 6 Benchmark: number of orders in date range

**macOS**

time awk -F, 'NR > 1 && !x\[$0\]++ { split($6, a, "/"); d = sprintf("%d%02d%02d", a\[3\], a\[1\], a\[2\]); if (d >= "20140301" && d <= "20150331") n++ } END { print n }' 1500000\ Sales\ Records.csv
```
203060
7.33s user 0.11s system 99% cpu 7.456 total
```
**sawk.nim**

time ../sawk -F, 'NR > 1 && !x\[$0\]++ { split($6, a, "/"); d = sprintf("%d%02d%02d", a[3], a[1], a[2]); if (d >= "20140301" && d <= "20150331") n++ } END { print n }' 1500000\ Sales\ Records.csv
```
203060
6.62s user 0.12s system 99% cpu 6.757 total
```

## Conclusion
sawk.nim rocks!
