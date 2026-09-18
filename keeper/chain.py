"""The only part of the keeper that can write. Everything it sends is a fact it
observed; none of it is a decision. The contract decides."""

from __future__ import annotations

import json
import os
import pathlib

from web3 import Web3

ROOT = pathlib.Path(__file__).resolve().parent.parent


def _abi(name: str) -> list:
    art = json.loads((ROOT / "out" / f"{name}.sol" / f"{name}.json").read_text())
    return art["abi"]


class Chain:
    def __init__(self) -> None:
        self.w3 = Web3(Web3.HTTPProvider(os.environ["XLAYER_TESTNET_RPC"], request_kwargs={"timeout": 30}))
        self.acct = self.w3.eth.account.from_key(os.environ["KEEPER_PK"])
        d = json.loads((ROOT / "deployments.1952.json").read_text())
        self.addresses = d
        self.signal = self._c("TapeSignal", d["TapeSignal"])
        self.amm = self._c("MockAMM", d["MockAMM"])
        self.router = self._c("TipRouter", d["TipRouter"])
        self.account_abi = _abi("CreatorAccount")
        self._nonce: int | None = None

    def _c(self, name: str, address: str):
        return self.w3.eth.contract(address=Web3.to_checksum_address(address), abi=_abi(name))

    def creator_account(self, address: str):
        return self.w3.eth.contract(address=Web3.to_checksum_address(address), abi=self.account_abi)

    # -------------------------------------------------------------- sending

    def _next_nonce(self) -> int:
        onchain = self.w3.eth.get_transaction_count(self.acct.address)
        self._nonce = onchain if self._nonce is None else max(self._nonce, onchain)
        n = self._nonce
        self._nonce += 1
        return n

    def send(self, fn) -> str:
        """Any failure hands the nonce back to the node. Holding on to a local
        count after a tx that never landed would leave every later transaction
        stuck behind a gap."""
        try:
            tx = fn.build_transaction({
                "from": self.acct.address,
                "nonce": self._next_nonce(),
                "gasPrice": int(self.w3.eth.gas_price * 1.2),
            })
            signed = self.acct.sign_transaction(tx)
            h = self.w3.eth.send_raw_transaction(signed.raw_transaction)
            receipt = self.w3.eth.wait_for_transaction_receipt(h, timeout=120)
        except Exception:
            self._nonce = None
            raise
        if receipt.status != 1:
            self._nonce = None
            raise RuntimeError(f"tx reverted: {h.hex()}")
        return h.hex()

    def balance_okb(self) -> float:
        return self.w3.eth.get_balance(self.acct.address) / 1e18

    # ---------------------------------------------------------------- reads

    def onchain_signal(self, symbol_id: bytes) -> dict:
        s = self.signal.functions.signals(symbol_id).call()
        return {"session": s[0], "halt": s[1], "ca_at": s[2], "price_at": s[3], "observed_at": s[4]}

    def token_of(self, symbol_id: bytes) -> str:
        return self.router.functions.tokenOf(symbol_id).call()
