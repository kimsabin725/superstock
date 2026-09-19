"""What the keeper must do when its sources fail.

The contract's fail-safe only works if the keeper stops vouching for readings it
can no longer take. These check that it does.

Run: .venv/bin/python keeper/test_keeper.py
"""

from __future__ import annotations

import datetime as dt
from zoneinfo import ZoneInfo
import pathlib
import sys
import time

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

import keeper as K
import sources as src


ALLOW = [True]


class FakeFn:
    def __init__(self, sink, name, args):
        self.sink, self.name, self.args = sink, name, args

    def call(self):
        return (ALLOW[0], 0) if self.name == "check" else None


class FakeFunctions:
    def __init__(self, sink):
        self.sink = sink

    def __getattr__(self, name):
        def make(*args):
            return FakeFn(self.sink, name, args)
        return make


class FakeContract:
    def __init__(self, sink):
        self.functions = FakeFunctions(sink)


class FakeChain:
    onchain = {"session": 0, "halt": 0, "ca_at": 0}
    price = 0

    def onchain_signal(self, sid):
        return dict(self.onchain)

    def venue_price(self, token):
        return self.price

    def __init__(self):
        self.sent = []
        self.signal = FakeContract(self.sent)
        self.amm = FakeContract(self.sent)
        self.router = FakeContract(self.sent)

    def send(self, fn):
        self.sent.append((fn.name, fn.args))
        return "0x" + "ab" * 32

    def token_of(self, sid):
        return "0x" + "11" * 20


class MemState:
    def __init__(self):
        self.pub, self.px = {}, {}

    def last(self, s):
        return self.pub.get(s)

    def save(self, s, session, halt, ca_at, price_at):
        self.pub[s] = (session, halt, ca_at)

    def last_price(self, s):
        return self.px.get(s)

    def save_price(self, s, v):
        self.px[s] = v


def fresh_keeper():
    k = K.Keeper(FakeChain(), MemState())
    k.sessions = {s: 0 for s in K.POOL}
    k.issuer_halts = {s: 0 for s in K.POOL}
    now = time.time()
    k.source_ok_at = {n: now for n in K.SOURCE_BUDGET}
    k.price_seen_at = {s: now for s in K.POOL}
    return k


def check(name, cond):
    print(("  ok   " if cond else "  FAIL ") + name)
    return cond


def main() -> int:
    ok = True

    # 1. everything healthy -> it writes
    k = fresh_keeper()
    wrote = k.publish(force=True)
    ok &= check("healthy keeper publishes", wrote and k.chain.sent[-1][0] == "setBatch")

    # 2. the asset feed goes dark -> it must stop writing, not republish the cache
    k = fresh_keeper()
    k.source_ok_at["assets"] = time.time() - (K.SOURCE_BUDGET["assets"] + 60)
    before = len(k.chain.sent)
    wrote = k.publish(force=True)
    ok &= check("dead asset feed stops the keeper writing", not wrote and len(k.chain.sent) == before)
    ok &= check("and it says which source died", K.health["stale_sources"] == ["assets"])

    # 3. the halt feed going dark is just as disqualifying
    k = fresh_keeper()
    k.source_ok_at["halts"] = time.time() - (K.SOURCE_BUDGET["halts"] + 60)
    ok &= check("dead halt feed stops the keeper writing", not k.publish(force=True))

    # 4. a price we have not re-read recently must not be dated as current
    k = fresh_keeper()
    k.price_seen_at = {s: time.time() - (K.PRICE_BUDGET + 60) for s in K.POOL}
    k.publish(force=True)
    sigs = k.chain.sent[-1][1][1]
    ok &= check("a stale quote is published as no quote", all(s[3] == 0 for s in sigs))

    # 5. a fresh price carries the time it was actually read
    k = fresh_keeper()
    seen = time.time() - 30
    k.price_seen_at = {s: seen for s in K.POOL}
    k.publish(force=True)
    sigs = k.chain.sent[-1][1][1]
    ok &= check("a fresh quote carries its real read time", all(s[3] == int(seen) for s in sigs))

    # 6. corporate action bookkeeping: newest version wins, cancellations drop out
    now = dt.datetime.now(dt.timezone.utc)
    soon = (now + dt.timedelta(hours=3)).isoformat().replace("+00:00", "Z")
    later = (now + dt.timedelta(days=2)).isoformat().replace("+00:00", "Z")
    past = (now - dt.timedelta(days=3)).isoformat().replace("+00:00", "Z")
    events = [
        {"eventId": "a", "version": 1, "xstockSymbol": "NVDAx", "caType": "CashDividend",
         "effectiveTimeUtc": soon, "status": "Scheduled", "notes": None},
        {"eventId": "a", "version": 2, "xstockSymbol": "NVDAx", "caType": "CashDividend",
         "effectiveTimeUtc": soon, "status": "Cancelled", "notes": None},
        {"eventId": "b", "version": 1, "xstockSymbol": "NVDAx", "caType": "ForwardSplit",
         "effectiveTimeUtc": later, "status": "Scheduled", "notes": None},
        {"eventId": "c", "version": 1, "xstockSymbol": "TSLAx", "caType": "CashDividend",
         "effectiveTimeUtc": past, "status": "Scheduled", "notes": None},
    ]
    out = src.next_corporate_action(events, now)
    ok &= check("a cancelled amendment removes the event", out["NVDAx"]["event_id"] == "b")
    ok &= check("a scheduled row left in the past is ignored", "TSLAx" not in out)

    # 7. a halt clears on its published resumption time, never on vanishing
    # Both halves have to come off the same clock. Dating this from UTC while
    # hardcoding an ET wall time made the pair land in the future for most of
    # the day, so the check only passed after 13:30 UTC.
    past_et = (now - dt.timedelta(hours=1)).astimezone(ZoneInfo("America/New_York"))
    past_halt = {"resumption_date": past_et.strftime("%m/%d/%Y"),
                 "resumption_trade_time": past_et.strftime("%H:%M:%S")}
    open_halt = {"resumption_date": "", "resumption_trade_time": ""}
    ok &= check("a halt with no resumption time stays a halt", not src.resumed(open_halt, now))
    ok &= check("a halt past its resumption time clears", src.resumed(past_halt, now))

    # 8. a halt must survive the feed being wiped at midnight ET
    k = fresh_keeper()
    k.underlying = {"NVDA": "NVDAx"}
    src_feed = {"NVDA": {"code": 200, "reason_code": "T1", "halt_date": "", "halt_time": "",
                         "resumption_date": "", "resumption_trade_time": ""}}
    real_fetch, real_resumed = src.fetch_exchange_halts, src.resumed
    src.fetch_exchange_halts = lambda: src_feed
    k.loop_halts()
    ok &= check("a halt in the feed is recorded", k.exchange_halts.get("NVDAx") == 200)
    src.fetch_exchange_halts = lambda: {}          # midnight: the feed is emptied
    k.loop_halts()
    ok &= check("and it survives the feed being wiped", k.exchange_halts.get("NVDAx") == 200)
    src.resumed = lambda h, n: True                # the exchange publishes a resumption
    k.loop_halts()
    ok &= check("only a resumption time clears it", "NVDAx" not in k.exchange_halts)
    src.fetch_exchange_halts, src.resumed = real_fetch, real_resumed

    # 9. the two feeds spell class shares differently; the join has to survive it
    ok &= check("BRK.B and BRK/B join", src.normalize_ticker("brk.b") == src.normalize_ticker("BRK/B"))

    # 10. a halted name holds even while its session says the market is open
    k = fresh_keeper()
    k.exchange_halts = {"NVDAx": 201}
    k.publish(force=True)
    sigs = dict(zip(K.POOL, k.chain.sent[-1][1][1]))
    ok &= check("a halt outranks an open session", sigs["NVDAx"][1] == 201 and sigs["SPYx"][1] == 0)

    # 11. an issuer halt is reported when the exchange has nothing to say
    k = fresh_keeper()
    k.issuer_halts["TSLAx"] = 210
    k.publish(force=True)
    sigs = dict(zip(K.POOL, k.chain.sent[-1][1][1]))
    ok &= check("an issuer halt is reported too", sigs["TSLAx"][1] == 210)

    # 12a. a redeployed venue must not inherit a mark the keeper merely remembers
    k = fresh_keeper()
    k.chain.onchain = {"session": 2, "halt": 0, "ca_at": 0}   # chain says closed
    k.sessions = {s: 0 for s in K.POOL}                        # we just read open
    wrote = k.publish()
    ok &= check("a signal is written when the chain disagrees", wrote)
    k.chain.onchain = {"session": 0, "halt": 0, "ca_at": 0}
    before = len(k.chain.sent)
    k.publish()
    ok &= check("and withheld when the chain already agrees", len(k.chain.sent) == before)

    # 12. parking cash the next pass would immediately un-park is pure waste
    k = fresh_keeper()
    k.accounts = ["0x" + "22" * 20]
    ALLOW[0] = True
    before = len(k.chain.sent)
    k.loop_sweep()
    ok &= check("an open market means no parking", len(k.chain.sent) == before)
    ALLOW[0] = False
    k.loop_buys()
    ok &= check("and a shut market means no pointless buy", len(k.chain.sent) == before)
    ALLOW[0] = True

    print("\n" + ("all keeper checks passed" if ok else "KEEPER CHECKS FAILED"))
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
