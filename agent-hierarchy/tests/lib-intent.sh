# Helpers for tests that dispatch to a review-class role, sourced by the suites.

# fill_intent <request path> [goal] [acceptance]: puts text on the `[1] goal` and `[5] acceptance` tldr lines of a fresh skeleton.
fill_intent() {
  GOAL="${2-deliver the stated change}" ACC="${3-the stated checks pass}" perl -pi -e 's/^- \[1\] goal: $/- [1] goal: $ENV{GOAL}/; s/^- \[5\] acceptance: $/- [5] acceptance: $ENV{ACC}/' "$1"
}
