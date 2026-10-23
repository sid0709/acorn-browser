#!/usr/bin/env python3
"""Runs the missions against the app and keeps the score, the way Online-Mind2Web is scored.

    scripts/build.sh run            # in app/: the browser must be running
    bench/run.py                    # every mission in bench/missions/levels, once
    bench/run.py --only L3-flightaware-discussions --repeat 2
    bench/run.py --missions bench/missions/basics --no-judge
    bench/run.py --mode both                  # every mission in image mode, then in DOM mode

A mission is a request in plain words, as a person would type it, followed by an HTML comment
with its level, the site it starts on, and what a judge must see. As in Online-Mind2Web, the
run starts on the mission's site (not a search engine), and a judge model grades it from the
screenshots and the actions of the trace, not from what the agent said at the end: it is told
the request and the key points, and answers pass or fail. The runner's own verdict (its "done")
is kept beside it.

A row per run goes to the table printed at the end and to bench/results/<stamp>.md; every run's
trace is under bench/traces/<stamp>/<mission>/. The judge's pass rate is the number to watch; the
traces of the failures are what to read next.

The judge needs OPENROUTER_API_KEY (from the environment, or the app's or kit's .env file).
Exits 0 when every run passed, 1 otherwise.
"""
import argparse
import itertools
import base64
import datetime
import json
import os
import re
import subprocess
import sys
import tempfile
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent
REPO = ROOT.parent
JUDGE_MODEL = "openai/gpt-6-luna"
JUDGE_SHOTS = 8


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


def read_key():
    key = os.environ.get("OPENROUTER_API_KEY", "").strip()
    if key:
        return key
    for env in [Path.home() / "Library/Application Support/com.acorn.browser/.env", REPO / "kit/.env"]:
        if env.exists():
            for line in env.read_text().splitlines():
                if line.strip().startswith("OPENROUTER_API_KEY="):
                    return line.split("=", 1)[1].strip().strip('"').strip("'")
    return ""


def read_mission(path):
    """The request, and the level, site and judge key points from the comment after it."""
    text = path.read_text()
    meta = {}
    comment = re.search(r"<!--(.*?)-->", text, re.S)
    if comment:
        for line in comment.group(1).splitlines():
            if ":" in line:
                key, value = line.split(":", 1)
                meta[key.strip().lower()] = value.strip()
        text = text[: comment.start()] + text[comment.end():]
    return text.strip(), meta


def write_task(request, site, with_site):
    """The task file the runner reads: the site as the benchmark gives it, the rest for the
    runner to read from the request."""
    handle = tempfile.NamedTemporaryFile("w", suffix=".md", prefix="mission-", delete=False)
    if site and with_site:
        handle.write(f"---\nurl: {site}\n---\n")
    handle.write(request + "\n")
    handle.close()
    return Path(handle.name)


def run_mission(runner, task_file, trace_dir, extra):
    """Runs one mission and returns its row: what the runner understood, how it ended, the cost."""
    command = [str(runner), str(task_file), "--trace", str(trace_dir)] + extra
    started = datetime.datetime.now()
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    row = {"status": "crashed", "message": "", "answer": "", "seconds": 0.0, "cost": 0.0, "steps": 0, "understood": "", "run": "", "mode": ""}
    for line in process.stdout:
        line = line.strip()
        if not line:
            continue
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        kind = event.get("event")
        if kind == "start":
            row["run"] = event.get("run", "")
            row["mode"] = event.get("mode", "")
        elif kind == "understood":
            row["understood"] = event.get("summary", "")
            print(f"  understood: {row['understood']}  [{event.get('startUrl') or '(current page)'}]")
            print(f"  done when: {event.get('doneWhen', '')}")
            for n, line in enumerate(event.get('approach') or [], 1):
                print(f"  approach {n}: {line}")
            for line in event.get('watchOut') or []:
                print(f"  watch out: {line}")
        elif kind == "step":
            row["steps"] = event.get("number", row["steps"])
            print(f"  step {event.get('number')}: {event.get('message', '')}")
        elif kind == "end":
            row["status"] = event.get("status", "")
            row["message"] = event.get("message", "")
            row["answer"] = event.get("answer", "") or ""
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


def trace_evidence(trace_dir, run_id):
    """The screenshots the model saw, spread over the run with the last one always in, and the
    actions as the timeline records them."""
    folder = trace_dir / run_id if run_id else trace_dir
    if not folder.exists():
        candidates = sorted(p for p in trace_dir.glob("*") if p.is_dir()) if trace_dir.exists() else []
        if not candidates:
            return [], ""
        folder = candidates[-1]
    shots = sorted(p for p in folder.glob("*.jpg") if ".marked." not in p.name and ".survey" not in p.name)
    shots = pick_shots(shots, [field_value(p.with_suffix(".json")) for p in shots], JUDGE_SHOTS)
    timeline = folder / "timeline.txt"

    actions = timeline.read_text() if timeline.exists() else ""
    return shots, actions[-6000:]


def field_value(entry):
    """What the focused field showed when the screenshot was taken, or None when none was
    focused; read from the trace entry beside the screenshot."""
    try:
        focus = json.loads(entry.read_text()).get("focus") or {}
    except (OSError, ValueError):
        return None
    if not focus:
        return None
    return (focus.get("label", ""), focus.get("value", ""), focus.get("checked"))


def pick_shots(shots, values, limit):
    """At most `limit` of the screenshots, in order: the last one always; then the ones where
    the focused field had just changed its value, newest first, since a wrong pick in a
    dropdown and its correction a step later look the same in an even spread (a judge once
    saw the wrong country and never the right one); the rest spread evenly over the run."""
    if len(shots) <= limit:
        return shots
    chosen = {len(shots) - 1}
    changed = [i for i in range(1, len(shots)) if values[i] is not None and values[i] != values[i - 1]]
    for i in reversed(changed):
        if len(chosen) >= max(1, limit // 2):
            break
        chosen.add(i)
    step = (len(shots) - 1) / (limit - 1)
    for i in range(limit):
        if len(chosen) >= limit:
            break
        chosen.add(round(i * step))
    # The even spread may already hold a chosen one; fill the rest from the newest down.
    for i in reversed(range(len(shots))):
        if len(chosen) >= limit:
            break
        chosen.add(i)
    return [shots[i] for i in sorted(chosen)]


def judge(key, request, key_points, shots, actions, answer):
    """Grades a run as WebJudge does: from the request, the key points, the screenshots and the
    actions; and, apart from that, the agent's answer in words against what the screenshots
    show. Returns (verdict, reason, answer_verdict, answer_reason)."""
    if not key:
        return "no key", "OPENROUTER_API_KEY is not set", "", ""
    if not shots:
        return "no trace", "no screenshots were found in the trace", "", ""
    content = [{
        "type": "text",
        "text": (
            "You grade whether a browser agent completed a task, from the screenshots it saw (in order, the last one being the final state) "
            "and the actions it took. Judge only what the screenshots and actions show; what the agent claimed at the end is not evidence. "
            "The task is complete only when every key point is visibly satisfied on the screenshots; a task that reached a results list when "
            "a single item was asked for, or that applied some of the requested criteria but not all, or that ended on an error or an unrelated "
            "page, is a fail.\n\n"
            "Apart from that, grade the agent's answer in words, as a person who asked would read it: \"pass\" when it answers what the task "
            "asks, correctly and completely, with the figures, names or conclusion that the screenshots show; \"fail\" when it is wrong, leaves "
            "out what was asked, or states something the screenshots do not support; \"none\" when the agent gave no answer. A task that asks "
            "for a state rather than a fact (open a page, fill a form) is answered by one sentence saying what was done.\n\n"
            "Answer with one JSON object: {\"verdict\": \"pass\" or \"fail\", \"reason\": one sentence, "
            "\"answer_verdict\": \"pass\", \"fail\" or \"none\", \"answer_reason\": one sentence}.\n\n"
            f"Task: {request}\n\nKey points: {key_points}\n\nThe agent's answer in words: {answer or '(none)'}\n\nActions:\n{actions or '(none recorded)'}"
        ),
    }]
    for shot in shots:
        data = base64.b64encode(shot.read_bytes()).decode()
        content.append({"type": "image_url", "image_url": {"url": f"data:image/jpeg;base64,{data}"}})
    body = {
        "model": JUDGE_MODEL,
        "messages": [{"role": "user", "content": content}],
        "response_format": {"type": "json_object"},
        "reasoning": {"effort": "low"},
    }
    req = urllib.request.Request(
        "https://openrouter.ai/api/v1/chat/completions",
        data=json.dumps(body).encode(),
        headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=180) as response:
            reply = json.loads(response.read())
        text = reply["choices"][0]["message"]["content"]
        verdict = json.loads(text[text.find("{"):])
        return verdict.get("verdict", "fail"), verdict.get("reason", ""), verdict.get("answer_verdict", ""), verdict.get("answer_reason", "")
    except Exception as error:  # noqa: BLE001 - the judge failing is a row, not a crash
        return "judge error", str(error)[:200], "", ""


def clean(text, limit=140):
    return (text or "").replace("|", "/").replace("\n", " ")[:limit]


def table(rows, judged):
    """The score table: the judge's verdict on the screen, its verdict on the answer in words,
    the steps, the seconds (everything the person waited for, from the runner's start), and the
    cost; then each run's answer, since that is what the person gets."""
    head = "| mission | level | mode | agent | judge | answer | steps | seconds | cost | note |"
    lines = [head, "| --- | ---: | --- | --- | --- | --- | ---: | ---: | ---: | --- |"]
    for r in rows:
        note = clean(r["judge_reason"] if judged else r["message"])
        lines.append(f"| {r['mission']} | {r['level']} | {r.get('mode', '')} | {r['status']} | {r['judge']} | {r.get('answer_judge', '')} | {r['steps']} | {r['seconds']:.0f} | ${r['cost']:.3f} | {note} |")
    passed = sum(1 for r in rows if (r["judge"] if judged else r["status"]) in ("pass", "done"))
    answered = sum(1 for r in rows if r.get("answer_judge") == "pass")
    lines.append("")
    summary = f"**{passed} of {len(rows)} {'passed' if judged else 'done'}**"
    if judged:
        summary += f" · {answered} of {len(rows)} answers right"
    lines.append(f"{summary} · {sum(r['seconds'] for r in rows):.0f} s · ${sum(r['cost'] for r in rows):.2f}")
    lines.append("")
    lines.append("Answers:")
    for r in rows:
        verdict = f" ({r['answer_judge']}: {clean(r.get('answer_reason', ''), 200)})" if judged and r.get("answer_judge") else ""
        lines.append(f"- {r['mission']}: {clean(r.get('answer', ''), 400) or '(no answer)'}{verdict}")
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--runner", help="the acorn-runner binary")
    parser.add_argument("--missions", default=str(ROOT / "missions" / "levels"), help="the folder of mission files")
    parser.add_argument("--only", nargs="*", default=[], help="mission names to run (file names without .md)")
    parser.add_argument("--repeat", type=int, default=1, help="how many times to run each mission")
    parser.add_argument("--model", help="the driving model (passed to the runner)")
    parser.add_argument("--decider", help="the decision model, or none (passed to the runner)")
    parser.add_argument("--mode", choices=["image", "dom", "both"], default="image", help="how the model sees the page: a screenshot (image), the page map and no picture (dom), or each mission in both, one after the other")
    parser.add_argument("--no-site", action="store_true", help="do not give the runner the mission's site: it must find it from the request")
    parser.add_argument("--no-judge", action="store_true", help="skip the judge; the agent's own verdict is the score")
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
    modes = ["image", "dom"] if args.mode == "both" else [args.mode]
    key = "" if args.no_judge else read_key()
    if not args.no_judge and not key:
        print("no OPENROUTER_API_KEY for the judge: the agent's own verdict will be the score")

    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    traces = ROOT / "traces" / stamp
    rows = []
    for mission in missions:
        request, meta = read_mission(mission)
        for n, mode in itertools.product(range(args.repeat), modes):
            name = mission.stem if args.repeat == 1 else f"{mission.stem}-{n + 1}"
            if len(modes) > 1:
                name = f"{name}-{mode}"
            print(f"\n== {name} (level {meta.get('level', '?')}, {mode} mode): {request.splitlines()[0]}")
            task_file = write_task(request, meta.get("site", ""), not args.no_site)
            trace_dir = traces / name
            try:
                row = run_mission(runner, task_file, trace_dir, extra + ["--mode", mode])
            finally:
                task_file.unlink(missing_ok=True)
            row["mission"] = name
            row["level"] = meta.get("level", "")
            row["judge"], row["judge_reason"], row["answer_judge"], row["answer_reason"] = "", "", "", ""
            if key:
                shots, actions = trace_evidence(trace_dir, row["run"])
                row["judge"], row["judge_reason"], row["answer_judge"], row["answer_reason"] = judge(key, request, meta.get("judge", ""), shots, actions, row["answer"])
            print(f"  -> agent: {row['status']} in {row['seconds']:.0f} s, ${row['cost']:.3f}: {row['message']}")
            print(f"  -> answer: {row['answer'] or '(none)'}")
            if key:
                print(f"  -> judge: {row['judge']}: {row['judge_reason']}")
                print(f"  -> judge of the answer: {row['answer_judge']}: {row['answer_reason']}")
            rows.append(row)

    report = table(rows, bool(key))
    print("\n" + report)
    results = ROOT / "results"
    results.mkdir(exist_ok=True)
    out = results / f"{stamp}.md"
    out.write_text(f"# Missions, {stamp}\n\nTraces in `bench/traces/{stamp}/`.\n\n{report}\n")
    print(f"\nWritten to {out}")
    ok = all((r["judge"] if key else r["status"]) in ("pass", "done") for r in rows)
    return 0 if ok else 1


if __name__ == "__main__":
    os.chdir(REPO)
    sys.exit(main())
