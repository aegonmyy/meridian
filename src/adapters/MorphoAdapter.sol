// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity 0.8.33;
import {IYieldSource} from "../interfaces/IYieldSource.sol";
import {IMorpho, MarketParams, Market, Id, Position} from "../interfaces/morpho/IMorpho.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MarketParamsLib} from "../interfaces/morpho/utils/MarketParamsLib.sol";
import {MathLib} from "../interfaces/morpho/utils/MathLib.sol";

/// @title MorphoAdapter
/// @notice Yield adapter that routes assets into a configured Morpho market.
contract morphoAdapter is IYieldSource {
    using MarketParamsLib for MarketParams;
    using SafeERC20 for IERC20;
    using MathLib for uint256;

    MarketParams public marketparams;
    IERC20 public immutable ASSET;
    IMorpho public immutable MORPHO;

    /// @notice Raised when a required constructor address is zero.
    error ZeroAddress();

    /// @param _asset Underlying ERC20 asset.
    /// @param _morpho Morpho core contract.
    /// @param _loanToken Market loan token.
    /// @param _collateralToken Market collateral token.
    /// @param _oracle Market oracle.
    /// @param _irm Market interest rate model.
    /// @param _lltv Market liquidation loan-to-value.
    constructor(
        address _asset,
        address _morpho,
        address _loanToken,
        address _collateralToken,
        address _oracle,
        address _irm,
        uint256 _lltv
    ) {
        if (
            _asset == address(0) ||
            _morpho == address(0) ||
            _loanToken == address(0) ||
            _collateralToken == address(0) ||
            _oracle == address(0) ||
            _irm == address(0)
        ) {
            revert ZeroAddress();
        }
        ASSET = IERC20(_asset);
        MORPHO = IMorpho(_morpho);
        marketparams = MarketParams({
            loanToken: _loanToken,
            collateralToken: _collateralToken,
            oracle: _oracle,
            irm: _irm,
            lltv: _lltv
        });
        ASSET.forceApprove(_morpho, type(uint256).max);
    }

    /// @inheritdoc IYieldSource
    function deposit(uint256 _amount) external {
        MarketParams memory params = marketparams;
        ASSET.safeTransferFrom(msg.sender, address(this), _amount);
        MORPHO.supply(params, _amount, 0, address(this), "");
    }

    /// @inheritdoc IYieldSource
    function withdraw(uint256 _amount) external {
        MarketParams memory params = marketparams;
        (uint256 assetsWithdrawn, ) = MORPHO.withdraw(
            params,
            _amount,
            0,
            address(this),
            address(this)
        );
        ASSET.safeTransfer(msg.sender, assetsWithdrawn);
    }

    /// @notice Returns underlying assets claimable by this adapter in Morpho.
    /// @dev Uses share-to-asset conversion against current market totals.
    function totalAssets() external view returns (uint256) {
        Id marketId = marketparams.id();
        Position memory position = MORPHO.position(marketId, address(this));
        if (position.supplyShares == 0) return 0;

        Market memory market = MORPHO.market(marketId);
        if (market.totalSupplyShares == 0) return 0;

        return
            position.supplyShares.mulDivDown(
                market.totalSupplyAssets,
                market.totalSupplyShares
            );
    }
}
