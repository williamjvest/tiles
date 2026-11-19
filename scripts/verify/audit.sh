#!/bin/zsh
# The render audit: the tile gallery at every Text Size, Standardized and Dynamic, and real pages of each camera
# lineup at phone and iPad sizes, Text Sizes and appearances, each with the alignment audit (nothing cut off, every
# tile lined up). Prints the renders that aren't clean, then a count; exits 1 if any.
#
#   scripts/verify/audit.sh [out-dir]          (default qa-out/audit; about 1,500 renders, 6 at a time)
#   AUDIT_LIMIT=20 scripts/verify/audit.sh      (the first 20: a quick look that the audit runs)
set -u
R=$(cd "$(dirname "$0")/../.." && pwd)
OUT=${1:-$R/qa-out/audit}
WORK=$(mktemp -d)
trap 'rm -rf $WORK' EXIT
(cd $R/Packages/CameraKit && swift build --product dashboard-snapshot --build-path $WORK/build >/dev/null 2>&1) \
  || { echo "dashboard-snapshot didn't build"; exit 2; }
B=$WORK/build/arm64-apple-macosx/debug/dashboard-snapshot
rm -rf $OUT && mkdir -p $OUT

jobs=$WORK/jobs
: > $jobs
for scale in 1.0 1.1 1.2 1.3 1.4 1.5; do
  for dyn in - dynamic; do echo "g $scale $dyn - - 0x0" >> $jobs; done
done
for scale in 1.0 1.2 1.5; do for dyn in - dynamic; do for look in - custom; do
  for bodies in venice2 fx3 fx6 burano alexaMini pyxis12k venice2,fx3 venice2,fx6 venice2,venice2,fx3,burano; do
    for size in 393x759 759x372 375x647 647x375 393x852 852x393 402x874 874x402 1180x820 820x1180 1366x1024 1024x1366 \
                1133x744 744x1133; do
      echo "p $scale $dyn $look $bodies $size" >> $jobs
    done
  done
done; done; done

export B OUT
render() {  # kind scale dyn look bodies size; "-" for none
  local kind=$1 scale=$2 dyn=$3 look=$4 bodies=$5 size=$6
  local name="$kind-$scale-$dyn-$look-${bodies//,/-}-$size"
  local -a e=(CC_SNAPSHOT_TEXT_SCALE=$scale)
  [ $dyn != - ] && e+=(CC_SNAPSHOT_TEXT_SIZE=dynamic)
  [ $look != - ] && e+=(CC_SNAPSHOT_APPEARANCE=custom)
  if [ $kind = g ]; then
    env CC_SNAPSHOT_SCALE=1 $e $B $OUT/$name.png 0 0 "" gallery > $OUT/$name.log 2>&1
  else
    if [ $bodies = pyxis12k ]; then e+=(CC_SNAPSHOT_PYXIS=1); else e+=(CC_SNAPSHOT_BODIES=$bodies); fi
    env CC_SNAPSHOT_AUDIT=1 $e $B $OUT/$name.png ${size%x*} ${size#*x} "" window > $OUT/$name.log 2>&1
  fi
  grep -q "every tile lines up" $OUT/$name.log || echo "NOT CLEAN $name: $(grep -m2 ALIGNMENT $OUT/$name.log | tr '\n' ' ')"
}
typeset -f render > $WORK/render.zsh
head -n ${AUDIT_LIMIT:-100000} $jobs | xargs -P 6 -L 1 zsh -c "source $WORK/render.zsh; render \"\$@\"" _
total=$(ls $OUT/*.log | wc -l | tr -d ' ')
bad=$(grep -L "every tile lines up" $OUT/*.log | wc -l | tr -d ' ')
echo "audit: $total renders, $bad not clean"
[ $bad -eq 0 ]
