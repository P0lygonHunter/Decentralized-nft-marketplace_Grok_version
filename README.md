# NexusMarket – Production-Oriented NFT Marketplace (Grok Version)

Improved version of the original NexusMarket contract with production hardening, full test suite (unit + fuzz + invariant), and gas reporting support.

## Structure

```
src/
  NexusMarket.sol          # Main contract
test/
  NexusMarket.t.sol        # Unit + Integration + Negative/Exploit tests
  NexusMarket.fuzz.t.sol   # Fuzz tests
  NexusMarket.invariant.t.sol # Invariant tests
foundry.toml
README.md
```

## Key Improvements

- Full event coverage (Mint, List, Cancel, Sale, Commit, Withdraw, Admin)
- `cancelListing()` function
- OpenZeppelin `Pausable` (emergency stop)
- Stricter CEI in sale path
- Better view helpers for frontend commitment calculation
- Clearer access control & zero-address checks
- Listing auto-cancelled on any transfer (with event)
- Platform fee + royalty edge-case handling

## How to run tests (Foundry)

```bash
# Install Foundry: https://book.getfoundry.sh/getting-started/installation
forge install OpenZeppelin/openzeppelin-contracts --no-commit
forge install foundry-rs/forge-std --no-commit

# Unit + negative tests
forge test --match-path test/NexusMarket.t.sol -vv

# Fuzz tests
forge test --match-path test/NexusMarket.fuzz.t.sol -vv

# Invariant tests
forge test --match-path test/NexusMarket.invariant.t.sol -vv

# Gas report
forge test --gas-report

# Everything
forge test -vv --gas-report
```

Works on **WSL Ubuntu**, native Linux, and macOS. Windows native also works if Foundry is installed.

## Security notes for manual audit

1. Commit-reveal still relies on correct frontend binding.
2. Pull pattern is used – royalty / fee recipients must call `withdraw()`.
3. Owner can pause and change fee/recipient.
4. No on-chain cancellation for signature orders (standard for off-chain orders).
5. `MAX_COMMIT_AGE = 1 days`.
6. Invariant handler does not track every possible royalty receiver – extend if needed.

**Audit carefully before mainnet use.**
