#!/usr/bin/env python3
"""Runs the missions against the app and keeps the score.

    scripts/build.sh run            # in app/: the browser must be running
    bench/run.py                    # every mission in bench/missions, once
    bench/run.py --only todomvc jspaint-circle --repeat 3

Each mission is a request in plain words, as a person would type it, with no url: or done_when:
line: the runner reads those from it first. A row per run goes to the table printed at the end
and to bench/results/<stamp>.md, and every run's trace (the screenshots the model saw and what it
decided) goes under bench/traces/<stamp>/<mission>/. The success rate is the number to watch;
the traces of the failures are what to read next.

Exits 0 when every run ended done, 1 otherwise.
"""
import argparse
import datetime
import json
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
REPO = ROOT.parent


def find_runner(given):
    if given:
        return Path(given)
    for candidate in [
        REPO / "runner/target/release/acorn-runner",
        REPO / "app/build/AcornBrowser.app/Contents/Resources/acorn-runner",
        REPO / "runner/target/debug/acorn-runner",
    ]:
        if candidate.exists():
            return candidate
    sys.exit("no acorn-runner found: build it with `cargo build --release` in runner/, or pass --runner")


def run_mission(runner, mission, trace_dir, extra):
    """Runs one mission and returns its row: what the runner understood, how it ended, and the cost."""
    command = [str(runner), str(mission), "--trace", str(trace_dir)] + extra
    started = datetime.datetime.now()
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    row = {"mission": mission.stem, "status": "crashed", "message": "", "seconds": 0.0, "cost": 0.0, "steps": 0, "understood": ""}
    for line in process.stdout:
        line = line.strip()
        if not line:
            continue
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        kind = event.get("event")
        if kind == "understood":
            row["understood"] = event.get("summary", "")
            url = event.get("startUrl") or "(current page)"
            print(f"  understood: {row['understood']}  [{url}]")
        elif kind == "step":
            row["steps"] = event.get("number", row["steps"])
            print(f"  step {event.get('number')}: {event.get('message', '')}")
        elif kind == "end":
            row["status"] = event.get("status", "")
            row["message"] = event.get("message", "")
            row["seconds"] = float(event.get("seconds", 0))
            row["cost"] = float(event.get("cost", 0))
        elif kind == "error":
            row["status"] = "error"
            row["message"] = event.get("message", "")
    process.wait()
    errors = process.stderr.read().strip()
    if row["status"] in ("crashed", "error") and errors:
        row["message"] = (row["message"] + " " + errors.splitlines()[-1]).strip()
    if not row["seconds"]:
        row["seconds"] = (datetime.datetime.now() - started).total_seconds()
    return row


def table(rows):
    lines = ["| mission | status | steps | seconds | cost | message |", "| --- | --- | ---: | ---: | ---: | --- |"]
    for r in rows:
        message = r["message"].replace("|", "/").replace("\n", " ")[:120]
        lines.append(f"| {r['mission']} | {r['status']} | {r['steps']} | {r['seconds']:.0f} | ${r['cost']:.3f} | {message} |")
    done = sum(1 for r in rows if r["status"] == "done")
    lines.append("")
    lines.append(f"**{done} of {len(rows)} done** · {sum(r['seconds'] for r in rows):.0f} s · ${sum(r['cost'] for r in rows):.2f}")
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--runner", help="the acorn-runner binary")
    parser.add_argument("--missions", default=str(ROOT / "missions"), help="the folder of mission files")
    parser.add_argument("--only", nargs="*", default=[], help="mission names to run (file names without .md)")
    parser.add_argument("--repeat", type=int, default=1, help="how many times to run each mission")
    parser.add_argument("--model", help="the driving model (passed to the runner)")
    parser.add_argument("--decider", help="the decision model, or none (passed to the runner)")
    args = parser.parse_args()

    runner = find_runner(args.runner)
    missions = sorted(Path(args.missions).glob("*.md"))
    if args.only:
        missions = [m for m in missions if m.stem in args.only]
    if not missions:
        sys.exit("no missions to run")
    extra = []
    if args.model:
        extra += ["--model", args.model]
    if args.decider:
        extra += ["--decider", args.decider]

    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    traces = ROOT / "traces" / stamp
    rows = []
    for mission in missions:
        for n in range(args.repeat):
            name = mission.stem if args.repeat == 1 else f"{mission.stem}-{n + 1}"
            print(f"\n== {name}: {mission.read_text().strip().splitlines()[0]}")
            row = run_mission(runner, mission, traces / name, extra)
            row["mission"] = name
            print(f"  -> {row['status']} in {row['seconds']:.0f} s, ${row['cost']:.3f}: {row['message']}")
            rows.append(row)

    report = table(rows)
    print("\n" + report)
    results = ROOT / "results"
    results.mkdir(exist_ok=True)
    out = results / f"{stamp}.md"
    out.write_text(f"# Missions, {stamp}\n\nTraces in `bench/traces/{stamp}/`.\n\n{report}\n")
    print(f"\nWritten to {out}")
    return 0 if all(r["status"] == "done" for r in rows) else 1


if __name__ == "__main__":
    os.chdir(REPO)
    sys.exit(main())
