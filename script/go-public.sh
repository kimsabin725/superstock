#!/bin/bash
# Flip the repo public — but only once it is safe to.
# Nothing here is automatic: run it, read the checks, then say yes.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
REPO="kimsabin725/superstock"
fail=0

check() { # $1 label, $2 actual, $3 expected
  if [ "$2" = "$3" ]; then printf "  ok    %-42s %s\n" "$1" "$2"
  else printf "  FAIL  %-42s %s (expected %s)\n" "$1" "$2" "$3"; fail=1; fi
}

echo "=== leak checks ==="
check "commit authors are personal only" \
  "$(git log --format='%ae %ce' | tr ' ' '\n' | sort -u | grep -vc 'kimsabin725@naver.com')" "0"
EMPLOYER_RE=$(printf '%s' 'a29yZWFpbnZlc3RtZW50' | base64 -d)   # kept encoded so this file
PERSON_RE=$(printf '%s' 'a2lyYWNsMDE=' | base64 -d)               # never matches its own check
check "employer identifiers in history" \
  "$(git log -p --all 2>/dev/null | grep -icE "$EMPLOYER_RE|$PERSON_RE")" "0"
check "forbidden files tracked" \
  "$(git ls-files | grep -cEi '\.env$|\.key$|keeper\.db|\.jsonl$|\.out$|\.err$|__pycache__')" "0"
check "local paths leaked" \
  "$(git grep -l "/$(printf Users)/" -- . ':!script/go-public.sh' 2>/dev/null | wc -l | tr -d ' ')" "0"
check "working tree clean" "$(git status --porcelain | wc -l | tr -d ' ')" "0"
check "pushed up to date" "$(git rev-list --count origin/main..HEAD 2>/dev/null)" "0"

echo "=== it has to work for whoever clones it ==="
export PATH="$PATH:$HOME/.foundry/bin"
forge test >/dev/null 2>&1 && echo "  ok    contracts" || { echo "  FAIL  contracts"; fail=1; }
./.venv/bin/python keeper/test_keeper.py >/dev/null 2>&1 && echo "  ok    keeper" || { echo "  FAIL  keeper"; fail=1; }
(cd web && pnpm lint >/dev/null 2>&1) && echo "  ok    web lint" || { echo "  FAIL  web lint"; fail=1; }
# A run still in flight is not a pass; wait it out rather than guess.
while [ "$(gh run list --repo "$REPO" --limit 1 --json status --jq '.[0].status' 2>/dev/null)" != "completed" ]; do
  echo "  ...  waiting for CI"
  sleep 20
done
CI=$(gh run list --repo "$REPO" --limit 1 --json conclusion --jq '.[0].conclusion' 2>/dev/null)
check "latest CI run" "$CI" "success"

echo
if [ "$fail" -ne 0 ]; then
  echo "Not going public: fix the failures above first."
  exit 1
fi

echo "All clear. Going public makes this visible to everyone, and that cannot be quietly undone."
read -r -p "Type PUBLIC to confirm: " answer
[ "$answer" = "PUBLIC" ] || { echo "Left private."; exit 1; }

gh repo edit "$REPO" --visibility public --accept-visibility-change-consequences \
  && echo "Public: https://github.com/$REPO"
