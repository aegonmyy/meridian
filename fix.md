# Fix Plan

## Confirmed Hub.sol Fix
- `test_allSpokesFresh_path2WhenStale` and related Path-2 tests were failing because `_withdraw` called `_requestAllBalanceReports(...)` internally, so the `onlyRebalancer` check saw the caller, not hub.

  In `src/Hub.sol:_withdraw`, call `this._requestAllBalanceRecords(...)` instead. This makes `msg.sender == address(this)`, which passes `onlyRebalancer`.

- Same issue for user queues in No-spoke setup.

## Still unresolved (likely test or contract/source mismatch issues)
- `DepositFlowTest`: 18 CCIP tests are still failing withERC20InsufficientBalance and assertion mismatches. Source/tests don't explain the balance offsets.
- `AllocationMaths.t.sol`: Both “expect revert” tests fire `call didn’t revert at a lower depth than cheatcode call depth` on Foundry — this is a test/cheatcode-rules issue, not a contract issue.
- `AllocationMathsFuzzTest.t.sol`: Both “expect revert” fuzz tests fail for the same reason.

Next: check `test/units/ccipBasedTests/ccipBasedTests.t.sol`, `test/mocks/Asset.sol`, and `src/Spoke.sol` against the failing paths.
