function max(v1,v2) {
  return v1>v2 ? v1 : v2;
}
BEGIN {
  print max("12","34");
  print max(100,34);
  print max(100,"34");
}
