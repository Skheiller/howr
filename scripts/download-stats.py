#!/usr/bin/env python3
"""Read aggregate GitHub release-asset counts. Requires authenticated gh CLI."""
import datetime
import json
import subprocess

pages = json.loads(subprocess.check_output([
    "gh", "api", "--paginate", "--slurp",
    "repos/Skheiller/howr/releases?per_page=100",
], text=True))
rows = []
for page in pages:
    for release in page:
        if release["draft"]:
            continue
        for asset in release["assets"]:
            name = asset["name"]
            if name.endswith("-universal.dmg"):
                channel = "dmg"
            elif name.endswith("-homebrew.zip"):
                channel = "homebrew"
            elif name.endswith("-universal.zip"):
                channel = "legacy_shared_zip" if release["tag_name"] == "v1.0.0" else "terminal"
            else:
                continue
            rows.append({"tag": release["tag_name"], "asset_id": asset["id"],
                         "asset": name, "distribution": channel,
                         "downloads": asset["download_count"]})
totals = {}
for row in rows:
    totals[row["distribution"]] = totals.get(row["distribution"], 0) + row["downloads"]
print(json.dumps({"retrieved_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
                  "repository": "Skheiller/howr", "totals": totals, "assets": rows,
                  "limits": "Asset downloads, not unique people, completed installs or verified attribution. Includes tests, retries and direct GitHub downloads."}, indent=2))
