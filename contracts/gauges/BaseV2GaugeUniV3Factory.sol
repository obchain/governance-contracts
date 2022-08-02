// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";

import {IRegistry} from "../interfaces/IRegistry.sol";
import {BaseGaugeV2UniV3} from "./BaseGaugeV2UniV3.sol";
import {IGaugeV2UniV3Factory} from "../interfaces/IGaugeV2UniV3Factory.sol";
import {INonfungiblePositionManager} from "../interfaces/INonfungiblePositionManager.sol";

contract BaseV2GaugeUniV3Factory is IGaugeV2UniV3Factory {
    function createGauge(
        address _pool,
        address _bribe,
        address _registry,
        address _refundee,
        IUniswapV3Factory _factory,
        INonfungiblePositionManager _nonfungiblePositionManager,
        uint256 _maxIncentiveStartLeadTime,
        uint256 _maxIncentiveDuration
    ) external override returns (address) {
        address guage = address(new BaseGaugeV2UniV3(
            _pool,
            _registry,
            _refundee,
            _factory,
            _nonfungiblePositionManager,
            _maxIncentiveStartLeadTime,
            _maxIncentiveDuration
        ));

        emit GaugeCreated(
            guage,
            _pool,
            _bribe,
            _registry,
            _refundee,
            address(_factory),
            address(_nonfungiblePositionManager),
            _maxIncentiveStartLeadTime,
            _maxIncentiveDuration
        );

        return guage;
    }
}
