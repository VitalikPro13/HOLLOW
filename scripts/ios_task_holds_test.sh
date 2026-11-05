#!/bin/bash
# Tests for the counted background task's holds in ios/Runner/AppDelegate.swift
# (the TaskHolds struct between its markers), compiled on their own: an end that
# arrives after an expiry is spent on the hold that expiry ended, never on a task
# taken since, so a storage write never loses its task to an old write's end.
#
#   bash scripts/ios_task_holds_test.sh
set -euo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd)/ios/Runner/AppDelegate.swift"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
sed -n '/^\/\/ TASK-HOLDS-BEGIN$/,/^\/\/ TASK-HOLDS-END$/p' "$SRC" >"$W/holds.swift"
grep -q 'struct TaskHolds' "$W/holds.swift" || { echo "FAIL: no TaskHolds between the markers in $SRC"; exit 1; }
cat >"$W/main.swift" <<'SWIFT'
import Foundation

var failed = 0
func check(_ name: String, _ ok: Bool) {
  print("\(ok ? "PASS" : "FAIL"): \(name)")
  if !ok { failed += 1 }
}

var a = TaskHolds()
a.take()
check("one hold ends the task at its end", a.release())

var b = TaskHolds()
b.take(); b.take()
check("overlapping holds keep the task until the last end", !b.release() && b.release())

// Two writes held the task when iOS expired it; a third begins, then the two
// old ends arrive before its own.
var c = TaskHolds()
c.take(); c.take()
c.expire()
c.take()
check("an old end after an expiry never ends a newer task", !c.release() && !c.release())
check("the newer task ends at its own end", c.release())

var d = TaskHolds()
d.take()
d.expire()
check("an old end after an expiry with no newer task ends nothing", !d.release())
d.take()
check("and a task taken after it ends at its own end", d.release())

var e = TaskHolds()
check("an end with no hold leaves nothing held", e.release() && e.live == 0)

if failed > 0 { exit(1) }
SWIFT
xcrun swiftc -o "$W/holds" "$W/holds.swift" "$W/main.swift"
"$W/holds"
