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