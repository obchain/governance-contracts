// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
pragma abicoder v2;

import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "@uniswap/v3-core/contracts/interfaces/IERC20Minimal.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";

import {RewardMath} from "../utils/RewardMath.sol";
import {INonfungiblePositionManager} from "../interfaces/INonfungiblePositionManager.sol";
import {IGaugeV2UniV3} from "../interfaces/IGaugeV2UniV3.sol";
import {IRegistry} from "../interfaces/IRegistry.sol";
import "../utils/NFTPositionInfo.sol";
import "../utils/Multicall.sol";
import "../utils/TransferHelperExtended.sol";
import "../interfaces/IUniswapV3Staker.sol";
import "../utils/IncentiveId.sol";
import {INFTStaker} from "../interfaces/INFTStaker.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title Uniswap V3 canonical staking interface
contract BaseGaugeV2UniV3 is IGaugeV2UniV3, IUniswapV3Staker, Multicall, ReentrancyGuard {
    address public refundee;

    IRegistry public immutable override registry;

    IUniswapV3Pool public immutable pool;

    /// @notice Represents a staking incentive
    struct Incentive {
        uint256 totalRewardUnclaimed;
        uint160 totalSecondsClaimedX128;
        uint96 numberOfStakes;
    }

    /// @notice Represents the deposit of a liquidity NFT
    struct Deposit {
        address owner;
        uint48 numberOfStakes;
        int24 tickLower;
        int24 tickUpper;
    }

    /// @notice Represents a staked liquidity NFT
    struct Stake {
        uint160 secondsPerLiquidityInsideInitialX128;
        uint96 liquidityNoOverflow;
        uint128 liquidityIfOverflow;
        uint128 nonDerivedLiquidity;
    }

    /// @inheritdoc IUniswapV3Staker
    IUniswapV3Factory public override factory;
    /// @inheritdoc IUniswapV3Staker
    INonfungiblePositionManager
        public
        override nonfungiblePositionManager;

    /// @inheritdoc IUniswapV3Staker
    uint256 public override maxIncentiveStartLeadTime;
    /// @inheritdoc IUniswapV3Staker
    uint256 public override maxIncentiveDuration;

    /// @dev bytes32 refers to the return value of IncentiveId.compute
    mapping(bytes32 => Incentive) public override incentives;

    /// @dev deposits[tokenId] => Deposit
    mapping(uint256 => Deposit) public override deposits;

    /// @dev stakes[tokenId][incentiveHash] => Stake
    mapping(uint256 => mapping(bytes32 => Stake)) private _stakes;

    /// @dev _incentiveKeys[token] => IncentiveKey
    mapping (address => IncentiveKey) private _incentiveKeys;

    uint256 public totalSupply;

    bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;

    /// @inheritdoc IUniswapV3Staker
    function stakes(uint256 tokenId, bytes32 incentiveId)
        public
        view
        override
        returns (
            uint160 secondsPerLiquidityInsideInitialX128,
            uint128 liquidity
        )
    {
        Stake storage stake = _stakes[tokenId][incentiveId];
        secondsPerLiquidityInsideInitialX128 = stake
            .secondsPerLiquidityInsideInitialX128;
        liquidity = stake.liquidityNoOverflow;
        if (liquidity == type(uint96).max) {
            liquidity = stake.liquidityIfOverflow;
        }
    }

    /// @dev rewards[rewardToken][owner] => uint256
    /// @inheritdoc IUniswapV3Staker
    mapping(IERC20Minimal => mapping(address => uint256))
        public
        override rewards;

    /// @param _factory the Uniswap V3 factory
    /// @param _nonfungiblePositionManager the NFT position manager contract address
    /// @param _maxIncentiveStartLeadTime the max duration of an incentive in seconds
    /// @param _maxIncentiveDuration the max amount of seconds into the future the incentive startTime can be set
    constructor(
        address _pool,
        address _registry,
        address _refundee,
        IUniswapV3Factory _factory,
        INonfungiblePositionManager _nonfungiblePositionManager,
        uint256 _maxIncentiveStartLeadTime,
        uint256 _maxIncentiveDuration
    ) {
        pool = IUniswapV3Pool(_pool);
        registry = IRegistry(_registry);

        refundee = _refundee;
        factory = _factory;
        nonfungiblePositionManager = _nonfungiblePositionManager;
        maxIncentiveStartLeadTime = _maxIncentiveStartLeadTime;
        maxIncentiveDuration = _maxIncentiveDuration;
    }

    function _createIncentive(IncentiveKey memory key, uint256 reward, bool isFirstTime)
        internal
    {
        require(
            reward > 0,
            "UniswapV3Staker::createIncentive: reward must be positive"
        );

        if (isFirstTime) {
            // If the key is used first time, do basic start time validations.
            require(
                block.timestamp <= key.startTime,
                "UniswapV3Staker::createIncentive: start time must be now or in the future"
            );

            require(
                key.startTime - block.timestamp <= maxIncentiveStartLeadTime,
                "UniswapV3Staker::createIncentive: start time too far into future"
            );
        }

        require(
            key.startTime < key.endTime,
            "UniswapV3Staker::createIncentive: start time must be before end time"
        );
        require(
            key.endTime - key.startTime <= maxIncentiveDuration,
            "UniswapV3Staker::createIncentive: incentive duration is too long"
        );

        bytes32 incentiveId = IncentiveId.compute(key);

        incentives[incentiveId].totalRewardUnclaimed += reward;

        TransferHelperExtended.safeTransferFrom(
            address(key.rewardToken),
            msg.sender,
            address(this),
            reward
        );

        emit IncentiveCreated(
            key.rewardToken,
            key.pool,
            key.startTime,
            key.endTime,
            key.refundee,
            reward
        );
    }

    /// @inheritdoc IUniswapV3Staker
    function endIncentive(IncentiveKey memory key)
        external
        override
        returns (uint256 refund)
    {
        require(
            block.timestamp >= key.endTime,
            "UniswapV3Staker::endIncentive: cannot end incentive before end time"
        );

        bytes32 incentiveId = IncentiveId.compute(key);
        Incentive storage incentive = incentives[incentiveId];

        refund = incentive.totalRewardUnclaimed;

        require(
            refund > 0,
            "UniswapV3Staker::endIncentive: no refund available"
        );
        require(
            incentive.numberOfStakes == 0,
            "UniswapV3Staker::endIncentive: cannot end incentive while deposits are staked"
        );

        // issue the refund
        incentive.totalRewardUnclaimed = 0;
        TransferHelperExtended.safeTransfer(
            address(key.rewardToken),
            key.refundee,
            refund
        );

        // note we never clear totalSecondsClaimedX128

        emit IncentiveEnded(incentiveId, refund);
    }

    /// @notice Upon receiving a Uniswap V3 ERC721, creates the token deposit setting owner to `from`. Also stakes token
    /// in one or more incentives if properly formatted `data` has a length > 0.
    /// @inheritdoc IERC721Receiver
    function onERC721Received(
        address,
        address from,
        uint256 tokenId,
        bytes calldata data
    ) external override returns (bytes4) {
        require(
            msg.sender == address(nonfungiblePositionManager),
            "UniswapV3Staker::onERC721Received: not a univ3 nft"
        );

        (
            ,
            ,
            ,
            ,
            ,
            int24 tickLower,
            int24 tickUpper,
            ,
            ,
            ,
            ,

        ) = nonfungiblePositionManager.positions(tokenId);

        deposits[tokenId] = Deposit({
            owner: from,
            numberOfStakes: 0,
            tickLower: tickLower,
            tickUpper: tickUpper
        });
        emit DepositTransferred(tokenId, address(0), from);

        if (data.length > 0) {
            if (data.length == 160) {
                _stakeToken(abi.decode(data, (IncentiveKey)), tokenId);
            } else {
                IncentiveKey[] memory keys = abi.decode(data, (IncentiveKey[]));
                for (uint256 i = 0; i < keys.length; i++) {
                    _stakeToken(keys[i], tokenId);
                }
            }
        }
        return this.onERC721Received.selector;
    }

    /// @inheritdoc IUniswapV3Staker
    function transferDeposit(uint256 tokenId, address to) external override {
        require(
            to != address(0),
            "UniswapV3Staker::transferDeposit: invalid transfer recipient"
        );
        address owner = deposits[tokenId].owner;
        require(
            owner == msg.sender,
            "UniswapV3Staker::transferDeposit: can only be called by deposit owner"
        );
        deposits[tokenId].owner = to;
        emit DepositTransferred(tokenId, owner, to);
    }

    /// @inheritdoc IUniswapV3Staker
    function withdrawToken(
        uint256 tokenId,
        address to,
        bytes memory data
    ) external override {
        require(
            to != address(this),
            "UniswapV3Staker::withdrawToken: cannot withdraw to staker"
        );
        Deposit memory deposit = deposits[tokenId];
        require(
            deposit.numberOfStakes == 0,
            "UniswapV3Staker::withdrawToken: cannot withdraw token while staked"
        );
        require(
            deposit.owner == msg.sender,
            "UniswapV3Staker::withdrawToken: only owner can withdraw token"
        );

        delete deposits[tokenId];
        emit DepositTransferred(tokenId, deposit.owner, address(0));

        nonfungiblePositionManager.safeTransferFrom(
            address(this),
            to,
            tokenId,
            data
        );
    }

    /// @inheritdoc IUniswapV3Staker
    function stakeToken(IncentiveKey memory key, uint256 tokenId)
        external
        override
    {
        require(
            deposits[tokenId].owner == msg.sender,
            "UniswapV3Staker::stakeToken: only owner can stake token"
        );

        _stakeToken(key, tokenId);
    }

    /// @inheritdoc IUniswapV3Staker
    function unstakeToken(IncentiveKey memory key, uint256 tokenId)
        external
        override
    {
        Deposit memory deposit = deposits[tokenId];
        // anyone can call unstakeToken if the block time is after the end time of the incentive
        if (block.timestamp < key.endTime) {
            require(
                deposit.owner == msg.sender,
                "UniswapV3Staker::unstakeToken: only owner can withdraw token before incentive end time"
            );
        }

        bytes32 incentiveId = IncentiveId.compute(key);

        (
            uint160 secondsPerLiquidityInsideInitialX128,
            uint128 liquidity
        ) = stakes(tokenId, incentiveId);

        totalSupply -= uint256(_stakes[tokenId][incentiveId].nonDerivedLiquidity);

        require(
            liquidity != 0,
            "UniswapV3Staker::unstakeToken: stake does not exist"
        );
        require(
            key.pool == pool,
            "UniswapV3Staker::stakeToken: token pool is not the incentive pool"
        );

        Incentive storage incentive = incentives[incentiveId];

        deposits[tokenId].numberOfStakes--;
        incentive.numberOfStakes--;

        (, uint160 secondsPerLiquidityInsideX128, ) = key
            .pool
            .snapshotCumulativesInside(deposit.tickLower, deposit.tickUpper);
        (uint256 reward, uint160 secondsInsideX128) = RewardMath
            .computeRewardAmount(
                incentive.totalRewardUnclaimed,
                incentive.totalSecondsClaimedX128,
                key.startTime,
                key.endTime,
                liquidity,
                secondsPerLiquidityInsideInitialX128,
                secondsPerLiquidityInsideX128,
                block.timestamp
            );

        // if this overflows, e.g. after 2^32-1 full liquidity seconds have been claimed,
        // reward rate will fall drastically so it's safe
        incentive.totalSecondsClaimedX128 += secondsInsideX128;
        // reward is never greater than total reward unclaimed
        incentive.totalRewardUnclaimed -= reward;
        // this only overflows if a token has a total supply greater than type(uint256).max
        rewards[key.rewardToken][deposit.owner] += reward;

        Stake storage stake = _stakes[tokenId][incentiveId];
        delete stake.secondsPerLiquidityInsideInitialX128;
        delete stake.liquidityNoOverflow;
        if (liquidity >= type(uint96).max) delete stake.liquidityIfOverflow;
        emit TokenUnstaked(tokenId, incentiveId);
    }

    /// @inheritdoc IUniswapV3Staker
    function claimReward(
        IERC20Minimal rewardToken,
        address to,
        uint256 amountRequested
    ) external override returns (uint256 reward) {
        reward = rewards[rewardToken][msg.sender];
        if (amountRequested != 0 && amountRequested < reward) {
            reward = amountRequested;
        }

        rewards[rewardToken][msg.sender] -= reward;
        TransferHelperExtended.safeTransfer(address(rewardToken), to, reward);

        emit RewardClaimed(to, reward);
    }

    /// @inheritdoc IUniswapV3Staker
    function getRewardInfo(IncentiveKey memory key, uint256 tokenId)
        external
        view
        override
        returns (uint256 reward, uint160 secondsInsideX128)
    {
        bytes32 incentiveId = IncentiveId.compute(key);

        (
            uint160 secondsPerLiquidityInsideInitialX128,
            uint128 liquidity
        ) = stakes(tokenId, incentiveId);
        require(
            liquidity > 0,
            "UniswapV3Staker::getRewardInfo: stake does not exist"
        );

        Deposit memory deposit = deposits[tokenId];
        Incentive memory incentive = incentives[incentiveId];

        (, uint160 secondsPerLiquidityInsideX128, ) = key
            .pool
            .snapshotCumulativesInside(deposit.tickLower, deposit.tickUpper);

        (reward, secondsInsideX128) = RewardMath.computeRewardAmount(
            incentive.totalRewardUnclaimed,
            incentive.totalSecondsClaimedX128,
            key.startTime,
            key.endTime,
            liquidity,
            secondsPerLiquidityInsideInitialX128,
            secondsPerLiquidityInsideX128,
            block.timestamp
        );
    }

    /// @dev Stakes a deposited token without doing an ownership check
    function _stakeToken(IncentiveKey memory key, uint256 tokenId) private {
        require(
            block.timestamp >= key.startTime,
            "UniswapV3Staker::stakeToken: incentive not started"
        );
        require(
            block.timestamp < key.endTime,
            "UniswapV3Staker::stakeToken: incentive ended"
        );

        bytes32 incentiveId = IncentiveId.compute(key);

        require(
            incentives[incentiveId].totalRewardUnclaimed > 0,
            "UniswapV3Staker::stakeToken: non-existent incentive"
        );
        require(
            _stakes[tokenId][incentiveId].liquidityNoOverflow == 0,
            "UniswapV3Staker::stakeToken: token already staked"
        );

        (
            IUniswapV3Pool _pool,
            int24 tickLower,
            int24 tickUpper,
            uint128 _liquidity
        ) = NFTPositionInfo.getPositionInfo(
                factory,
                nonfungiblePositionManager,
                tokenId
            );

        totalSupply += uint256(_liquidity);
        uint128 liquidity = uint128(derivedLiquidity(_liquidity, deposits[tokenId].owner));

        require(
            _pool == key.pool && _pool == pool,
            "UniswapV3Staker::stakeToken: token pool is not the incentive pool"
        );
        require(
            liquidity > 0,
            "UniswapV3Staker::stakeToken: cannot stake token with 0 liquidity"
        );

        deposits[tokenId].numberOfStakes++;
        incentives[incentiveId].numberOfStakes++;

        (, uint160 secondsPerLiquidityInsideX128, ) = _pool
            .snapshotCumulativesInside(tickLower, tickUpper);

        if (liquidity >= type(uint96).max) {
            _stakes[tokenId][incentiveId] = Stake({
                secondsPerLiquidityInsideInitialX128: secondsPerLiquidityInsideX128,
                liquidityNoOverflow: type(uint96).max,
                liquidityIfOverflow: liquidity,
                nonDerivedLiquidity: _liquidity
            });
        } else {
            Stake storage stake = _stakes[tokenId][incentiveId];
            stake
                .secondsPerLiquidityInsideInitialX128 = secondsPerLiquidityInsideX128;
            stake.liquidityNoOverflow = uint96(liquidity);
        }

        emit TokenStaked(tokenId, incentiveId, liquidity);
    }

    function derivedLiquidity(uint256 liquidity, address account)
        public
        view
        returns (uint256)
    {
        uint256 _derived = (liquidity * 20) / 100;
        uint256 _adjusted = 0;
        uint256 _supply = IERC20(registry.locker()).totalSupply();

        if (_supply > 0) {
            _adjusted = INFTStaker(registry.staker()).balanceOf(account);
            _adjusted = (((totalSupply * _adjusted) / _supply) * 80) / 100;
        }

        // because of this we are able to max out the boost by 5x
        return Math.min((_derived + _adjusted), liquidity);
    }

    function notifyRewardAmount(address token, uint256 amount)
        external
        override
        nonReentrant
    {
        IERC20Minimal _token = IERC20Minimal(token);

        IncentiveKey memory _key = _incentiveKeys[token];
        bool isFirstTime = false;

        // Check if this token is already part of any incentive key.
        if (address(_key.rewardToken) == address(0)) {
            _key = IUniswapV3Staker.IncentiveKey({
                rewardToken: _token,
                pool: pool,
                startTime: block.timestamp,
                endTime: type(uint256).max,
                refundee: refundee
            });

            // If no, then create new incentive key and store it to
            // be able to map it next time.
            _incentiveKeys[token] = _key;

            // Also mark that this key is being used first time.
            isFirstTime = true;
        }

        _createIncentive(_key, amount, isFirstTime);
    }
}
