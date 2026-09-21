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