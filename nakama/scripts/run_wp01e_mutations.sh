#!/bin/sh
# VS-01 WP01-E E3 — mutation test of the claim transaction's write guards.
#
# For each guard W1-W7 of rpcEncounterClaim's settlement multiUpdate, two
# mutants are built in a TEMPORARY copy of nakama/ (the real source is never
# edited):
#   noversion  the guard's version check is removed (version "" = last write wins)
#   removed    the guard's write is removed from the transaction
# Each mutant is compiled and the WP01-E unit tests are run. A mutant is
# KILLED when at least one test fails. Prints a table; exits non-zero if any
# mutant SURVIVES or if the unmutated copy does not pass.
#
# Usage: nakama/scripts/run_wp01e_mutations.sh   (needs nakama/node_modules)
set -eu
NAKAMA_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cp -R "$NAKAMA_DIR/src" "$NAKAMA_DIR/tests" "$NAKAMA_DIR/package.json" "$NAKAMA_DIR/tsconfig.json" "$WORK/"
ln -s "$NAKAMA_DIR/node_modules" "$WORK/node_modules"
TESTS="tests/unit/wp01e_guards.test.mjs tests/unit/wp01e_commands.test.mjs tests/unit/wp01e_intent_recovery.test.mjs tests/unit/wp01e_parity.test.mjs"
ORIGINAL="$WORK/src/wp01e.ts.original"
cp "$WORK/src/wp01e.ts" "$ORIGINAL"

run_tests() {
	(cd "$WORK" && ./node_modules/.bin/tsc -p tsconfig.json >/dev/null 2>&1; node --test $TESTS > "$WORK/out.txt" 2>&1) && return 0 || return 1
}

echo "Baseline (no mutation):"
if run_tests; then
	echo "  baseline PASS ($(grep -E '^ℹ pass' "$WORK/out.txt"))"
else
	echo "  baseline FAILED: cannot judge mutants" >&2
	cat "$WORK/out.txt" >&2
	exit 2
fi

survived=0
printf "%-6s %-10s %-8s %s\n" "guard" "mutation" "result" "failing tests"
for guard in W1 W2 W3 W4 W5 W6 W7; do
	for kind in noversion removed; do
		cp "$ORIGINAL" "$WORK/src/wp01e.ts"
		python3 - "$WORK/src/wp01e.ts" "$guard" "$kind" <<'EOF'
import sys
path, guard, kind = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(path).read()
# Exact source fragments of the settlement transaction (rpcEncounterClaim).
W = {
  "W1": ('      eWrite(E_RECEIPT_COLLECTION, key, userId, receiptValue, "*"),                                        // W1\n',
         '      eWrite(E_RECEIPT_COLLECTION, key, userId, receiptValue, ""),\n'),
  "W2": ('      }, "*"),                                                                                              // W2\n',
         '      }, ""),\n'),
  "W3": ('eWithRevision(t, { status: "CLAIMED", resolved_at_ms: now0 }), ticket.version), // W3\n',
         'eWithRevision(t, { status: "CLAIMED", resolved_at_ms: now0 }), ""),\n'),
  "W4": ('      eWrite(E_STATE_COLLECTION, E_STATE_KEY, userId, nextState, stateObj === null ? "*" : stateObj.version), // W4\n',
         '      eWrite(E_STATE_COLLECTION, E_STATE_KEY, userId, nextState, ""),\n'),
  "W5": ('      eWrite(E_HERO_COLLECTION, E_HERO_KEY, userId, nextHero, heroObj === null ? "*" : heroObj.version),      // W5\n',
         '      eWrite(E_HERO_COLLECTION, E_HERO_KEY, userId, nextHero, ""),\n'),
  "W6": ('      eSessionGuard(userId, current),                                                                         // W6\n',
         '      progressWrite(userId, current.progress, ""),\n'),
  "W7": ('      decidedIntent,                                                                                          // W7\n',
         '      (function (w) { w.version = ""; return w; })(decidedIntent),\n'),
}
old, noversion = W[guard]
assert s.count(old) == 1, (guard, "fragment not found exactly once")
if kind == "noversion":
    s = s.replace(old, noversion)
elif guard == "W2":
    # the marker write spans 4 lines: remove the whole eWrite(...) call
    start = s.index("      eWrite(E_CLAIM_COLLECTION, ticketId, userId, {\n")
    end = s.index(old) + len(old)
    s = s[:start] + s[end:]
else:
    s = s.replace(old, "")
open(path, "w").write(s)
EOF
		if run_tests; then
			result="SURVIVED"; survived=$((survived + 1)); failing="-"
		else
			result="KILLED"
			failing="$(grep -E '^✖ ' "$WORK/out.txt" | grep -v '^✖ failing tests:' | sed -E 's/^✖ //; s/ \([0-9.]+ms\)$//' | sort -u | head -3 | tr '\n' ';' | cut -c1-200)"
		fi
		printf "%-6s %-10s %-8s %s\n" "$guard" "$kind" "$result" "$failing"
	done
done
cp "$ORIGINAL" "$WORK/src/wp01e.ts"
echo "Mutants survived: $survived of 14"
[ "$survived" -eq 0 ]
