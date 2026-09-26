"""Generate Database/sellprices.lua, the vendor sell price of every stock item.

This client exposes no sell price for an arbitrary item: GetItemInfo stops at
`texture`, and the price reaches a tooltip only while a merchant window is
open. The gear advisor needs one for every reward a quest-giver offers, so the
price ships as data.

Source: pfUI's pfSellData (Eric Mauser / Shagu, MIT), read from the local
UnrealPfUI copy at env/tables.lua. Each row there is "<sell>,<buy>" in copper;
only the sell half is kept. See Database/CREDITS.md for provenance and the
accuracy limit (Vanilla prices; an item this server added has no row).

    python tools/make_sell_prices.py
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ADDON = os.path.dirname(HERE)
SOURCE = os.path.join(os.path.dirname(ADDON), "UnrealPfUI", "env", "tables.lua")
TARGET = os.path.join(ADDON, "Database", "sellprices.lua")
PER_LINE = 8


def main():
    with open(SOURCE, encoding="utf-8", errors="replace") as handle:
        text = handle.read()
    start = text.find("pfSellData")
    if start < 0:
        sys.exit("pfSellData not found in " + SOURCE)
    end = text.find("\n}", start)
    rows = re.findall(r'\[(\d+)\]\s*=\s*"(\d+),(\d+)"', text[start:end])
    prices = sorted((int(item), int(sell)) for item, sell, _ in rows)
    if len(prices) < 10000:
        sys.exit("only %d rows parsed; refusing to write a partial table" % len(prices))

    lines = ['UnrealQuestData["sellprices"] = {']
    for index in range(0, len(prices), PER_LINE):
        chunk = prices[index:index + PER_LINE]
        lines.append("  " + " ".join("[%d]=%d," % pair for pair in chunk))
    lines.append("}")
    with open(TARGET, "w", encoding="utf-8", newline="\n") as handle:
        handle.write("\n".join(lines) + "\n")
    print("wrote %d prices to %s" % (len(prices), TARGET))


if __name__ == "__main__":
    main()
