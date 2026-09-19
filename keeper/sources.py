"""Reading the tape: what the issuer, the exchange and the calendar say right now.

Every function here returns plain data and never touches the chain. The rules
that turn this data into an allow/hold decision live in the contract, not here.
"""

from __future__ import annotations

import datetime as dt
import xml.etree.ElementTree as ET
from zoneinfo import ZoneInfo

import requests
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry

XSTOCKS = "https://api.xstocks.fi/api/v2/public"
HALTS_RSS = "https://www.nasdaqtrader.com/rss.aspx?feed=tradehalts"
NDAQ = "{http://www.nasdaqtrader.com/}"

# session codes, matching TapeSignal.sol
MARKET, EXTENDED, CLOSED, LUNCH, UNKNOWN = 0, 1, 2, 3, 4

# halt codes, matching the shared reason table
HALT_NEWS, HALT_VOLATILITY, HALT_REGULATORY = 200, 201, 202
HALT_MARKET_WIDE, HALT_ISSUER, HALT_UNKNOWN = 203, 210, 220

REASON_CODE_MAP = {
    "T1": HALT_NEWS, "T2": HALT_NEWS, "T12": HALT_NEWS, "T3": HALT_NEWS,
    "LUDP": HALT_VOLATILITY, "LUDS": HALT_VOLATILITY,
    "H10": HALT_REGULATORY, "H4": HALT_REGULATORY, "H9": HALT_REGULATORY, "H11": HALT_REGULATORY,
    "MWC0": HALT_MARKET_WIDE, "MWC1": HALT_MARKET_WIDE, "MWC2": HALT_MARKET_WIDE,
    "MWC3": HALT_MARKET_WIDE, "MWCQ": HALT_MARKET_WIDE,
}

CA_TYPE = {
    "CashDividend": 1, "StockDividend": 2, "ForwardSplit": 3,
    "ReverseSplit": 4, "SpinOff": 5,
}

HK_TZ = ZoneInfo("Asia/Hong_Kong")


def normalize_ticker(t: str) -> str:
    """The halt feed and the issuer disagree on class shares: one writes BRK.B,
    the other BRK/B. Join on one spelling or the join silently finds nothing."""
    return t.strip().upper().replace(".", "/")


# The issuer answers a quote in well under a second while New York is open and
# takes 20+ seconds once it closes, which sat right on top of a flat 20s timeout
# and turned every after-hours read into a failure. Separate the two budgets:
# a connection that will not open is dead, a slow answer is just slow.
CONNECT_TIMEOUT, READ_TIMEOUT = 10, 45

_session = requests.Session()
_session.mount("https://", HTTPAdapter(
    max_retries=Retry(
        total=3, backoff_factor=1.5,
        # Retry a refused connection or a server that says it is busy, but not
        # a slow answer: on a 60s loop, four 45s reads in a row would block
        # every other source behind this one for three minutes.
        read=0,
        status_forcelist=(429, 500, 502, 503, 504),
        allowed_methods=("GET",),
    ),
    pool_maxsize=16,
))


def _get(url: str, **params):
    r = _session.get(url, params=params or None,
                     timeout=(CONNECT_TIMEOUT, READ_TIMEOUT))
    r.raise_for_status()
    return r.json()


def fetch_assets(limit: int = 100) -> list[dict]:
    """Every xStock the issuer publishes, one page at a time."""
    out, page = [], 1
    while True:
        d = _get(f"{XSTOCKS}/assets", page=page, limit=limit)
        out.extend(d["nodes"])
        if not d["page"].get("hasNextPage"):
            return out
        page += 1


def session_of(asset: dict, now: dt.datetime) -> int:
    """Which trading period the underlying market is in.

    The issuer reports market / extended / overnight / closed. HKEX names sit
    'closed' through the local lunch break, which is a different thing from the
    market being shut for the day, so we separate it.
    """
    trading = asset.get("trading")
    if not trading:
        return UNKNOWN
    period = trading.get("currentPeriod")
    if period == "market":
        return MARKET
    if period in ("extended", "overnight"):
        return EXTENDED
    if period == "closed":
        mic = (trading.get("exchange") or {}).get("mic")
        if mic == "XHKG":
            local = now.astimezone(HK_TZ)
            if local.weekday() < 5 and local.hour == 12:
                return LUNCH
        return CLOSED
    return UNKNOWN


def issuer_halt(asset: dict) -> int:
    """The issuer's own halt flag — issue and redeem are off, but the exchange
    may be trading normally. A different thing from an exchange halt."""
    trading = asset.get("trading") or {}
    return HALT_ISSUER if (asset.get("isTradingHalted") or trading.get("isTradingHalted")) else 0


def fetch_exchange_halts() -> dict[str, dict]:
    """Nasdaq's live halt feed, keyed by the underlying ticker.

    The feed only carries the current day and resets at midnight ET, so an entry
    disappearing is not the same as trading resuming. Resumption is read from
    the resumption time, never from absence.
    """
    r = _session.get(HALTS_RSS, timeout=(CONNECT_TIMEOUT, READ_TIMEOUT))
    r.raise_for_status()
    root = ET.fromstring(r.content)
    halts: dict[str, dict] = {}
    for item in root.iter("item"):
        def f(tag: str) -> str:
            el = item.find(NDAQ + tag)
            return (el.text or "").strip() if el is not None else ""

        symbol = normalize_ticker(f("IssueSymbol"))
        if not symbol:
            continue
        code = f("ReasonCode").upper()
        halts[symbol] = {
            "code": REASON_CODE_MAP.get(code, HALT_UNKNOWN),
            "reason_code": code,
            "halt_date": f("HaltDate"),
            "halt_time": f("HaltTime"),
            "resumption_date": f("ResumptionDate"),
            "resumption_trade_time": f("ResumptionTradeTime"),
        }
    return halts


def resumed(halt: dict, now: dt.datetime) -> bool:
    """True once the published resumption time has passed."""
    date, time = halt.get("resumption_date"), halt.get("resumption_trade_time")
    if not date or not time:
        return False
    try:
        naive = dt.datetime.strptime(f"{date} {time}", "%m/%d/%Y %H:%M:%S")
    except ValueError:
        return False
    et = naive.replace(tzinfo=ZoneInfo("America/New_York"))
    return now >= et


def fetch_corporate_actions(limit: int = 100) -> list[dict]:
    out, page = [], 1
    while True:
        d = _get(f"{XSTOCKS}/corporate-actions/upcoming", page=page, limit=limit)
        out.extend(d["nodes"])
        if not d["page"].get("hasNextPage"):
            return out
        page += 1


def next_corporate_action(events: list[dict], now: dt.datetime) -> dict[str, dict]:
    """The one event per symbol that actually matters.

    Corporate actions get amended and cancelled in place: the same eventId shows
    up again with a higher version, sometimes cancelled outright, and stale
    scheduled rows linger past their own effective time. Only the newest version
    of a live event counts, and only if its time is still ahead of us.
    """
    newest: dict[str, dict] = {}
    for e in events:
        key = e.get("eventId")
        if key is None:
            continue
        prev = newest.get(key)
        if prev is None or (e.get("version") or 0) > (prev.get("version") or 0):
            newest[key] = e

    by_symbol: dict[str, dict] = {}
    for e in newest.values():
        if e.get("status") == "Cancelled":
            continue
        if "[CANCELLED" in (e.get("notes") or ""):
            continue
        when = e.get("effectiveTimeUtc")
        if not when:
            continue
        at = dt.datetime.fromisoformat(when.replace("Z", "+00:00"))
        if at < now - dt.timedelta(hours=6):
            continue  # stale row left behind by the issuer
        sym = e.get("xstockSymbol")
        cur = by_symbol.get(sym)
        if cur is None or at < cur["at"]:
            by_symbol[sym] = {
                "at": at,
                "type": CA_TYPE.get(e.get("caType"), 6),
                "event_id": e.get("eventId"),
                "version": e.get("version"),
            }
    return by_symbol


def fetch_price(symbol: str) -> float | None:
    """Issuer mark. Used as the fallback for names Chainlink does not cover on
    X Layer — which is 93% of them."""
    try:
        d = _get(f"{XSTOCKS}/assets/{symbol}/price-data")
    except requests.RequestException:
        # One unreachable symbol must not cost us the other four. The caller
        # reads this as 'no mark', which ages out on its own.
        return None
    q = d.get("quote")
    return float(q) if q is not None else None
