// SPDX-License-Identifier: LicenseRef-Gyro-1.0
// for information on licensing please see the README in the GitHub repository <https://github.com/gyrostable/concentrated-lps>.

pragma solidity 0.7.6;
pragma experimental ABIEncoderV2;

// import "@balancer-labs/v2-solidity-utils/contracts/math/FixedPoint.sol";
import "../../libraries/GyroFixedPoint.sol";

import "@balancer-labs/v2-pool-weighted/contracts/WeightedPoolUserDataHelpers.sol";
import "@balancer-labs/v2-pool-weighted/contracts/WeightedPool2TokensMiscData.sol";

import "../../libraries/GyroConfigKeys.sol";
import "../../libraries/GyroErrors.sol";
import "../../interfaces/IGyroConfig.sol";
import "../../libraries/GyroPoolMath.sol";

import "../ExtensibleWeightedPool2Tokens.sol";
import "./GyroECLPMath.sol";
import "./GyroECLPOracleMath.sol";
import "../CappedLiquidity.sol";
import "../LocallyPausable.sol";

contract GyroECLPPool is ExtensibleWeightedPool2Tokens, CappedLiquidity, LocallyPausable {
    using GyroFixedPoint for uint256;
    using WeightedPoolUserDataHelpers for bytes;
    using WeightedPool2TokensMiscData for bytes32;
    using SafeCast for int256;
    using SafeCast for uint256;

    uint256 private constant _MINIMUM_BPT = 1e6;

    /// @notice Parameters of the ECLP pool
    int256 public immutable _paramsAlpha;
    int256 public immutable _paramsBeta;
    int256 public immutable _paramsC;
    int256 public immutable _paramsS;
    int256 public immutable _paramsLambda;
    int256 public immutable _tauAlphaX;
    int256 public immutable _tauAlphaY;
    int256 public immutable _tauBetaX;
    int256 public immutable _tauBetaY;
    int256 public immutable _u;
    int256 public immutable _v;
    int256 public immutable _w;
    int256 public immutable _z;
    int256 public immutable _dSq;

    IGyroConfig public gyroConfig;

    struct GyroParams {
        NewPoolParams baseParams;
        GyroECLPMath.Params eclpParams;
        GyroECLPMath.DerivedParams derivedEclpParams;
        address capManager;
        CapParams capParams;
        address pauseManager;
    }

    event ECLPParamsValidated(bool paramsValidated);
    event ECLPDerivedParamsValidated(bool derivedParamsValidated);

    event InvariantAterInitializeJoin(uint256 invariantAfterJoin);
    event InvariantOldAndNew(uint256 oldInvariant, uint256 newInvariant);

    event SwapParams(uint256[] balances, GyroECLPMath.Vector2 invariant, uint256 amount);

    event OracleIndexUpdated(uint256 oracleUpdatedIndex);

    constructor(GyroParams memory params, address configAddress)
        ExtensibleWeightedPool2Tokens(params.baseParams)
        CappedLiquidity(params.capManager, params.capParams)
        LocallyPausable(params.pauseManager)
    {
        _grequire(configAddress != address(0x0), GyroECLPPoolErrors.ADDRESS_IS_ZERO_ADDRESS);

        GyroECLPMath.validateParams(params.eclpParams);
        emit ECLPParamsValidated(true);

        GyroECLPMath.validateDerivedParamsLimits(params.eclpParams, params.derivedEclpParams);
        emit ECLPDerivedParamsValidated(true);

        (_paramsAlpha, _paramsBeta, _paramsC, _paramsS, _paramsLambda) = (
            params.eclpParams.alpha,
            params.eclpParams.beta,
            params.eclpParams.c,
            params.eclpParams.s,
            params.eclpParams.lambda
        );

        (_tauAlphaX, _tauAlphaY, _tauBetaX, _tauBetaY, _u, _v, _w, _z, _dSq) = (
            params.derivedEclpParams.tauAlpha.x,
            params.derivedEclpParams.tauAlpha.y,
            params.derivedEclpParams.tauBeta.x,
            params.derivedEclpParams.tauBeta.y,
            params.derivedEclpParams.u,
            params.derivedEclpParams.v,
            params.derivedEclpParams.w,
            params.derivedEclpParams.z,
            params.derivedEclpParams.dSq
        );

        gyroConfig = IGyroConfig(configAddress);
    }

    /** @dev reconstructs ECLP params structs from immutable arrays */
    function reconstructECLPParams() internal view returns (GyroECLPMath.Params memory params, GyroECLPMath.DerivedParams memory d) {
        (params.alpha, params.beta, params.c, params.s, params.lambda) = (_paramsAlpha, _paramsBeta, _paramsC, _paramsS, _paramsLambda);
        (d.tauAlpha.x, d.tauAlpha.y, d.tauBeta.x, d.tauBeta.y) = (_tauAlphaX, _tauAlphaY, _tauBetaX, _tauBetaY);
        (d.u, d.v, d.w, d.z, d.dSq) = (_u, _v, _w, _z, _dSq);
    }

    function getECLPParams() external view returns (GyroECLPMath.Params memory params, GyroECLPMath.DerivedParams memory d) {
        return reconstructECLPParams();
    }

    /**
     * @dev Returns the current value of the invariant.
     */
    // TODO WIP killing this routine to pipe DerivedParams through differently.
    //    function getInvariant() public view override returns (int256) {
    //        (, uint256[] memory balances, ) = getVault().getPoolTokens(getPoolId());
    //
    //        // Since the Pool hooks always work with upscaled balances, we manually
    //        // upscale here for consistency
    //        _upscaleArray(balances);
    //
    //        return GyroECLPMath.calculateInvariant(balances, eclpParams, derived);
    //    }

    // Swap Hooks

    function onSwap(
        SwapRequest memory request,
        uint256 balanceTokenIn,
        uint256 balanceTokenOut
    ) public virtual override whenNotPaused onlyVault(request.poolId) returns (uint256) {
        bool tokenInIsToken0;

        if (request.tokenIn == _token0 && request.tokenOut == _token1) {
            tokenInIsToken0 = true;
        } else if (request.tokenIn == _token1 && request.tokenOut == _token0) {
            tokenInIsToken0 = false;
        } else {
            _revert(GyroECLPPoolErrors.TOKEN_IN_IS_NOT_TOKEN_0);
        }

        uint256 scalingFactorTokenIn = _scalingFactor(tokenInIsToken0);
        uint256 scalingFactorTokenOut = _scalingFactor(!tokenInIsToken0);

        // All token amounts are upscaled.
        balanceTokenIn = _upscale(balanceTokenIn, scalingFactorTokenIn);
        balanceTokenOut = _upscale(balanceTokenOut, scalingFactorTokenOut);

        // We "undo" the pre-processing that the caller of onSwap() did: In contrast to other pools, we don't exploit
        // symmetry here, and we identify the two tokens explicitly.
        uint256[] memory balances = _balancesFromTokenInOut(balanceTokenIn, balanceTokenOut, tokenInIsToken0);

        (GyroECLPMath.Params memory eclpParams, GyroECLPMath.DerivedParams memory derivedECLPParams) = reconstructECLPParams();
        GyroECLPMath.Vector2 memory invariant;
        {
            (int256 currentInvariant, int256 invErr) = GyroECLPMath.calculateInvariantWithError(balances, eclpParams, derivedECLPParams);
            // invariant = overestimate in x-component, underestimate in y-component
            // No overflow in `+` due to constraints to the different values enforced in GyroECLPMath.
            invariant = GyroECLPMath.Vector2(currentInvariant + 2 * invErr, currentInvariant);

            // Update price oracle with the pre-swap balances. Vs other pools, we need to do this after invariant is calculated
            _updateOracle(request.lastChangeBlock, balances, currentInvariant.toUint256(), eclpParams, derivedECLPParams);
        }

        if (request.kind == IVault.SwapKind.GIVEN_IN) {
            // Fees are subtracted before scaling, to reduce the complexity of the rounding direction analysis.
            // This is amount - fee amount, so we round up (favoring a higher fee amount).
            uint256 feeAmount = request.amount.mulUp(getSwapFeePercentage());
            request.amount = _upscale(request.amount.sub(feeAmount), scalingFactorTokenIn);

            uint256 amountOut = _onSwapGivenIn(request, balances, tokenInIsToken0, eclpParams, derivedECLPParams, invariant);

            emit SwapParams(balances, invariant, amountOut);

            // amountOut tokens are exiting the Pool, so we round down.
            return _downscaleDown(amountOut, scalingFactorTokenOut);
        } else {
            request.amount = _upscale(request.amount, scalingFactorTokenOut);

            uint256 amountIn = _onSwapGivenOut(request, balances, tokenInIsToken0, eclpParams, derivedECLPParams, invariant);

            emit SwapParams(balances, invariant, amountIn);

            // amountIn tokens are entering the Pool, so we round up.
            amountIn = _downscaleUp(amountIn, scalingFactorTokenIn);

            // Fees are added after scaling happens, to reduce the complexity of the rounding direction analysis.
            // This is amount + fee amount, so we round up (favoring a higher fee amount).
            return amountIn.divUp(getSwapFeePercentage().complement());
        }
    }

    function _onSwapGivenIn(
        SwapRequest memory swapRequest,
        uint256[] memory balances,
        bool tokenInIsToken0,
        GyroECLPMath.Params memory eclpParams,
        GyroECLPMath.DerivedParams memory derivedECLPParams,
        GyroECLPMath.Vector2 memory invariant
    ) private pure returns (uint256) {
        // Swaps are disabled while the contract is paused.
        return GyroECLPMath.calcOutGivenIn(balances, swapRequest.amount, tokenInIsToken0, eclpParams, derivedECLPParams, invariant);
    }

    function _onSwapGivenOut(
        SwapRequest memory swapRequest,
        uint256[] memory balances,
        bool tokenInIsToken0,
        GyroECLPMath.Params memory eclpParams,
        GyroECLPMath.DerivedParams memory derivedECLPParams,
        GyroECLPMath.Vector2 memory invariant
    ) private pure returns (uint256) {
        // Swaps are disabled while the contract is paused.
        return GyroECLPMath.calcInGivenOut(balances, swapRequest.amount, tokenInIsToken0, eclpParams, derivedECLPParams, invariant);
    }

    /**
     * @dev Called when the Pool is joined for the first time; that is, when the BPT total supply is zero.
     *
     * Returns the amount of BPT to mint, and the token amounts the Pool will receive in return.
     *
     * Minted BPT will be sent to `recipient`, except for _MINIMUM_BPT, which will be deducted from this amount and sent
     * to the zero address instead. This will cause that BPT to remain forever locked there, preventing total BTP from
     * ever dropping below that value, and ensuring `_onInitializePool` can only be called once in the entire Pool's
     * lifetime.
     *
     * The tokens granted to the Pool will be transferred from `sender`. These amounts are considered upscaled and will
     * be downscaled (rounding up) before being returned to the Vault.
     */
    function _onInitializePool(
        bytes32,
        address,
        address,
        bytes memory userData
    ) internal override returns (uint256, uint256[] memory) {
        BaseWeightedPool.JoinKind kind = userData.joinKind();
        _require(kind == BaseWeightedPool.JoinKind.INIT, Errors.UNINITIALIZED);

        uint256[] memory amountsIn = userData.initialAmountsIn();
        InputHelpers.ensureInputLengthMatch(amountsIn.length, 2);
        _upscaleArray(amountsIn);

        (GyroECLPMath.Params memory eclpParams, GyroECLPMath.DerivedParams memory derivedECLPParams) = reconstructECLPParams();
        uint256 invariantAfterJoin = GyroECLPMath.calculateInvariant(amountsIn, eclpParams, derivedECLPParams);

        emit InvariantAterInitializeJoin(invariantAfterJoin);

        // Set the initial BPT to the value of the invariant times the number of tokens. This makes BPT supply more
        // consistent in Pools with similar compositions but different number of tokens.

        uint256 bptAmountOut = Math.mul(invariantAfterJoin, 2);

        _lastInvariant = invariantAfterJoin;

        return (bptAmountOut, amountsIn);
    }

    /**
     * @dev Called whenever the Pool is joined after the first initialization join (see `_onInitializePool`).
     *
     * Returns the amount of BPT to mint, the token amounts that the Pool will receive in return, and the number of
     * tokens to pay in protocol swap fees.
     *
     * Implementations of this function might choose to mutate the `balances` array to save gas (e.g. when
     * performing intermediate calculations, such as subtraction of due protocol fees). This can be done safely.
     *
     * Minted BPT will be sent to `recipient`.
     *
     * The tokens granted to the Pool will be transferred from `sender`. These amounts are considered upscaled and will
     * be downscaled (rounding up) before being returned to the Vault.
     *
     * Due protocol swap fees will be taken from the Pool's balance in the Vault (see `IBasePool.onJoinPool`). These
     * amounts are considered upscaled and will be downscaled (rounding down) before being returned to the Vault.
     *
     * protocolSwapFeePercentage argument is intentionally unused as protocol fees are handled in a different way
     */
    function _onJoinPool(
        bytes32,
        address,
        address recipient,
        uint256[] memory balances,
        uint256 lastChangeBlock,
        uint256, //protocolSwapFeePercentage,
        bytes memory userData
    )
        internal
        override
        returns (
            uint256,
            uint256[] memory,
            uint256[] memory
        )
    {
        // Due protocol swap fee amounts are computed by measuring the growth of the invariant between the previous join
        // or exit event and now - the invariant's growth is due exclusively to swap fees. This avoids spending gas
        // computing them on each individual swap
        (GyroECLPMath.Params memory eclpParams, GyroECLPMath.DerivedParams memory derivedECLPParams) = reconstructECLPParams();
        uint256 invariantBeforeAction = GyroECLPMath.calculateInvariant(balances, eclpParams, derivedECLPParams);

        // Update price oracle with the pre-exit balances. Vs other pools, we need to do this after invariant is calculated
        _updateOracle(lastChangeBlock, balances, invariantBeforeAction, eclpParams, derivedECLPParams);

        _distributeFees(invariantBeforeAction);

        (uint256 bptAmountOut, uint256[] memory amountsIn) = _doJoin(balances, userData);

        if (_capParams.capEnabled) {
            _ensureCap(bptAmountOut, balanceOf(recipient), totalSupply());
        }

        // Since we pay fees in BPT, they have not changed the invariant and 'invariantBeforeAction' is still consistent with
        // 'balances'. Therefore, we can use a simplified method to update the invariant that does not require a full
        // re-computation.
        // Note: Should this be changed in the future, we also need to reduce the invariant proportionally by the total
        // protocol fee factor.
        _lastInvariant = GyroPoolMath.liquidityInvariantUpdate(invariantBeforeAction, bptAmountOut, totalSupply(), true);

        emit InvariantOldAndNew(invariantBeforeAction, _lastInvariant);

        // returns a new uint256[](2) b/c Balancer vault is expecting a fee array, but fees paid in BPT instead
        return (bptAmountOut, amountsIn, new uint256[](2));
    }

    function _doJoin(uint256[] memory balances, bytes memory userData) internal view returns (uint256 bptAmountOut, uint256[] memory amountsIn) {
        BaseWeightedPool.JoinKind kind = userData.joinKind();

        // We do NOT currently support unbalanced update, i.e., EXACT_TOKENS_IN_FOR_BPT_OUT or TOKEN_IN_FOR_EXACT_BPT_OUT
        if (kind == BaseWeightedPool.JoinKind.ALL_TOKENS_IN_FOR_EXACT_BPT_OUT) {
            (bptAmountOut, amountsIn) = _joinAllTokensInForExactBPTOut(balances, userData);
        } else {
            _revert(Errors.UNHANDLED_JOIN_KIND);
        }
    }

    function _joinAllTokensInForExactBPTOut(uint256[] memory balances, bytes memory userData)
        internal
        view
        override
        returns (uint256, uint256[] memory)
    {
        uint256 bptAmountOut = userData.allTokensInForExactBptOut();
        // Note that there is no maximum amountsIn parameter: this is handled by `IVault.joinPool`.

        uint256[] memory amountsIn = GyroPoolMath._calcAllTokensInGivenExactBptOut(balances, bptAmountOut, totalSupply());

        return (bptAmountOut, amountsIn);
    }

    /**
     * @dev Called whenever the Pool is exited.
     *
     * Returns the amount of BPT to burn, the token amounts for each Pool token that the Pool will grant in return, and
     * the number of tokens to pay in protocol swap fees.
     *
     * Implementations of this function might choose to mutate the `balances` array to save gas (e.g. when
     * performing intermediate calculations, such as subtraction of due protocol fees). This can be done safely.
     *
     * BPT will be burnt from `sender`.
     *
     * The Pool will grant tokens to `recipient`. These amounts are considered upscaled and will be downscaled
     * (rounding down) before being returned to the Vault.
     *
     * Due protocol swap fees will be taken from the Pool's balance in the Vault (see `IBasePool.onExitPool`). These
     * amounts are considered upscaled and will be downscaled (rounding down) before being returned to the Vault.
     *
     * protocolSwapFeePercentage argument is intentionally unused as protocol fees are handled in a different way
     */
    function _onExitPool(
        bytes32,
        address,
        address,
        uint256[] memory balances,
        uint256 lastChangeBlock,
        uint256, // protocolSwapFeePercentage,
        bytes memory userData
    )
        internal
        override
        returns (
            uint256 bptAmountIn,
            uint256[] memory amountsOut,
            uint256[] memory dueProtocolFeeAmounts
        )
    {
        // Exits are not completely disabled while the contract is paused: proportional exits (exact BPT in for tokens
        // out) remain functional.
        (GyroECLPMath.Params memory eclpParams, GyroECLPMath.DerivedParams memory derivedECLPParams) = reconstructECLPParams();

        // Note: If the contract is paused, swap protocol fee amounts are not charged and the oracle is not updated
        // to avoid extra calculations and reduce the potential for errors.
        if (_isNotPaused()) {
            // Due protocol swap fee amounts are computed by measuring the growth of the invariant between the previous
            // join or exit event and now - the invariant's growth is due exclusively to swap fees. This avoids
            // spending gas calculating the fees on each individual swap.
            uint256 invariantBeforeAction = GyroECLPMath.calculateInvariant(balances, eclpParams, derivedECLPParams);

            // Update price oracle with the pre-exit balances. Vs other pools, we need to do this after invariant is calculated
            _updateOracle(lastChangeBlock, balances, invariantBeforeAction, eclpParams, derivedECLPParams);

            _distributeFees(invariantBeforeAction);

            (bptAmountIn, amountsOut) = _doExit(balances, userData);

            // Since we pay fees in BPT, they have not changed the invariant and 'invariantBeforeAction' is still consistent with
            // 'balances'. Therefore, we can use a simplified method to update the invariant that does not require a full
            // re-computation.
            // Note: Should this be changed in the future, we also need to reduce the invariant proportionally by the total
            // protocol fee factor.
            _lastInvariant = GyroPoolMath.liquidityInvariantUpdate(invariantBeforeAction, bptAmountIn, totalSupply(), false);

            emit InvariantOldAndNew(invariantBeforeAction, _lastInvariant);
        } else {
            // Note: If the contract is paused, swap protocol fee amounts are not charged and the oracle is not updated
            // to avoid extra calculations and reduce the potential for errors.
            (bptAmountIn, amountsOut) = _doExit(balances, userData);

            // Invalidate _lastInvariant. We do not compute the invariant to make sure the pool is not locking
            // up b/c numerical limits might be violated. Instead, we set the invariant such that any following
            // (non-paused) join/exit will ignore and recompute it. (see GyroPoolMath._calcProtocolFees())
            _lastInvariant = type(uint256).max;
        }

        // returns a new uint256[](2) b/c Balancer vault is expecting a fee array, but fees paid in BPT instead
        return (bptAmountIn, amountsOut, new uint256[](2));
    }

    function _doExit(uint256[] memory balances, bytes memory userData) internal view returns (uint256 bptAmountIn, uint256[] memory amountsOut) {
        BaseWeightedPool.ExitKind kind = userData.exitKind();

        // We do NOT support unbalanced exit at the moment, i.e., EXACT_BPT_IN_FOR_ONE_TOKEN_OUT or
        // BPT_IN_FOR_EXACT_TOKENS_OUT.
        if (kind == BaseWeightedPool.ExitKind.EXACT_BPT_IN_FOR_TOKENS_OUT) {
            (bptAmountIn, amountsOut) = _exitExactBPTInForTokensOut(balances, userData);
        } else {
            _revert(Errors.UNHANDLED_EXIT_KIND);
        }
    }

    function _exitExactBPTInForTokensOut(uint256[] memory balances, bytes memory userData)
        internal
        view
        override
        returns (uint256, uint256[] memory)
    {
        // This exit function is the only one that is not disabled if the contract is paused: it remains unrestricted
        // in an attempt to provide users with a mechanism to retrieve their tokens in case of an emergency.
        // This particular exit function is the only one that remains available because it is the simplest one, and
        // therefore the one with the lowest likelihood of errors.

        uint256 bptAmountIn = userData.exactBptInForTokensOut();
        // Note that there is no minimum amountOut parameter: this is handled by `IVault.exitPool`.

        uint256[] memory amountsOut = GyroPoolMath._calcTokensOutGivenExactBptIn(balances, bptAmountIn, totalSupply());
        return (bptAmountIn, amountsOut);
    }

    // Helpers.

    function _balancesFromTokenInOut(
        uint256 balanceTokenIn,
        uint256 balanceTokenOut,
        bool tokenInIsToken0
    ) internal pure returns (uint256[] memory balances) {
        balances = new uint256[](2);
        if (tokenInIsToken0) {
            balances[0] = balanceTokenIn;
            balances[1] = balanceTokenOut;
        } else {
            balances[0] = balanceTokenOut;
            balances[1] = balanceTokenIn;
        }
    }

    /**
     * @dev Updates the Price Oracle based on the Pool's current state (balances, BPT supply and invariant). Must be
     * called on *all* state-changing functions with the balances *before* the state change happens, and with
     * `lastChangeBlock` as the number of the block in which any of the balances last changed.
     */
    function _updateOracle(
        uint256 lastChangeBlock,
        uint256[] memory balances,
        uint256 invariant,
        GyroECLPMath.Params memory eclpParams,
        GyroECLPMath.DerivedParams memory derivedECLPParams
    ) internal {
        bytes32 miscData = _miscData;
        if (miscData.oracleEnabled() && block.number > lastChangeBlock) {
            uint256 spotPrice = GyroECLPMath.calculatePrice(balances, eclpParams, derivedECLPParams, invariant.toInt256());

            int256 logSpotPrice = GyroECLPOracleMath._calcLogSpotPrice(spotPrice);

            // // can optionally log BPT spot price using this code. Instead, we log L/S
            // int256 logBPTPrice = GyroECLPOracleMath._calcLogBPTPrice(
            //     balances[0],
            //     balances[1],
            //     spotPrice,
            //     miscData.logTotalSupply()
            // );

            int256 logInvariantDivSupply = GyroECLPOracleMath._calcLogInvariantDivSupply(invariant, miscData.logTotalSupply());

            uint256 oracleCurrentIndex = miscData.oracleIndex();
            uint256 oracleCurrentSampleInitialTimestamp = miscData.oracleSampleCreationTimestamp();
            uint256 oracleUpdatedIndex = _processPriceData(
                oracleCurrentSampleInitialTimestamp,
                oracleCurrentIndex,
                logSpotPrice,
                logInvariantDivSupply, // replaces logBPTPrice
                miscData.logInvariant()
            );

            if (oracleCurrentIndex != oracleUpdatedIndex) {
                // solhint-disable not-rely-on-time
                miscData = miscData.setOracleIndex(oracleUpdatedIndex);
                miscData = miscData.setOracleSampleCreationTimestamp(block.timestamp);
                _miscData = miscData;

                emit OracleIndexUpdated(oracleUpdatedIndex);
            }
        }
    }

    // Override unused inherited function
    // this intentionally does not revert so that it will be bypassed on onJoinPool inherited from ExtensibleWeightedPool2Tokens
    // the above overloading implementation of _updateOracle takes different arguments and processes the oracle update in a different place
    // Note: this is identical to the handling in Gyro2CLPPool.sol
    function _updateOracle(
        uint256,
        uint256,
        uint256
    ) internal pure override {
        // solhint-disable-previous-line no-empty-blocks
        // Do nothing.
    }

    // Fee helpers. These are exactly the same as in the Gyro2CLPPool.
    // TODO prob about time to make a base class.

    /**
     * Note: This function is identical to that used in Gyro2CLPPool.sol
     * @dev Computes and distributes fees between the Balancer and the Gyro treasury
     * The fees are computed and distributed in BPT rather than using the
     * Balancer regular distribution mechanism which would pay these in underlying
     */

    function _distributeFees(uint256 invariantBeforeAction) internal {
        // calculate Protocol fees in BPT
        // lastInvariant is the invariant logged at the end of the last liquidity update
        // protocol fees are calculated on swap fees earned between liquidity updates
        (uint256 gyroFees, uint256 balancerFees, address gyroTreasury, address balTreasury) = _getDueProtocolFeeAmounts(
            _lastInvariant,
            invariantBeforeAction
        );

        // Pay fees in BPT
        _payFeesBpt(gyroFees, balancerFees, gyroTreasury, balTreasury);
    }

    /**
     * Note: This function is identical to that used in Gyro2CLPPool.sol
     * @dev this function overrides inherited function to make sure it is never used
     */
    function _getDueProtocolFeeAmounts(
        uint256[] memory, // balances,
        uint256[] memory, // normalizedWeights,
        uint256, // previousInvariant,
        uint256, // currentInvariant,
        uint256 // protocolSwapFeePercentage
    ) internal pure override returns (uint256[] memory) {
        revert("Not implemented");
    }

    /**
     * @dev
     * Note: This function is identical to that used in Gyro2CLPPool.sol.
     * Calculates protocol fee amounts in BPT terms.
     * protocolSwapFeePercentage is not used here b/c we take parameters from GyroConfig instead.
     * Returns: BPT due to Gyro, BPT due to Balancer, receiving address for Gyro fees, receiving address for Balancer
     * fees.
     */
    function _getDueProtocolFeeAmounts(uint256 previousInvariant, uint256 currentInvariant)
        internal
        view
        returns (
            uint256,
            uint256,
            address,
            address
        )
    {
        (uint256 protocolSwapFeePerc, uint256 protocolFeeGyroPortion, address gyroTreasury, address balTreasury) = _getFeesMetadata();

        // Early return if the protocol swap fee percentage is zero, saving gas.
        if (protocolSwapFeePerc == 0) {
            return (0, 0, gyroTreasury, balTreasury);
        }

        // Calculate fees in BPT
        (uint256 gyroFees, uint256 balancerFees) = GyroPoolMath._calcProtocolFees(
            previousInvariant,
            currentInvariant,
            totalSupply(),
            protocolSwapFeePerc,
            protocolFeeGyroPortion
        );

        return (gyroFees, balancerFees, gyroTreasury, balTreasury);
    }

    // Note: This function is identical to that used in Gyro2CLPPool.sol
    function _payFeesBpt(
        uint256 gyroFees,
        uint256 balancerFees,
        address gyroTreasury,
        address balTreasury
    ) internal {
        // Pay fees in BPT to gyro treasury
        if (gyroFees > 0) {
            _mintPoolTokens(gyroTreasury, gyroFees);
        }
        // Pay fees in BPT to bal treasury
        if (balancerFees > 0) {
            _mintPoolTokens(balTreasury, balancerFees);
        }
    }

    // Note: This function is identical to that used in Gyro2CLPPool.sol
    function _getFeesMetadata()
        internal
        view
        returns (
            uint256,
            uint256,
            address,
            address
        )
    {
        return (
            gyroConfig.getUint(GyroConfigKeys.PROTOCOL_SWAP_FEE_PERC_KEY),
            gyroConfig.getUint(GyroConfigKeys.PROTOCOL_FEE_GYRO_PORTION_KEY),
            gyroConfig.getAddress(GyroConfigKeys.GYRO_TREASURY_KEY),
            gyroConfig.getAddress(GyroConfigKeys.BAL_TREASURY_KEY)
        );
    }

    function _setPausedState(bool paused) internal override {
        _setPaused(paused);
    }
}
