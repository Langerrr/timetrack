# Reconstructs time from an event log. Reads concatenated TSVs on stdin.
#   -v since=EPOCH  -v upto=EPOCH  -v gap=SECONDS  -v byday=0|1  -v detail=0|1
BEGIN { FS = "\t" }

# Registering a bucket separately from adding to it keeps a project visible at
# zero when its events never form an interval.
function touch(bucket) {
  if (!(bucket in seen)) { seen[bucket] = 1; keys[++nkeys] = bucket }
}

function add(bucket, mode, secs) {
  touch(bucket)
  tot[bucket, mode] += secs
}

function hm(s,   h, m) {
  h = int(s / 3600); m = int((s % 3600) / 60)
  return sprintf("%dh %02dm", h, m)
}

NF < 11 { next }
{
  start = $3 + 0
  if (start < since || start > upto) next

  key = $8
  if (detail && $9 != ".") key = $8 "/" $9
  bucket = byday ? substr($1, 1, 10) : key

  if ($2 == "span") { add(bucket, $7, $4 - $3); next }

  touch(bucket)
  sk = $5 SUBSEP $10 SUBSEP $8 SUBSEP $9
  if (sk in last) {
    d = start - last[sk]
    if (d > 0 && d <= gap) add(prevbucket[sk], prevmode[sk], d)
  }
  last[sk] = start; prevbucket[sk] = bucket; prevmode[sk] = $7
}

END {
  # Insertion sort. The key count is small, and this avoids depending on gawk.
  for (i = 2; i <= nkeys; i++) {
    v = keys[i]; j = i - 1
    while (j >= 1 && keys[j] > v) { keys[j + 1] = keys[j]; j-- }
    keys[j + 1] = v
  }

  w = 7
  for (i = 1; i <= nkeys; i++) if (length(keys[i]) > w) w = length(keys[i])
  fmt = "%-" w "s  %9s %9s %9s %9s\n"

  printf fmt, (byday ? "DAY" : "PROJECT"), "PAIRED", "SOLO", "MANUAL", "TOTAL"
  gp = 0; gs = 0; gm = 0
  for (i = 1; i <= nkeys; i++) {
    k = keys[i]
    p = tot[k, "paired"] + 0; s = tot[k, "solo"] + 0; m = tot[k, "manual"] + 0
    gp += p; gs += s; gm += m
    printf fmt, k, hm(p), hm(s), hm(m), hm(p + s + m)
  }
  if (nkeys > 0) printf fmt, "TOTAL", hm(gp), hm(gs), hm(gm), hm(gp + gs + gm)
  else print "no events in range"
}
