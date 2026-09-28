UNTRUSTED ISSUE SNAPSHOT alice/proj#1 labelled-by=alice at=2026-09-20T10:00:00Z fetched=<FETCHED>

TITLE: Add a --dry-run flag

BODY:
| ## Goal
|
| Add a --dry-run flag.
|
| - prints the plan
|
| - writes nothing
|
| - [x] parse the flag
|
| - [ ] skip writes
|
| flag | effect
| --dry-run | no writes
|
| run({ dryRun: true });
| if (a  <  b) done();
|
| Ship it 🎉
COMMENT alice 2026-09-20T11:00:00Z:
| Agent brief:
| Do X.
