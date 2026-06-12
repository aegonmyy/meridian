update all withdraw type to rebalance done

add more types to cciphelpers

will add :
targetAdapter - adapter to deposit into after rebalance
targetamount = amount to withdraw from adapter and deposit to target

removed sending back tokens in handle rebalance in spoke

implemented all types updates to instruction

next we handle rebalance case from hub

will be adding a new specific function in hub called rebalance

i added a new function to hub whose purpose is to recieve instruction and tag it rebalancer message type then send

implementing in rebalance a dedicated function that builds the rebalance message then sends to hub

we need bytes32 adapter; - the source of where to withdraw
        uint256 amount; - the amount to withdraw
        bytes32 targetAdapter; - the target ofwhere to deposit
        uint256 targetAmount; - the target of how much to deposit
rebalance messageTYpe might not need targetAmoount after all, only amount, the entirety of what is withdrawn is deposited in target

my plan now was to do precise checks against the constraint and not re use allocation proposal struct

implemented raw sending to hub with precise variables without any of the checks

compiles, time to make the spoke to handle the rebalance

updated spoke to instead immediately deposit funds back to target in case of rebalance

due to no new funds issued from hub and hub doesnt track specifix adapter balance noneed to update accounting in hub, everything compiles, this is a start there are serious issues particularly in rebalancer.sol

