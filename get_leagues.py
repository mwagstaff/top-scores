import requests
import pandas as pd

API_KEY = "7179aeb7f213cbc0f55a6cc1f4b5de80e05c09d3"

r = requests.get(
    "https://sports.bzzoiro.com/api/v2/leagues/?limit=200",
    headers={"Authorization": f"Token {API_KEY}"}
)
r.raise_for_status()

data = r.json()

rows = []
for league in data.get("results", []):
    season = league.get("current_season") or {}
    rows.append({
        "League ID": league.get("id"),
        "League Name": league.get("name"),
        "Country": league.get("country"),
        "Season ID": season.get("id"),
        "Season Name": season.get("name"),
        "Year": season.get("year"),
    })

df = pd.DataFrame(rows)
print(df.to_markdown(index=False))