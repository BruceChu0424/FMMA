# 18. Security and compliance

## 18.1 Paper trading only

This system trades on an **Alpaca paper trading account**. No real capital is
involved, and the endpoint is hard-coded:

```c
#define ALPACA_URL  "https://paper-api.alpaca.markets/v2/orders"
```

Pointing it at the live endpoint would require editing the source. Do not.
Nothing in this project — not the strategy, not the risk layer, not the
testing — is adequate for real money, and [08](08-trading-strategy.md) §8.7
says why in detail.

This is a university engineering project demonstrating a hardware/software
latency split. It is not investment advice, it has no edge, and it was never
intended to be profitable.

## 18.2 Credentials

**Rules:**

1. API keys live in the environment, never in a file in this repository.
   ```bash
   export APCA_API_KEY_ID='PK...'
   export APCA_API_SECRET_KEY='...'
   ```
2. the host application reads them with `getenv` and nothing else. There is no
   configuration file, no default and no fallback; with no keys the program
   runs and logs the orders it would have sent.
3. Use `sudo -E` so the environment survives. (Plain `sudo` strips it, and
   the program then reports that the keys are not set.)
4. Paper keys only. They start with `PK`; live keys start with `AK`.
5. `.gitignore` blocks `.env`, `*.key` and `secrets.*`, but the real control
   is that there is nowhere in the code for a key to go.

**Never** paste a key into a source file "just to test it". That is exactly
how §18.4 happened.

## 18.3 Transport security

| Connection | Protection |
|------------|------------|
| Coinbase WebSocket | TLS 1.2+ via OpenSSL, server certificate verified against the system CA bundle, SNI set |
| Alpaca REST | same |

The CA bundle is loaded from `/etc/ssl/certs/ca-certificates.crt` (or
`--ca`), and the program prints a warning if it cannot find one.

This was not true before. Version 1 passed `.ca = mg_str("")`, which
disables the trust-anchor check entirely and leaves only host-name matching
— no protection against an active attacker on the path, which for a program
that sends API keys in a header is a real exposure. It also built mongoose
with its own TLS stack, which cannot complete a handshake with Coinbase at
all ([10](10-build-guide.md) §10.3).

## 18.4 Incident: an API key was committed

**A live Alpaca paper-trading key ID and secret were committed to this
repository and are still reachable in its git history.**

| | |
|---|---|
| Commit | `d65ee28`, titled "Add key" |
| File | `Software/src/`, lines 20–21 at that revision |
| Current state | HEAD reads the credentials from the environment; the literals are gone from the working tree |
| Still exposed | **Yes.** The old blob remains in history and on any clone or fork, including the remote. |

Deleting a file does not remove it from git. Anyone who has ever cloned this
repository, and anyone who can read the remote, can recover those
credentials with one command.

### Required actions, in order

1. **Revoke the key pair in the Alpaca dashboard and issue a new one.** Do
   this first. It is the only step that actually ends the exposure;
   everything else is cleanup.
2. **Check the paper account's activity** for anything you did not do.
3. Decide whether to rewrite history. Because these are paper-trading
   credentials for a throwaway account, revocation is sufficient and a
   rewrite mostly buys tidiness. If you do want them gone:

   ```bash
   # every collaborator must re-clone afterwards; coordinate first
   git clone --mirror <remote> fmma-clean && cd fmma-clean
   git filter-repo --path Software/src/fmma_app.c --invert-paths   # or use BFG
   # re-add the current file, then
   git push --force --all
   ```

   Rewriting history breaks every existing clone. For a three-person
   student project with revoked credentials, revocation alone is the
   proportionate response — but the decision belongs to whoever owns the
   account, not to the tooling.

4. Note it in [`../CHANGELOG.md`](../CHANGELOG.md) so the next person
   understands why the history looks the way it does.

### Why it happened, and what stops it recurring

The original code had the key as a string literal with a comment saying
`<--- Put Alpaca Key Here`, which makes committing it the default action
rather than a mistake. The structural fix is that there is no longer a place
in the source where a key can be written: `getenv` or nothing.

## 18.5 Access and privilege

`marketstream` needs `root` because it maps `/dev/mem`. That is a large
privilege for a program that parses data from the internet, and it is worth
being clear about the exposure and the mitigations:

| | |
|---|---|
| Attack surface | JSON from a TLS-authenticated exchange endpoint |
| Parsing | Hand-written, bounded: `parse_scaled` reads digits and saturates; `json_str_field` builds a bounded pattern and uses `strstr`; message buffers are stack-allocated up to 2 KB and heap-allocated with a checked `malloc` beyond that |
| Mapping | Exactly 4 KB at a fixed physical address, `PROT_READ|PROT_WRITE`, unmapped on exit |
| Reduction available | A UIO device-tree node would let the bridge be mapped without `root`. Worth doing for anything beyond a lab demo. |

The board itself runs a stock Cyclone V image with a password-less `root`
account on the serial console. That is normal for a development image and
completely unsuitable for anything exposed. Keep the board on a private
network.

## 18.6 Third-party code

See [`../THIRD-PARTY-NOTICES.md`](../THIRD-PARTY-NOTICES.md). The important
one: **mongoose is GPL-2.0-only** (or commercial). Linking it makes the
combined `marketstream` binary GPL-2.0, which is why this project's own code
is licensed GPL-2.0 as well. That is a real obligation, not a formality, and
it was not declared anywhere before this revision.

## 18.7 Data handling

No personal data is collected, stored or transmitted. Market data is public.
The only sensitive values in the system are the API credentials, covered
above.

## 18.8 Checklist before any demonstration

```
[ ] the key pair in use is a PAPER key (starts with PK)
[ ] the leaked key from d65ee28 has been revoked
[ ] the endpoint is paper-api.alpaca.markets
[ ] the board is on a private network
[ ] --max-pos is set to something small (3-5)
[ ] a --dry-run has been done first
[ ] nobody's credentials are on screen or in the shell history shown
```
