pragma solidity ^0.6.0;

import '@openzeppelin/contracts/math/Math.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/SafeERC20.sol';
import '@openzeppelin/contracts/utils/ReentrancyGuard.sol';

import {ICurve} from './curve/Curve.sol';
import {IOracle} from './interfaces/IOracle.sol';
import {IBoardroom} from './interfaces/IBoardroom.sol';
import {IBasisAsset} from './interfaces/IBasisAsset.sol';
import {Babylonian} from './lib/Babylonian.sol';
import {FixedPoint} from './lib/FixedPoint.sol';
import {Safe112} from './lib/Safe112.sol';
import {Operator} from './owner/Operator.sol';
import {Epoch} from './utils/Epoch.sol';
import {ContractGuard} from './utils/ContractGuard.sol';

/**
 * @title Basis Cash Treasury contract
 * @notice Monetary policy logic to adjust supplies of basis cash assets
 * @author Summer Smith & Rick Sanchez
 */
contract Treasury is ContractGuard, Epoch {
    using FixedPoint for *;
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;
    using Safe112 for uint112;

    /* ========== STATE VARIABLES ========== */

    // ========== FLAGS
    bool public migrated = false;
    bool public initialized = false;

    // ========== CORE
    address public cash;
    address public bond;
    address public share;
    address public curve;
    address public boardroom;

    address public bondOracle;
    address public seigniorageOracle;

    // ========== PARAMS
    uint256 public cashPriceOne;

    uint256 public lastBondOracleEpoch = 0;
    uint256 public cashConversionLimit = 0;
    uint256 public accumulatedSeigniorage = 0;
    uint256 public accumulatedCashConversion = 0;

    /* ========== CONSTRUCTOR ========== */

    constructor(
        address _cash,
        address _bond,
        address _share,
        address _bondOracle,
        address _seigniorageOracle,
        address _boardroom,
        address _curve,
        uint256 _startTime
    ) public Epoch(1 days, _startTime, 0) {
        cash = _cash;
        bond = _bond;
        share = _share;
        curve = _curve;
        bondOracle = _bondOracle;
        seigniorageOracle = _seigniorageOracle;

        boardroom = _boardroom;

        cashPriceOne = 10**18;
    }

    /* =================== Modifier =================== */

    modifier checkMigration {
        require(!migrated, 'Treasury: migrated');

        _;
    }

    modifier checkOperator {
        require(
            IBasisAsset(cash).operator() == address(this) &&
                IBasisAsset(bond).operator() == address(this) &&
                IBasisAsset(share).operator() == address(this) &&
                Operator(boardroom).operator() == address(this),
            'Treasury: need more permission'
        );

        _;
    }

    modifier updatePrice {
        _;

        _updateCashPrice();
    }

    /* ========== VIEW FUNCTIONS ========== */

    // budget
    function getReserve() public view returns (uint256) {
        return accumulatedSeigniorage;
    }

    function circulatingSupply() public view returns (uint256) {
        return IERC20(cash).totalSupply().sub(accumulatedSeigniorage);
    }

    function getCeilingPrice() public view returns (uint256) {
        return ICurve(curve).calcCeiling(circulatingSupply());
    }

    // oracle
    function getBondOraclePrice() public view returns (uint256) {
        return _getCashPrice(bondOracle);
    }

    function getSeigniorageOraclePrice() public view returns (uint256) {
        return _getCashPrice(seigniorageOracle);
    }

    function _getCashPrice(address oracle) internal view returns (uint256) {
        try IOracle(oracle).consult(cash, 1e18) returns (uint256 price) {
            return price;
        } catch {
            revert('Treasury: failed to consult cash price from the oracle');
        }
    }

    /* ========== GOVERNANCE ========== */

    // MIGRATION
    function initialize() public checkOperator {
        require(!initialized, 'Treasury: initialized');

        // set accumulatedSeigniorage to it's balance
        accumulatedSeigniorage = IERC20(cash).balanceOf(address(this));

        initialized = true;
        emit Initialized(msg.sender, block.number);
    }

    function migrate(address target) public onlyOperator checkOperator {
        require(!migrated, 'Treasury: migrated');

        // cash
        Operator(cash).transferOperator(target);
        Operator(cash).transferOwnership(target);
        IERC20(cash).transfer(target, IERC20(cash).balanceOf(address(this)));

        // bond
        Operator(bond).transferOperator(target);
        Operator(bond).transferOwnership(target);
        IERC20(bond).transfer(target, IERC20(bond).balanceOf(address(this)));

        // share
        Operator(share).transferOperator(target);
        Operator(share).transferOwnership(target);
        IERC20(share).transfer(target, IERC20(share).balanceOf(address(this)));

        migrated = true;
        emit Migration(target);
    }

    

    // ORACLE
    function setBondOracle(address newOracle) public onlyOperator {
        address oldOracle = bondOracle;
        bondOracle = newOracle;
        emit BondOracleChanged(msg.sender, oldOracle, newOracle);
    }

    function setSeigniorageOracle(address newOracle) public onlyOperator {
        address oldOracle = seigniorageOracle;
        seigniorageOracle = newOracle;
        emit SeigniorageOracleChanged(msg.sender, oldOracle, newOracle);
    }

    // TWEAK
    function setCeilingCurve(address newCurve) public onlyOperator {
        address oldCurve = newCurve;
        curve = newCurve;
        emit CeilingCurveChanged(msg.sender, oldCurve, newCurve);
    }

    /* ========== MUTABLE FUNCTIONS ========== */

    function _updateConversionLimit(uint256 cashPrice) internal {
        uint256 currentEpoch = Epoch(bondOracle).getLastEpoch(); // lastest update time
        if (lastBondOracleEpoch != currentEpoch) {
            uint256 percentage = cashPriceOne.sub(cashPrice);
            cashConversionLimit = circulatingSupply().mul(percentage).div(1e18);
            accumulatedCashConversion = 0;

            lastBondOracleEpoch = currentEpoch;
        }
    }

    function _updateCashPrice() internal {
        if (Epoch(bondOracle).callable()) {
            try IOracle(bondOracle).update() {} catch {}
        }
        if (Epoch(seigniorageOracle).callable()) {
            try IOracle(seigniorageOracle).update() {} catch {}
        }
    }

    function buyBonds(uint256 amount, uint256 targetPrice)
        external
        onlyOneBlock
        checkMigration
        checkStartTime
        checkOperator
        updatePrice
    {
        require(amount > 0, 'Treasury: cannot purchase bonds with zero amount');

        uint256 cashPrice = _getCashPrice(bondOracle);
        require(cashPrice <= targetPrice, 'Treasury: cash price moved');
        require(
            cashPrice < cashPriceOne, // price < $1
            'Treasury: cashPrice not eligible for bond purchase'
        );
        _updateConversionLimit(cashPrice);

        // swap exact limit
        amount = Math.min(
            amount,
            cashConversionLimit.sub(accumulatedCashConversion)
        );
        accumulatedCashConversion = accumulatedCashConversion.add(amount);

        if (amount == 0) {
            return;
        }

        uint256 bondPrice = cashPrice;

        IBasisAsset(cash).burnFrom(msg.sender, amount);
        IBasisAsset(bond).mint(msg.sender, amount.mul(1e18).div(bondPrice));

        emit BoughtBonds(msg.sender, amount);
    }

    function redeemBonds(uint256 amount)
        external
        onlyOneBlock
        checkMigration
        checkStartTime
        checkOperator
        updatePrice
    {
        require(amount > 0, 'Treasury: cannot redeem bonds with zero amount');

        uint256 cashPrice = _getCashPrice(bondOracle);
        require(
            cashPrice > getCeilingPrice(), // price > $1.05
            'Treasury: cashPrice not eligible for bond purchase'
        );
        require(
            IERC20(cash).balanceOf(address(this)) >= amount,
            'Treasury: treasury has no more budget'
        );

        accumulatedSeigniorage = accumulatedSeigniorage.sub(
            Math.min(accumulatedSeigniorage, amount)
        );

        IBasisAsset(bond).burnFrom(msg.sender, amount);
        IERC20(cash).safeTransfer(msg.sender, amount);

        emit RedeemedBonds(msg.sender, amount);
    }

    function allocateSeigniorage()
        external
        onlyOneBlock
        checkMigration
        checkStartTime
        checkEpoch
        checkOperator
    {
        _updateCashPrice();
        uint256 cashPrice = _getCashPrice(seigniorageOracle);
        if (cashPrice <= getCeilingPrice()) {
            return; // just advance epoch instead revert
        }

        // circulating supply
        uint256 percentage = cashPrice.sub(cashPriceOne);
        uint256 seigniorage = circulatingSupply().mul(percentage).div(1e18);
        IBasisAsset(cash).mint(address(this), seigniorage);

        // boardroom
        IERC20(cash).safeApprove(boardroom, seigniorage);
        IBoardroom(boardroom).allocateSeigniorage(seigniorage);
        emit BoardroomFunded(now, seigniorage);
    }

    /* ========== EVENTS ========== */

    // GOV
    event Initialized(address indexed executor, uint256 at);
    event Migration(address indexed target);
    event ContributionPoolChanged(
        address indexed operator,
        address oldFund,
        address newFund
    );
    event ContributionPoolRateChanged(
        address indexed operator,
        uint256 oldRate,
        uint256 newRate
    );
    event BondOracleChanged(
        address indexed operator,
        address oldOracle,
        address newOracle
    );
    event SeigniorageOracleChanged(
        address indexed operator,
        address oldOracle,
        address newOracle
    );
    event CeilingCurveChanged(
        address indexed operator,
        address oldCurve,
        address newCurve
    );

    // CORE
    event RedeemedBonds(address indexed from, uint256 amount);
    event BoughtBonds(address indexed from, uint256 amount);
    event BoardroomFunded(uint256 timestamp, uint256 seigniorage);
    event ContributionPoolFunded(uint256 timestamp, uint256 seigniorage);
}
