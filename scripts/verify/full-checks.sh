#!/bin/zsh
# The full verification suite: the package tests twice, the control API end to end, the VENICE gate against a base
# commit, the render audit, the Mac app's build with its warnings counted, the UI suite on an iPad mini, a 13-inch
# iPad Pro and an iPhone 17 Pro, then Stream Deck and Companion (with lint). Every step runs whatever the one before
# did; each step's summary goes to <out> as it ends, its whole log to <out>.d/. About an hour to run.
#
#   scripts/verify/full-checks.sh <base-commit> [out]     (default qa-out/full-checks.out)
#
# Run it in a worktree of the commit to ship, so the main tree stays free:
#   git worktree add /tmp/tiles-checks <commit> && /tmp/tiles-checks/scripts/verify/full-checks.sh <base> /tmp/checks.out
# Known flakes (docs/testing.md): api-e2e's demo server sometimes never answers (it's run again once here); Stream
# Deck's port 54111 EADDRINUSE; a preset test's timing under load. Run a failed one again alone before believing it.
set -u
BASE=${1:?usage: scripts/verify/full-checks.sh <base-commit> [out]}
R=$(cd "$(dirname "$0")/../.." && pwd)
OUT=${2:-$R/qa-out/full-checks.out}
LOGS=$OUT.d
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
mkdir -p $LOGS && : > $OUT
step() { echo "== $1 ($(date +%H:%M:%S))" >> $OUT; }
note() { print -r -- "$1" >> $OUT; }

# The plugins' packages, which api-e2e also uses (the ws package from the Companion module): a fresh worktree has none.
for plugin in streamdeck companion-module; do
  [ -d $R/integrations/$plugin/node_modules ] || (cd $R/integrations/$plugin && npm ci --silent > $LOGS/npm-$plugin.log 2>&1)
done

for n in 1 2; do
  step swift-test-$n
  (cd $R/Packages/CameraKit && swift test > $LOGS/swift-test-$n.log 2>&1; echo "EXIT $?" >> $LOGS/swift-test-$n.log)
  grep -E "Test run with|Executed [0-9]+ tests|✘|^EXIT" $LOGS/swift-test-$n.log | sort -u | tail -6 >> $OUT
done

api_e2e() {  # <log>: the demo server, built first so it answers within the wait, then the contract check against it
  (cd $R/Packages/CameraKit && swift build --product twcc-api-demo > $1.build 2>&1) || { echo "demo didn't build" > $1; return 1; }
  (cd $R/Packages/CameraKit && TWCC_API_TOKEN=demo-token swift run --skip-build twcc-api-demo > $1.server 2>&1) &
  local server=$!
  for i in $(seq 1 180); do nc -z 127.0.0.1 51800 2>/dev/null && break; sleep 1; done
  # Then until its demo cameras have connected: run straight away, the first camera may still be "connecting", with no
  # model or fields, and the check stops early.
  for i in $(seq 1 30); do
    local st=$(curl -s -m 2 -H 'X-TWCC-Token: demo-token' http://127.0.0.1:51801/state)
    [ -n "$st" ] && ! print -r -- "$st" | grep -q '"connecting"' && break
    sleep 1
  done
  node $R/scripts/api-e2e.mjs > $1 2>&1
  local rc=$?
  pkill -f twcc-api-demo 2>/dev/null; kill $server 2>/dev/null; wait $server 2>/dev/null
  return $rc
}
step api-e2e
api_e2e $LOGS/api-e2e.log || { tail -2 $LOGS/api-e2e.log >> $OUT; note "again:"; api_e2e $LOGS/api-e2e-2.log; }
tail -1 $LOGS/api-e2e*.log(om[1]) >> $OUT

step venice-gate
$R/scripts/verify/venice-gate.sh $BASE $LOGS/venice-gate > $LOGS/venice-gate.log 2>&1
grep -v "^$" $LOGS/venice-gate.log | tail -12 >> $OUT

step audit
$R/scripts/verify/audit.sh $LOGS/audit > $LOGS/audit.log 2>&1
tail -3 $LOGS/audit.log >> $OUT

step mac-build
(cd $R/App && xcodegen generate --quiet && xcodebuild build -project CameraControl.xcodeproj -scheme CameraControl \
  -destination 'generic/platform=macOS' CODE_SIGNING_ALLOWED=NO > $LOGS/mac-build.log 2>&1)
grep -E "BUILD (SUCCEEDED|FAILED)" $LOGS/mac-build.log | tail -1 >> $OUT
note "mac warnings: $(grep -E ': warning: ' $LOGS/mac-build.log | grep -v '/SourcePackages/' | sort -u | wc -l | tr -d ' ')"

(cd $R/App && xcodegen generate --spec uitest.yml --quiet)
for device in "iPad mini (A17 Pro)" "iPad Pro 13-inch (M5)" "iPhone 17 Pro"; do
  name=${${device//[()]/}// /_}
  step ui-$name
  rm -rf $LOGS/ui-$name.xcresult
  (cd $R/App && xcodebuild test -project CameraControl.xcodeproj -scheme TilesUITests \
    -destination "platform=iOS Simulator,name=$device" -resultBundlePath $LOGS/ui-$name.xcresult > $LOGS/ui-$name.log 2>&1)
  grep -E "Executed [0-9]+ tests|TEST (SUCCEEDED|FAILED)|error: -\[" $LOGS/ui-$name.log | sort -u | tail -6 >> $OUT
done
(cd $R/App && xcodegen generate --quiet)   # the shipping project again

for plugin in streamdeck companion-module; do
  step $plugin
  # --forceExit: when Companion's two port tests can't listen (ports held by another process), jest finishes and
  # then never exits on their open handles.
  (cd $R/integrations/$plugin && npm test -- --forceExit > $LOGS/$plugin.log 2>&1;
   echo "EXIT $?" >> $LOGS/$plugin.log)
  grep -E "^Tests:|^Test Suites:|^EXIT" $LOGS/$plugin.log >> $OUT
done
step companion-lint
(cd $R/integrations/companion-module && npm run lint > $LOGS/companion-lint.log 2>&1; echo "EXIT $?" >> $LOGS/companion-lint.log)
tail -2 $LOGS/companion-lint.log >> $OUT
step done
