# Windows snapshot read-bound verification

Audience: maintainer verification.

This record holds the platform evidence behind `fm_timeout_spawn_scale` in `bin/fm-timeout-lib.sh` and the scaled bounded-read defaults in `bin/fm-fleet-snapshot.sh`.
Those files own the rule and the mechanics; this record owns why an order-of-magnitude larger default is the correct bound on Windows rather than a weakened one, because CI never runs there.
Re-establish it after a Git for Windows or MSYS runtime upgrade, or after any change to what a bounded read forks.

Verified 2026-08-26 on Windows 11 (10.0.26200) with `git version 2.51.0.windows.2`, `jq-1.8.2` (the winget native build), and Microsoft Defender real-time protection active.

## What the bounds are actually spending

A snapshot's bounded reads are short shell pipelines, so their wall clock is process-spawn cost, not work.
The registered-secondmate-table read forks the bound runner, the two shells it wraps the command in, and then `head`, `wc`, `head`, `awk`, `head`, `awk` and three `jq` passes - about a dozen spawns to parse a one-line file.

On this host a single spawn is not free:

```sh
$ time (for i in 1 2 3 4 5; do jq -n '1' >/dev/null; done)
real    0m5.733s
```

That is ~1.1s per `jq`, against ~1ms on a Linux or macOS host, and `/usr/bin/true`, `awk`, and `head` measured in the same range.
The cost is the Windows exec path with real-time AV in it, not the command.

## The read that the 2-second default was cutting off

Timing the registry read in place, against a `data/secondmates.md` holding exactly one registration, with the bound lifted to 300s so the read always completes:

```sh
REGISTRY_READ_MS=18863 rc=0
REGISTRY_READ_MS=15054 rc=0
REGISTRY_READ_MS=22313 rc=0
```

15-22s for the cheapest possible healthy read, against a 2s default.
Sweeping the bound confirms nothing below that range ever completes; each value is three runs of the real snapshot:

```
registry_timeout=2s  -> available true in 0/3 runs
registry_timeout=3s  -> available true in 0/3 runs
registry_timeout=4s  -> available true in 0/3 runs
registry_timeout=6s  -> available true in 0/3 runs
registry_timeout=8s  -> available true in 0/3 runs
registry_timeout=12s -> available true in 0/3 runs
```

The nested `--secondmate-home-summary` a parent runs per registered home, against an empty fixture home, costs ~13.0s and ~13.2s against its own 8s default.

So on this platform every one of these defaults reported a perfectly healthy read as timed out.
`tests/fm-bearings-snapshot.test.sh` failed here at `de65bba` and at older commits for exactly that reason, and a captain running Bearings on Windows got a permanently unavailable registry.

## Why the answer is a scaled default, not a longer one everywhere

A single larger constant would throw away a bound that is correct and useful on the hosts CI and most captains run, and pin the whole fleet to the slowest platform.
Suite-level overrides of the env knobs would turn the tests green while leaving a real Windows captain with the same broken snapshot, which is the defect, not the symptom.
Scaling the default by host keeps one meaning everywhere - far longer than a healthy read, still finite - and leaves POSIX hosts at the values they already had.

`FM_TIMEOUT_SPAWN_SCALE_MSYS` is 20, so the 2s reads bound at 40s.
40s is ~1.8x the slowest healthy read observed above, measured while a second snapshot was competing for the same host, and the sweep shows the healthy read never approaches it.
A wedged read is therefore cut loose 20x slower on Windows than on Linux, which is the same factor by which everything else on this host is slower; the worst case stays bounded, which is the property the bound exists for.

The same scale is applied to `FM_SNAPSHOT_SECONDMATE_TIMEOUT`, which is right in kind but not sufficient: that bound wraps a nested snapshot whose cost grows with the number of children, so 160s does not cover a home of any real size. See the first entry under "Two defects this scaling does NOT fix".

Only defaults are scaled. A bound named in the environment is used exactly as given, which is what keeps `FM_SNAPSHOT_SECONDMATE_TIMEOUT=1`-style wedge fixtures honest.

## Why the host comes from $OSTYPE and not uname

Everywhere else in this repo the host question is `uname -s`, and `bin/fm-path-lib.sh` owns that answer.
`fm_timeout_spawn_scale` deliberately reads `$OSTYPE` instead, for two reasons that are specific to what this answer is used for.

`uname` is a spawn, and a spawn is the exact cost this function exists to price - on this host that one call is a measurable fraction of the bound it is being consulted about, while bash sets `$OSTYPE` at build time and reading it costs nothing.

More importantly, `uname` is answerable from `PATH`.
`test_gnu_stat_uses_file_formats_without_bsd_fallback_pollution` shims `uname` to print `Linux` so it can pin the GNU-vs-BSD `stat` split, and with the scale read through `uname` that shim silently handed back 1x - putting every bound in that fixture back at 2s and making the authoritative secondmate summary unreadable on this host, a failure with no visible connection to the shim.
`$OSTYPE` cannot be reached that way.
`test_scaled_read_bounds_still_release_a_wedged_reader` pins it directly: a `uname` stub on `PATH` must not move the scale.

## What proves the bound still bounds

`test_scaled_read_bounds_still_release_a_wedged_reader` in `tests/fm-bearings-snapshot.test.sh` wedges the registry reader at its own `head` - the shim sleeps only for `secondmates.md`, so every other read behaves - and runs the snapshot with the production scaled default.
The snapshot still answers, with the registry disclosed as `freshness: unavailable` and a reason containing "timed out".

It asserts conditions, never elapsed seconds.
On a host where a healthy read costs 15-22s and process scheduling is this noisy, a wall-clock bound in a test proves nothing about the code and flakes on the host; that rule applies to every assertion in a suite that must pass here.

`test_perl_fallback_bounds_github_call` was the one assertion in this suite that broke the rule: it timed the whole Bearings run and required `elapsed -lt 10`, which no run on this host can satisfy whatever the bound does.
It now asserts what the test is actually named for instead - that the fixture `PATH` selects the `perl` mechanism, and that the stalled call is disclosed as unavailable.
That pair is strictly stronger than the clock was: the `gh` stub sleeps and then answers with a valid PR payload, so an unbounded call would report available PRs and only a bound that fired can produce "unavailable".

## Two fixtures that encoded the same fast-POSIX-host assumption

Scaling the defaults fixed the snapshot but not the whole suite, because two fixtures asserted host behaviour of their own.

`chmod` does not stick on this mount. Git Bash mounts the temp dir `noacl`, so the bits are accepted and then ignored:

```sh
$ echo data > "$t"; chmod 000 "$t"; stat -c '%a' "$t"
444
$ cat "$t" >/dev/null && echo "still readable"
still readable
$ mkdir "$d/data"; chmod 000 "$d/data"; stat -c '%a' "$d/data"
755
```

Both unreadability fixtures in `tests/fm-bearings-snapshot.test.sh` depended on that, and both silently produced a perfectly readable subject instead - the `unreadable` home stayed valid and then reported "structured home snapshot timed out", a reason with no visible connection to the fixture.
They now probe once with `posix_modes_stick` and take a portable route where the bits do not stick: a `data` path that is not a directory, which lands in the same `validate_operational_dirs` branch, and a `stat` shim answering the mode probe the snapshot actually consults.
Where the filesystem does enforce permissions - CI, and any POSIX host - the fixtures are unchanged.

A bound a fixture sets is not scaled, by design, and one fixture needed it to be. `test_bad_secondmate_homes_never_revive_parent_work` pinned `FM_SNAPSHOT_SECONDMATE_TIMEOUT=1` to wedge one home out of five; on this host that is below what the four healthy homes cost, so the `malformed` home timed out instead of reporting its unstructured row.
The bound has to sit above a healthy summary and below the wedged one, and only the first half is host-dependent, so the fixture now scales its own unit - `2 * spawn_scale`, still 2s on CI - and the `no-mistakes` stub it wedges on sleeps well past any scaled bound rather than 30s.

## Two defects this scaling does NOT fix

Both were masked by the 2s bounds: every read failed as "timed out" before either could be reached.
Both are separate root causes, and neither is a test artifact - each breaks the snapshot for a real Windows captain.

### The nested home summary is O(children), so no constant bounds it

`FM_SNAPSHOT_SECONDMATE_TIMEOUT` wraps a whole nested `--secondmate-home-summary`, not a short pipeline, and that nested snapshot re-probes every child.
Measured on this host, same fixture shape, bound lifted:

| children in the home | summary wall clock |
|---:|---:|
| 0 | ~13s |
| 1 | ~80s |
| 3 | ~182s |

That is roughly `13 + 56 * children` seconds.
The scaled default is `8 * 20 = 160s`, which covers about two children; `test_secondmate_and_child_bounds_are_disclosed` builds a three-child home and still times out at 160s.
A single multiplicative constant cannot bound a cost that grows with fan-out: covering ten children needs ~10 minutes, and a parent may hold twenty such homes.
This one needs a decision about shape - a per-child term, a much larger constant with an accepted worst case, or cutting the per-child spawn cost - not a bigger number.

### jq argument lists exceed the Windows command-line limit

`secondmate_home_summary_json` and `main_inventory_json` pass the whole backlog and task set to `jq` as `--argjson` argv.
Windows caps an entire command line at ~32KB and native `jq.exe` is launched through that API, so MSYS cannot lift it:

```sh
$ jq -n --arg v "$(head -c 30000 /dev/zero | tr '\0' x)" '$v|length' >/dev/null; echo $?
0
$ jq -n --arg v "$(head -c 40000 /dev/zero | tr '\0' x)" '$v|length' >/dev/null; echo $?
2   # jq: Argument list too long
```

A home with thirty done items is already over it:

```sh
$ fm-fleet-snapshot.sh --secondmate-home-summary
bin/fm-fleet-snapshot.sh: line 653: .../jq: Argument list too long
fm-fleet-snapshot: secondmate home summary failed
```

The parent reports `structured home snapshot failed` and shows no state for that home.
There are 113 `--arg`/`--argjson` sites in this file; at least those two carry unbounded payloads.
The mechanical fix is to feed the payloads on stdin and bind them with `input as $backlog | input as $tasks`, which leaves the jq program bodies untouched.

## What is not proven here

The scale is a platform constant, not a measurement taken per run.
It is calibrated against the slowest exec path observed on this host, so a Windows host that is slower still - a much larger registry, a heavier AV policy - could put a healthy read past 40s again and would show up as the same unavailable-registry disclosure.
`FM_TIMEOUT_SPAWN_SCALE` exists for that case, and for the inverse case of a POSIX host slow enough to need more than its 1x default.
