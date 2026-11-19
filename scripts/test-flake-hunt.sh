#!/bin/zsh
# Runs the CameraKit suite K times: how many hang (no summary in 150 s), fail, pass, and which tests failed. For the
# loopback EADDRINUSE flake (docs/testing.md). Logs to $D/hk-<n>.log, and a hung run's threads to $D/hk-<n>.sample.txt.
# It builds once and every run uses that build: edits made meanwhile, and the rebuild they'd cost a run's 150 s, don't
# count (a run has hung that way). Don't build in the package while it runs.   K=20 scripts/test-flake-hunt.sh
D=${D:-${TMPDIR:-/tmp}/tiles-flake-hunt}; mkdir -p $D
F=/Library/Developer/CommandLineTools/Library/Developer/Frameworks; L=/Library/Developer/CommandLineTools/Library/Developer/usr/lib
FLAGS=(-Xswiftc -F$F -Xlinker -F$F -Xlinker -rpath -Xlinker $F -Xlinker -rpath -Xlinker $L)
K=${K:-20}; hung=0; failed=0; passed=0
cd "$(dirname "$0")/../Packages/CameraKit"
swift build --build-tests $FLAGS >/dev/null 2>&1
rm -f $D/hk-*.log(N) $D/hk-*.sample.txt(N); touch $D/.start
for r in $(seq 1 $K); do
  T=$D/hk-$r.log
  (swift test --skip-build $FLAGS > $T 2>&1; echo "EXIT $?" >> $T) & p=$!
  for i in $(seq 1 30); do kill -0 $p 2>/dev/null || break; sleep 5; done
  if kill -0 $p 2>/dev/null; then
    hung=$((hung+1))
    h=$(pgrep -f swiftpm-testing-helper | head -1)
    [[ -n $h ]] && sample $h 3 -file $D/hk-$r.sample.txt >/dev/null 2>&1
    pkill -f swiftpm-testing-helper; sleep 3; wait $p 2>/dev/null
  # Its exit, not Swift Testing's summary alone: that says passed with an XCTest (the VENICE suites) failed.
  elif grep -q '^EXIT 0$' $T; then passed=$((passed+1))
  else failed=$((failed+1)); fi
done
echo "$K runs: $passed passed, $failed failed, $hung hung"
grep -h 'recorded an issue' $D/hk-*.log | sed -E 's/.*Test "([^"]{0,60}).*recorded an issue at ([^:]+:[0-9]+).*/\1 @ \2/' | sort | uniq -c | sort -rn | head -8
grep -h -E 'error: -\[[A-Za-z]+\.[A-Za-z]+ [A-Za-z0-9_]+\]' $D/hk-*.log | sed -E 's/.*error: -\[([^]]+)\].*/\1 (XCTest)/' | sort | uniq -c | sort -rn | head -5
# A run that crashed records no issue: the test it was in, and the crash report's place.
for f in $D/hk-*.log(N); do
  grep -q '^EXIT 0$' $f && continue
  grep -q 'recorded an issue' $f && continue
  grep -q -E 'error: -\[' $f && continue
  echo "   crashed or cut off, $(basename $f): last started $(grep -o 'Test "[^"]*" started' $f | tail -1 | cut -c6-70)" \
    "$(grep -m1 'Fatal error' $f | cut -c1-90)"
done
find ~/Library/Logs/DiagnosticReports -name 'swiftpm-testing-helper-*.ips' -newer $D/.start 2>/dev/null | sed 's/^/   crash report: /' 
