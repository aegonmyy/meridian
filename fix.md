# Fix Plan

## Test Run Summary
- `forge test` reports 215 passing tests and 42 failing tests.
- The failures cluster into a small set of root causes. The notes below map each cluster to the likely fix.

## 1. AllocationMaths unit and fuzz tests
- `test_netApy_revert_underflow()` and `test_weightedApy_revert_lengthMismatch()` fail because the tests use `vm.expectRevert` against internal library calls. Foundry only observes the revert at an external call boundary, so the cheatcode never sees the failure at the expected depth.
- `test_validateAllocation_validSingleChain()`, `test_validateAllocation_zeroAllowedAsMinimum()`, and `test_validateAllocation_exactlyMaxPerMarket()` fail because the test fixtures contradict the current allocation policy. `AllocationMaths.validateAllocation()` rejects any chain total above 8000 bps, so a single-chain 10000 bps allocation cannot pass with the current implementation.
- `testFuzz_validateAllocation_dustAllocationAlwaysFalse()` is unsatisfiable as written. `rest = 10_000 - dust` is always greater than 6000 when `dust` is in `[1, 499]`, so the `vm.assume(rest <= 6000)` gate rejects every input.
- `testFuzz_weightedApy_revert_lengthMismatch()` has the same revert-depth issue as the unit test.
- Proposed fix: use an external harness for the revert tests, rewrite the validate-allocation fixtures to obey the 8000 bps chain cap, and replace the impossible dust fuzz constraint with a satisfiable construction.

## 2. AgentConsumer constructor test
- `test_constructor_revert_zeroOwner()` fails because `Ownable(_owner)` reverts first with OpenZeppelin's `OwnableInvalidOwner` before the contract body can reach `InvalidConstructorArguments()`.
- Root cause: constructor evaluation order, not business logic.
- Proposed fix: update the test to expect `OwnableInvalidOwner`, or refactor the constructor if the project wants to preserve the custom error.

## 3. Hub invariant failure
- `invariant_spokeChainSelectorsLengthNeverDecreases()` fails during replay of `addSpoke(uint64,address)`.
- Root cause: the invariant/handler pair is too loose. The handler accepts arbitrary spoke addresses, while the invariant assumes the selector array and the ghost state always remain in lockstep. That assumption breaks when the generated sequence reaches a state the handler does not model correctly.
- Proposed fix: constrain the handler to register only valid spoke addresses, or relax the invariant to track monotonic growth separately from remove/re-add behavior.

## 4. Withdraw path 1 and path 2 zero-amount checks
- `test_withdraw_path1_revert_zeroAmount()` and `test_withdrawPath2_revert_zeroAmount()` fail because `HUB._withdraw()` does not reject `assets == 0`.
- Root cause: the withdrawal path calculates shares and proceeds without an explicit zero-asset guard.
- Proposed fix: add a zero-amount revert in `src/Hub.sol` before any state mutation.

## 5. Withdraw path 3 and recall flow
- `test_findBestSpoke_singleSpoke()`, `test_findBestSpoke_recallsFromHighestBalance()`, `test_recallFromSpoke_fullRecall()`, `test_recallFromSpoke_hubUSDCBalanceIncreases()`, `test_recallFromSpoke_inTransitBackToZero()`, `test_recallFromSpoke_pendingWithdrawal_*`, and `test_withdraw_path3_*` all point to the same issue.
- Root cause: the path-3 branch in `HUB._withdraw()` recalls the full withdrawal amount from the spoke instead of only the shortfall after idle balance is considered. When idle is 1000 and the user withdraws 10000, the hub asks the spoke for 10000, which can underflow or revert with `ERC20InsufficientBalance`.
- Proposed fix: compute and recall only `assets - idle` in the path-3 branch, then settle the remainder from idle. The pending-withdrawal accounting should be based on the shortfall, not the full amount.

## 6. Rebalance flow
- `test_handleRebalance_noTokensReturnToHub()` and `test_rebalance_noTokensLeaveSpokeChain[_v2]()` fail because `HUB._sendToSpoke()` attaches USDC token amounts for every nonzero instruction payload, including `REBALANCE` messages.
- Root cause: an intra-spoke rebalance should move capital between adapters that already live on the spoke. Sending fresh USDC from the hub changes hub idle balance and breaks the "no tokens leave the chain" expectation.
- Proposed fix: split deposit-style CCIP messages from rebalance messages, and only attach token amounts for true deposit or withdrawal flows.
- `test_totalManagedAssets_reflectsYieldOnMultipleSpokes()` is consistent with the same accounting mismatch: once the rebalance/deposit path is corrected, the reported total should line up with the manual balance setup in the test.

## 7. MockYieldSource test
- `test_withdraw_returnsUserBalance()` panics with arithmetic underflow because the test seeds the token balance but not the adapter's private `_totalAssets` accounting variable.
- Root cause: the mock adapter's `withdraw()` subtracts from `_totalAssets`, so writing only the ERC20 balance slot does not initialize the contract state the method reads.
- Proposed fix: seed `_totalAssets` through the actual mock flow, or write the adapter storage slot that backs `_totalAssets` in the test setup.

## 8. Rebalancer unit tests
- `test_addChainToWhitelist_emitsEvent()`, `test_addProtocolToWhitelist_emitsEvent()`, `test_removeChainFromWhitelist_emitsEvent()`, and `test_removeProtocolFromWhitelist_emitsEvent()` fail because the whitelist mutators do not emit any events.
- Root cause: the tests expect event coverage, but the implementation only flips the mapping value.
- Proposed fix: add the four missing emit statements in `src/Rebalancer.sol`, or drop the event assertions if events are not part of the intended API.
- `test_rebalance_agentConsumerCanCall()`, `test_rebalance_cooldownTriggersAfterSuccess()`, `test_rebalance_happyPath_sourceDecreases()`, `test_rebalance_happyPath_targetIncreases()`, `test_rebalance_revert_cooldownNotElapsed()`, `test_rebalance_succeedsAfterCooldownElapsed()`, and `test_rebalance_updatesLastRebalanceTimestamp()` fail because the current test fixture is hitting the hub authorization path before the rebalance flow is fully aligned with the deployed contract addresses and setup.
- Proposed fix: verify the final `REBALANCER` address in the hub/rebalancer setup, then rerun the happy-path tests. If the authorization is correct, the remaining failures are downstream of the rebalance accounting issue above.

## 9. Fuzz revert assumption issue
- `testFuzz_validateAllocation_dustAllocationAlwaysFalse()` also contributes to the fuzz rejection count because the assumptions are impossible to satisfy for the current bounds.
- Proposed fix: replace the impossible range with a generated allocation shape that can actually satisfy the helper constraints while still proving the property.

## Recommended order of fixes
- Fix the `Hub._withdraw()` zero-amount and path-3 shortfall bugs first.
- Fix the rebalance token-transfer behavior next.
- Then align the AllocationMaths tests with the actual policy, or change the policy if the current limits are not intended.
- Finally, patch the event expectations and the mock adapter test setup.
