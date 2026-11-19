#!/bin/zsh
# The VENICE gate: the same VENICE pages rendered at a base commit and at the working tree, compared pixel by pixel.
# Any difference fails it. Run it before a build whenever a change could reach a VENICE's pages, and expect only the
# differences the change means to make.
#
#   scripts/verify/venice-gate.sh <base-commit> [out-dir]
#
# Builds dashboard-snapshot twice (the base in a temporary worktree), renders each page with both into
# <out-dir>/base and <out-dir>/head (default qa-out/venice-gate), and prints one line per page.
set -u
BASE=${1:?usage: scripts/verify/venice-gate.sh <base-commit> [out-dir]}
R=$(cd "$(dirname "$0")/../.." && pwd)
OUT=${2:-$R/qa-out/venice-gate}
WORK=$(mktemp -d)
trap 'git -C $R worktree remove --force $WORK/base 2>/dev/null; rm -rf $WORK' EXIT

build() {  # <source root> <build path>: echoes the binary
  (cd $1/Packages/CameraKit && swift build --product dashboard-snapshot --build-path $2 >/dev/null 2>&1) || return 1
  echo $2/arm64-apple-macosx/debug/dashboard-snapshot
}

# name | env | width height | mode
PAGES=(
  "v2-ipad-land|CC_SNAPSHOT_BODIES=venice2|1180 820|window"
  "v2-ipad-port|CC_SNAPSHOT_BODIES=venice2|820 1180|window"
  "v2-ipadpro|CC_SNAPSHOT_BODIES=venice2|1366 1024|window"
  "v2-phone-land|CC_SNAPSHOT_BODIES=venice2|852 393|window"
  "v2-phone-port|CC_SNAPSHOT_BODIES=venice2|393 852|window"
  "v2-edit|CC_SNAPSHOT_BODIES=venice2|1180 820|edit"
  "v2-editor|CC_SNAPSHOT_BODIES=venice2|820 1180|camera-editor"
  "v2-settings|CC_SNAPSHOT_BODIES=venice2|820 1180|settings"
  "v2-locked|CC_SNAPSHOT_BODIES=venice2 CC_SNAPSHOT_LOCKED=1|1180 820|window"
  "v2-tall|CC_SNAPSHOT_BODIES=venice2 CC_SNAPSHOT_TALL=6|1180 820|window"
  "v2-test-mode|CC_SNAPSHOT_BODIES=venice2 CC_SNAPSHOT_TEST_MODE=1 CC_SNAPSHOT_NOTICE=live|1180 820|window"
  "v2-fx3|CC_SNAPSHOT_BODIES=venice2,fx3|1366 1024|window"
  "v2x2|CC_SNAPSHOT_BODIES=venice2,venice2|1366 1024|window"
)

render() {  # <binary> <dir>
  mkdir -p $2
  for page in $PAGES; do
    local name=${page%%|*} rest=${page#*|}
    local envs=${rest%%|*}; rest=${rest#*|}
    local size=${rest%%|*} mode=${rest#*|}
    env ${=envs} $1 $2/$name.png ${=size} "" $mode > $2/$name.log 2>&1
  done
}

git -C $R worktree add -q --detach $WORK/base $BASE || exit 2
BASE_BIN=$(build $WORK/base $WORK/build-base) || { echo "the base didn't build"; exit 2; }
HEAD_BIN=$(build $R $WORK/build-head) || { echo "the working tree didn't build"; exit 2; }
rm -rf $OUT/base $OUT/head
render $BASE_BIN $OUT/base
render $HEAD_BIN $OUT/head

failed=0
for page in $PAGES; do
  name=${page%%|*}
  result=$(python3 $R/scripts/verify/pixdiff.py $OUT/base/$name.png $OUT/head/$name.png $OUT/$name-diff.png)
  [ $? -eq 0 ] || failed=1
  echo "$name: ${result%%$'\n'*}"
done
exit $failed
