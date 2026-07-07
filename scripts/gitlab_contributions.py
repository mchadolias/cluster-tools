#!/usr/bin/env python3
"""
gitlab_contributions.py

Pulls your personal commit/push activity from a GitLab instance (e.g. an
internal collaboration server like git.km3net) and turns it into:
  1) contributions.json  - daily commit counts + summary stats
  2) heatmap.svg          - a GitHub-style contribution calendar you can
                            embed in a personal website / portfolio README

Usage:
    export GITLAB_URL="https://git.km3net.de"
    export GITLAB_TOKEN="your_personal_access_token"
    python gitlab_contributions.py --days 365

Notes:
  - Uses the GitLab REST API v4 (/users/:id/events), only `requests` needed.
  - Only reads YOUR OWN push events - no source code is fetched or stored,
    just commit counts and dates, so it's safe to publish externally even
    though the repos themselves are private.
  - Still worth a quick check with your supervisor/collaboration's
    authorship policy before publishing anything beyond raw commit counts
    (e.g. project names), just to be safe.
"""

import argparse
import json
import os
import sys
from collections import defaultdict
from datetime import datetime, timedelta, timezone

import requests


def get_own_user_id(base_url: str, token: str) -> int:
    r = requests.get(f"{base_url}/api/v4/user", headers={"PRIVATE-TOKEN": token})
    r.raise_for_status()
    return r.json()["id"]


def fetch_push_events(base_url: str, token: str, user_id: int, since: datetime):
    """Paginate through /users/:id/events, filtering to push events."""
    events = []
    page = 1
    while True:
        r = requests.get(
            f"{base_url}/api/v4/users/{user_id}/events",
            headers={"PRIVATE-TOKEN": token},
            params={
                "action": "pushed",
                "after": since.strftime("%Y-%m-%d"),
                "per_page": 100,
                "page": page,
            },
        )
        r.raise_for_status()
        batch = r.json()
        if not batch:
            break
        events.extend(batch)
        page += 1
        if page > 50:  # safety cap (~5000 events)
            break
    return events


def aggregate_by_day(events):
    daily = defaultdict(int)
    projects = defaultdict(int)
    for ev in events:
        push = ev.get("push_data") or {}
        count = push.get("commit_count", 1)
        date = ev["created_at"][:10]  # YYYY-MM-DD
        daily[date] += count
        projects[ev.get("project_id")] += count
    return daily, projects


def summarize(daily: dict):
    total = sum(daily.values())
    active_days = len(daily)
    days_sorted = sorted(daily.keys())
    longest_streak = cur_streak = 0
    prev_date = None
    for d in days_sorted:
        date = datetime.strptime(d, "%Y-%m-%d").date()
        if prev_date and (date - prev_date).days == 1:
            cur_streak += 1
        else:
            cur_streak = 1
        longest_streak = max(longest_streak, cur_streak)
        prev_date = date
    return {
        "total_commits": total,
        "active_days": active_days,
        "longest_streak_days": longest_streak,
    }


def render_svg_heatmap(daily: dict, days: int, out_path: str):
    """GitHub-style calendar heatmap as a static SVG."""
    today = datetime.now(timezone.utc).date()
    start = today - timedelta(days=days)
    start -= timedelta(days=(start.weekday() + 1) % 7)  # align to Sunday

    counts = []
    d = start
    while d <= today:
        counts.append(daily.get(d.strftime("%Y-%m-%d"), 0))
        d += timedelta(days=1)

    max_count = max(counts) if counts else 0

    def color(c):
        if c == 0:
            return "#161b22"
        ratio = c / max_count if max_count else 0
        if ratio < 0.25:
            return "#0e4429"
        if ratio < 0.5:
            return "#006d32"
        if ratio < 0.75:
            return "#26a641"
        return "#39d353"

    cell, gap = 11, 3
    weeks = (len(counts) + 6) // 7
    width = weeks * (cell + gap) + 20
    height = 7 * (cell + gap) + 20

    svg = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" '
        f'viewBox="0 0 {width} {height}" font-family="sans-serif">',
        f'<rect width="{width}" height="{height}" fill="#0d1117"/>',
    ]

    d = start
    for i, c in enumerate(counts):
        week = i // 7
        day = i % 7
        x = 10 + week * (cell + gap)
        y = 10 + day * (cell + gap)
        svg.append(
            f'<rect x="{x}" y="{y}" width="{cell}" height="{cell}" rx="2" '
            f'fill="{color(c)}"><title>{d.strftime("%Y-%m-%d")}: {c} commits</title></rect>'
        )
        d += timedelta(days=1)

    svg.append("</svg>")
    with open(out_path, "w") as f:
        f.write("\n".join(svg))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--days", type=int, default=365)
    parser.add_argument("--out-json", default="contributions.json")
    parser.add_argument("--out-svg", default="heatmap.svg")
    args = parser.parse_args()

    base_url = os.environ.get("GITLAB_URL")
    token = os.environ.get("GITLAB_TOKEN")
    if not base_url or not token:
        sys.exit("Set GITLAB_URL and GITLAB_TOKEN environment variables first.")

    since = datetime.now(timezone.utc) - timedelta(days=args.days)
    user_id = get_own_user_id(base_url, token)
    events = fetch_push_events(base_url, token, user_id, since)
    daily, projects = aggregate_by_day(events)
    summary = summarize(daily)

    with open(args.out_json, "w") as f:
        json.dump({"daily": daily, "summary": summary}, f, indent=2)

    render_svg_heatmap(daily, args.days, args.out_svg)

    print(f"Wrote {args.out_json} and {args.out_svg}")
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
