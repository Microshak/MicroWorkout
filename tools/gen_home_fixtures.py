#!/usr/bin/env python3
"""Generate the Home-state fixtures PRD-09's acceptance runs use.

    python3 tools/gen_home_fixtures.py

Writes ``tests/fixtures/home_states/<state>/{plans.json,history.json,settings.json}`` for the
five states `HomeState` can be in, by reusing the real golden plans so the today card shows a
real plan title, real focus chords and a real block count (PRD-09 AC11).

The fixtures are anchored to **Mon 2026-09-14 … Sun 2026-09-20** and assume the device's "today"
is **Wednesday 2026-09-16** — the date PRD-09 was implemented. Two consequences worth knowing
before reading them:

* The `training` / `done_today` fixtures use a **5-day** plan (`Mon, Tue, Wed, Fri, Sat`,
  appendix §6.3) and the `plan_finished` fixture a 3-session plan, because a plan only produces
  `TRAINING` on Wednesdays if its weekday pattern contains Wednesday. PRD-09 §7's illustrative
  Mon/Tue/Thu/Sat example cannot produce a training state on a Wednesday at all.
* Every date in the documents is a real `YYYY-MM-DD`; the desktop probe
  (`scripts/dev/_prd09_probe.gd`) shifts the whole fixture by whole weeks when it is run in a
  later week, which preserves the weekdays.
"""

import json
import os
import shutil

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "tests", "fixtures", "home_states")

# The fixture week: Monday … Sunday.
MON = "2026-09-14"
TUE = "2026-09-15"
WED = "2026-09-16"
THU = "2026-09-17"
FRI = "2026-09-18"
SAT = "2026-09-19"
SUN = "2026-09-20"

PLAN_ID = "plan-1757941200"

## A second plan id for the finished-plan fixture (appendix §5.2: `^plan-\d{10}$`).
PLAN_ID_THREE = "plan-1757941300"


def load_golden(name):
    with open(os.path.join(ROOT, "tests", "fixtures", name), encoding="utf-8") as handle:
        return json.load(handle)["expected_plan"]


def plan_from(name, plan_id, created_at, days_per_week=None, plan_name=None, drop_last=0):
    plan = json.loads(json.dumps(load_golden(name)))
    plan["id"] = plan_id
    plan["created_at"] = created_at
    if drop_last:
        plan["sessions"] = plan["sessions"][: len(plan["sessions"]) - drop_last]
        for index, session in enumerate(plan["sessions"]):
            session["index"] = index
    if days_per_week is not None:
        plan["days_per_week"] = days_per_week
    if plan_name is not None:
        plan["name"] = plan_name
    plan["source"] = "builtin"
    plan["provider"] = ""
    return plan


def entry(entry_id, date, session_id, session_title, duration_sec=2400, completed=True,
          plan_id=PLAN_ID, focus=None):
    return {
        "id": entry_id,
        "plan_id": plan_id,
        "session_id": session_id,
        "session_title": session_title,
        "date": date,
        "started_at": "%sT18:05:00Z" % date,
        "completed_at": "%sT18:45:00Z" % date,
        "duration_sec": duration_sec,
        "exercises_completed": 4,
        "exercises_total": 4,
        "completed": completed,
        "sets_completed": 12,
        "sets_total": 12,
        "focus": focus if focus is not None else [],
        "exercise_ids": [],
    }


def settings():
    return {
        "schema_version": 2,
        "units": "lb",
        "theme": "dark",
        "weekly_goal_days": 4,
        "onboarding_complete": True,
        "meta": {
            "created_at": "2026-09-01T08:00:00Z",
            "updated_at": "2026-09-01T08:00:00Z",
            "app_version": "0.1.0",
        },
    }


def write(state, plans, entries):
    target = os.path.join(OUT, state)
    shutil.rmtree(target, ignore_errors=True)
    os.makedirs(target)
    active = plans[0]["id"] if plans else ""
    documents = {
        "plans.json": {"schema_version": 1, "active_plan_id": active, "plans": plans},
        "history.json": {"schema_version": 1, "entries": entries},
        "settings.json": settings(),
    }
    for name, document in documents.items():
        path = os.path.join(target, name)
        with open(path, "w", encoding="utf-8") as handle:
            json.dump(document, handle, indent=2, ensure_ascii=False, sort_keys=False)
            handle.write("\n")
    print("%-14s active=%s plans=%d entries=%d" % (state, active or "-", len(plans), len(entries)))


def main():
    five = plan_from("golden_plan_5day_ppl_ul.json", PLAN_ID, "%sT06:00:00Z" % MON)
    four = plan_from("golden_plan_4day_upper_lower.json", PLAN_ID, "%sT06:00:00Z" % MON)
    three = plan_from("golden_plan_4day_upper_lower.json", PLAN_ID_THREE, "2026-08-03T06:00:00Z",
                      days_per_week=3, plan_name="3-Day Upper / Lower", drop_last=1)

    # 1. no_plan — nothing to show, and the strip is seven rest pills (R10).
    write("no_plan", [], [])

    # 2. training — a 5-day plan (Mon/Tue/Wed/Fri/Sat) with Monday and Tuesday done, so today
    #    (Wednesday) is a planned day whose session is still due: session_index 2 → `Legs`.
    write("training", [five], [
        entry("h-tr-1", MON, "s1", "Push", 2340, focus=["chest", "shoulders", "arms", "core"]),
        entry("h-tr-2", TUE, "s2", "Pull", 2520, focus=["back", "arms", "core"]),
    ])

    # 3. done_today — the same plan with today's session finished too (R11).
    write("done_today", [five], [
        entry("h-dt-1", MON, "s1", "Push", 2340, focus=["chest", "shoulders", "arms", "core"]),
        entry("h-dt-2", TUE, "s2", "Pull", 2520, focus=["back", "arms", "core"]),
        entry("h-dt-3", WED, "s3", "Legs", 2460, focus=["legs", "core"]),
    ])

    # 4. rest — a 4-day plan (Mon/Tue/Thu/Fri) with Monday and Tuesday done: Wednesday is a rest
    #    day whose next session is `Upper B` on Thursday (R12).
    write("rest", [four], [
        entry("h-rs-1", MON, "s1", "Upper A", 2040,
              focus=["chest", "back", "shoulders", "arms", "core"]),
        entry("h-rs-2", TUE, "s2", "Lower A", 2160,
              focus=["core", "chest", "back", "shoulders", "arms"]),
    ])

    # 5. plan_finished — every session of the 3-session plan completed four times (R13).
    finished_entries = []
    week_starts = ["2026-08-03", "2026-08-10", "2026-08-17", "2026-08-24"]
    for week_index, start in enumerate(week_starts):
        day = start
        for session_index, (session_id, title) in enumerate(
                [("s1", "Upper A"), ("s2", "Lower A"), ("s3", "Upper B")]):
            offset = session_index * 2
            from datetime import date, timedelta
            year, month, day_of_month = (int(part) for part in day.split("-"))
            when = (date(year, month, day_of_month) + timedelta(days=offset)).isoformat()
            finished_entries.append(entry(
                "h-pf-%d-%d" % (week_index + 1, session_index + 1), when, session_id, title,
                2400, True, PLAN_ID_THREE))
    write("plan_finished", [three], finished_entries)


if __name__ == "__main__":
    main()
