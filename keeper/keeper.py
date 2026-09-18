"""Super Stock keeper.

Reads the tape and writes it on chain. It never decides whether a buy happens —
it publishes what it saw and lets the contract apply the rules. If this process
dies, the signals go stale and the contract holds every buy on its own.

Run:  python keeper/keeper.py         (add --once to do a single pass)
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import pathlib
import sqlite3
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

from dotenv import load_dotenv
from web3 import Web3

import sources as src
from chain import Chain

ROOT = pathlib.Path(__file__).resolve().parent.parent
POOL = ["NVDAx", "TSLAx", "SPYx", "AAPLx", "COINx"]

INTERVALS = {
    "assets": 60, "halts": 300, "corporate_actions": 300,
    "prices": 60, "sweep": 600, "buys": 300, "accounts": 300,
}
US_MARKET_HALT_POLL = 30  # the halt feed matters most while New York is open

# The contract holds everything once a signal is older than its maxSignalAge
# (900s). We refresh well inside that, and otherwise only write when something
# actually moved — an unchanged tape is not worth a transaction.
HEARTBEAT = 300

# Don't pay gas to move a mark by a fraction of a cent.
PRICE_DEADBAND_BPS = 10

# How old an observation may be before we refuse to keep vouching for it.
# Publishing a cached reading with a fresh observedAt would tell the contract the
# tape is current when the source behind it has gone dark — which is exactly the
# failure the contract's fail-safe exists to catch. So when a source goes stale we
# stop writing, and the on-chain signal is allowed to age out on its own.
SOURCE_BUDGET = {"assets": 300, "halts": 900, "corporate_actions": 1800}
PRICE_BUDGET = 300

health = {"loops": {}, "last_tx": None, "stale_sources": [], "errors": []}


def now() -> dt.datetime:
    return dt.datetime.now(dt.timezone.utc)


def log(event: str, **fields) -> None:
    line = {"t": now().isoformat(), "event": event, **fields}
    print(json.dumps(line, default=str), flush=True)
    with open(ROOT / "keeper" / "keeper.jsonl", "a") as f:
        f.write(json.dumps(line, default=str) + "\n")


def symbol_id(sym: str) -> bytes:
    return Web3.keccak(text=sym)


# --------------------------------------------------------------------- state


class State:
    """What we last published, so we only pay gas for things that changed."""

    def __init__(self, path: pathlib.Path) -> None:
        self.db = sqlite3.connect(path, check_same_thread=False)
        self.db.execute(
            "CREATE TABLE IF NOT EXISTS published ("
            "symbol TEXT PRIMARY KEY, session INT, halt INT, ca_at INT, price_at INT)"
        )
        self.db.execute("CREATE TABLE IF NOT EXISTS prices (symbol TEXT PRIMARY KEY, price_e8 INT)")
        self.db.commit()

    def last(self, symbol: str) -> tuple | None:
        r = self.db.execute(
            "SELECT session, halt, ca_at FROM published WHERE symbol=?", (symbol,)
        ).fetchone()
        return r

    def save(self, symbol: str, session: int, halt: int, ca_at: int, price_at: int) -> None:
        self.db.execute(
            "INSERT INTO published VALUES (?,?,?,?,?) ON CONFLICT(symbol) DO UPDATE SET "
            "session=excluded.session, halt=excluded.halt, ca_at=excluded.ca_at, price_at=excluded.price_at",
            (symbol, session, halt, ca_at, price_at),
        )
        self.db.commit()

    def last_price(self, symbol: str) -> int | None:
        r = self.db.execute("SELECT price_e8 FROM prices WHERE symbol=?", (symbol,)).fetchone()
        return r[0] if r else None

    def save_price(self, symbol: str, price_e8: int) -> None:
        self.db.execute(
            "INSERT INTO prices VALUES (?,?) ON CONFLICT(symbol) DO UPDATE SET price_e8=excluded.price_e8",
            (symbol, price_e8),
        )
        self.db.commit()


# --------------------------------------------------------------------- keeper


class Keeper:
    def __init__(self, chain: Chain, state: State) -> None:
        self.chain = chain
        self.state = state
        self.sessions: dict[str, int] = {}
        self.issuer_halts: dict[str, int] = {}
        self.exchange_halts: dict[str, int] = {}  # by xStock symbol
        self.ca: dict[str, int] = {}
        self.underlying: dict[str, str] = {}  # underlying ticker -> xStock symbol
        self.accounts: list[str] = []
        self.us_market_open = False
        self.source_ok_at: dict[str, float] = {}
        self.price_seen_at: dict[str, float] = {}
        self.open_halts: dict[str, dict] = {}  # xStock symbol -> the halt record

    # ------------------------------------------------------------- reading

    def loop_assets(self) -> None:
        assets = src.fetch_assets()
        t = now()
        pool = set(POOL)
        self.us_market_open = False
        for a in assets:
            sym = a.get("symbol")
            under = src.normalize_ticker(a.get("underlyingSymbol") or "")
            if under:
                self.underlying[under] = sym
            if sym in pool:
                self.sessions[sym] = src.session_of(a, t)
                self.issuer_halts[sym] = src.issuer_halt(a)
                if self.sessions[sym] == src.MARKET:
                    self.us_market_open = True
        self.source_ok_at["assets"] = time.time()
        log("assets", n=len(assets), pool={s: self.sessions.get(s) for s in POOL})

    def loop_halts(self) -> None:
        """The feed carries the current trading day only and is wiped at midnight
        ET. A halt leaving the feed therefore means nothing at all — a name halted
        into the close would look resumed at 00:00. So halts are remembered, and
        only the published resumption time clears one."""
        halts = src.fetch_exchange_halts()
        t = now()
        pool = set(POOL)

        for ticker, h in halts.items():
            xsym = self.underlying.get(ticker)
            if xsym in pool:
                self.open_halts[xsym] = h

        cleared = [s for s, h in self.open_halts.items() if src.resumed(h, t)]
        for s in cleared:
            del self.open_halts[s]

        self.exchange_halts = {s: h["code"] for s, h in self.open_halts.items()}
        self.source_ok_at["halts"] = time.time()
        log(
            "halts",
            feed_items=len(halts),
            affecting_pool=self.exchange_halts,
            cleared=cleared,
            remembered=len(self.open_halts),
        )

    def loop_corporate_actions(self) -> None:
        events = src.fetch_corporate_actions()
        upcoming = src.next_corporate_action(events, now())
        self.ca = {s: int(v["at"].timestamp()) for s, v in upcoming.items() if s in set(POOL)}
        self.source_ok_at["corporate_actions"] = time.time()
        log("corporate_actions", total=len(events), pool=self.ca)

    # ------------------------------------------------------------- writing

    def publish(self, force: bool = False) -> bool:
        """Push only what changed. A symbol we did not manage to read is left
        alone: its observedAt goes stale and the contract holds it by itself."""
        wall = time.time()
        stale = [
            name for name, budget in SOURCE_BUDGET.items()
            if wall - self.source_ok_at.get(name, 0.0) > budget
        ]
        if stale:
            # Say nothing rather than say something we can no longer see.
            log("publish_skipped", stale_sources=stale)
            health["stale_sources"] = stale
            return False
        health["stale_sources"] = []

        t = int(now().timestamp())
        ids, sigs, changed = [], [], []
        for sym in POOL:
            if sym not in self.sessions:
                continue
            session = self.sessions[sym]
            halt = self.exchange_halts.get(sym) or self.issuer_halts.get(sym, 0)
            ca_at = self.ca.get(sym, 0)
            seen = self.price_seen_at.get(sym, 0.0)
            price_at = int(seen) if wall - seen <= PRICE_BUDGET else 0
            prev = self.state.last(sym)
            if prev == (session, halt, ca_at):
                # nothing moved, but observedAt still has to be refreshed
                pass
            else:
                changed.append(sym)
            ids.append(symbol_id(sym))
            sigs.append((session, halt, ca_at, price_at, t))
            self.state.save(sym, session, halt, ca_at, price_at)

        if not ids or (not changed and not force):
            return False
        tx = self.chain.send(self.chain.signal.functions.setBatch(ids, sigs))
        health["last_tx"] = tx
        log("published", symbols=len(ids), changed=changed, heartbeat=force and not changed, tx=tx)
        return True

    def loop_prices(self) -> None:
        stocks, prices, seen = [], [], {}
        for sym in POOL:
            q = src.fetch_price(sym)
            if q is None:
                continue
            e8 = int(round(q * 1e8))
            seen[sym] = q
            self.price_seen_at[sym] = time.time()
            prev = self.state.last_price(sym)
            if prev and abs(e8 - prev) * 10_000 <= PRICE_DEADBAND_BPS * prev:
                continue
            stocks.append(Web3.to_checksum_address(self.chain.token_of(symbol_id(sym))))
            prices.append(e8)
            self.state.save_price(sym, e8)
        if stocks:
            tx = self.chain.send(self.chain.amm.functions.setPrices(stocks, prices))
            health["last_tx"] = tx
            log("prices", pushed=len(stocks), quotes=seen, tx=tx)
        else:
            log("prices", pushed=0, quotes=seen)

    def loop_sweep(self) -> None:
        """Cash that cannot be spent yet should not sit idle. Only accounts whose
        creator asked for this are touched; the contract enforces that too."""
        for address in self.accounts:
            acct = self.chain.creator_account(address)
            try:
                if not acct.functions.sweepToTreasury().call():
                    continue
                if acct.functions.pendingUsdg().call() == 0:
                    continue
                if self.chain.usdg_balance(address) == 0:
                    continue
            except Exception as e:
                log("sweep_read_error", account=address, error=repr(e))
                continue
            tx = self.chain.send(acct.functions.sweepIdle())
            health["last_tx"] = tx
            log("swept", account=address, tx=tx)

    def loop_buys(self) -> None:
        """Batch the waiting cash into buys. Anyone can call this; the keeper
        just does it on a schedule so creators do not have to."""
        buyable = any(
            self.chain.signal.functions.check(symbol_id(s)).call()[0] for s in self.sessions
        )
        if not buyable:
            log("buys", skipped="nothing the tape allows right now")
            return
        for address in self.accounts:
            acct = self.chain.creator_account(address)
            _, pending, _, _ = acct.functions.statement().call()
            if pending == 0:
                continue
            tx = self.chain.send(acct.functions.executeBuys())
            health["last_tx"] = tx
            log("buys", account=address, pending=pending, tx=tx)

    def discover_accounts(self) -> None:
        """Every account the router has ever created, read from its own events —
        a creator who onboards through the web app is picked up without anyone
        editing this file."""
        try:
            self.accounts = self.chain.creator_accounts()
        except Exception as e:
            log("discover_error", error=repr(e))
            return
        log("accounts", n=len(self.accounts), accounts=self.accounts)


# --------------------------------------------------------------------- health


class HealthHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        body = json.dumps(health, default=str).encode()
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


def serve_health(port: int = 8787) -> None:
    threading.Thread(target=HTTPServer(("127.0.0.1", port), HealthHandler).serve_forever, daemon=True).start()


# ----------------------------------------------------------------------- main


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--once", action="store_true", help="single pass, then exit")
    ap.add_argument("--no-health", action="store_true")
    args = ap.parse_args()

    load_dotenv(ROOT / ".env")
    chain = Chain()
    state = State(ROOT / "keeper" / "keeper.db")
    k = Keeper(chain, state)

    if not args.no_health:
        serve_health()

    log("start", keeper=chain.acct.address, balance_okb=round(chain.balance_okb(), 6), pool=POOL)

    order = ["accounts", "assets", "halts", "corporate_actions", "prices", "sweep", "buys"]
    runners = {
        "accounts": k.discover_accounts,
        "assets": k.loop_assets,
        "halts": k.loop_halts,
        "corporate_actions": k.loop_corporate_actions,
        "prices": k.loop_prices,
        "sweep": k.loop_sweep,
        "buys": k.loop_buys,
    }
    due = {name: 0.0 for name in order}

    last_publish = 0.0

    while True:
        for name in order:
            if time.time() < due[name]:
                continue
            try:
                runners[name]()
                health["loops"][name] = now().isoformat()
            except Exception as e:  # a dead source must not take the keeper down
                log("loop_error", loop=name, error=repr(e))
                health["errors"] = (health["errors"] + [f"{name}: {e!r}"])[-10:]
            interval = INTERVALS[name]
            if name == "halts" and k.us_market_open:
                interval = US_MARKET_HALT_POLL
            due[name] = time.time() + interval

        try:
            if k.publish(force=time.time() - last_publish > HEARTBEAT):
                last_publish = time.time()
        except Exception as e:
            log("publish_error", error=repr(e))
            health["errors"] = (health["errors"] + [f"publish: {e!r}"])[-10:]

        if args.once:
            log("done_once", balance_okb=round(chain.balance_okb(), 6))
            return
        time.sleep(5)


if __name__ == "__main__":
    main()
