// SPDX-License-Identifier: MIT

pragma solidity 0.8.9;

/** Imports **/

import "./LBToken.sol";
import "./libraries/BinHelper.sol";
import "./libraries/Math512Bits.sol";
import "./libraries/MathS40x36.sol";
import "./libraries/SafeCast.sol";
import "./libraries/TreeMath.sol";
import "./libraries/ReentrancyGuard.sol";
import "./libraries/SafeTransfer.sol";
import "./interfaces/ILBFactoryHelper.sol";
import "./interfaces/ILBFlashLoanCallback.sol";
import "./interfaces/ILBPair.sol";

/** Errors **/

error LBPair__InsufficientAmounts();
error LBPair__WrongAmounts(uint256 amount0Out, uint256 amount1Out);
error LBPair__BrokenSwapSafetyCheck();
error LBPair__BrokenMintSafetyCheck(uint256 id);
error LBPair__InsufficientLiquidityBurned(uint256 id);
error LBPair__BurnExceedsReserve(uint256 id);
error LBPair__WrongLengths();
error LBPair__MintExceedsAmountsIn(uint256 id);
error LBPair__BinReserveOverflows(uint256 id);
error LBPair__IdOverflows(uint256 id);
error LBPair__FlashLoanUnderflow(uint256 expectedBalance, uint256 balance);
error LBPair__BrokenFlashLoanSafetyChecks(uint256 amount0In, uint256 amount1In);
error LBPair__OnlyStrictlyIncreasingId();
error LBPair__OnlyFactory();

// TODO add oracle price, distribute fees protocol / sJoe
/// @title Liquidity Bin Exchange
/// @author Trader Joe
/// @notice DexV2 POC
contract LBPair is LBToken, ReentrancyGuard, ILBPair {
    /** Libraries **/

    using Math512Bits for uint256;
    using MathS40x36 for int256;
    using TreeMath for mapping(uint256 => uint256)[3];
    using SafeCast for uint256;
    using SafeTransfer for IERC20;
    using FeeHelper for FeeHelper.FeeParameters;

    /** Events **/

    event Swap(
        address indexed sender,
        address indexed recipient,
        uint24 indexed _id,
        uint256 amount0,
        uint256 amount1
    );

    event FlashLoan(
        address indexed sender,
        address indexed recipient,
        uint256 amount0,
        uint256 amount1,
        uint256 fees0,
        uint256 fees1
    );

    event Mint(
        address indexed sender,
        address indexed recipient,
        uint256[] ids,
        uint256[] liquidities
    );

    event Burn(
        address indexed sender,
        address indexed recipient,
        uint256[] ids,
        uint256[] amounts
    );

    event FeesCollected(
        address indexed sender,
        address indexed recipient,
        uint256 amount0,
        uint256 amount1
    );

    event ProtocolFeesCollected(
        address indexed sender,
        address indexed recipient,
        uint256 amount0,
        uint256 amount1
    );

    event FeesParametersSet(bytes32 packedFeeParameters);

    /** Modifiers **/

    modifier OnlyFactory() {
        if (msg.sender != address(factory)) revert LBPair__OnlyFactory();
        _;
    }

    /** Public constant variables **/

    uint256 public constant override PRICE_PRECISION = 1e36;

    /** Public immutable variables **/

    IERC20 public immutable override token0;
    IERC20 public immutable override token1;
    ILBFactory public immutable override factory;
    /// @notice The `log2(1 + α binStep)` value as a signed 39.36-decimal fixed-point number
    int256 public immutable override log2Value;

    /** Private constant variables **/

    uint256 private constant BASIS_POINT_MAX = 10_000;

    /** Private variables **/

    PairInformation private _pairInformation;
    FeeHelper.FeeParameters private _feeParameters;
    /// @dev the reserves of tokens for every bin. This is the amount
    /// of token1 if `id < _pairInformation.id`; of token0 if `id > _pairInformation.id`
    /// and a mix of both if `id == _pairInformation.id`
    mapping(uint256 => Bin) private _bins;
    /// @dev Tree to find bins with non zero liquidity
    mapping(uint256 => uint256)[3] private _tree;
    /// @notice mappings from account to user's unclaimed fees.
    mapping(address => UnclaimedFees) private _unclaimedFees;
    /// @notice mappings from account to id to user's accruedDebt.
    mapping(address => mapping(uint256 => Debts)) private _accruedDebts;

    /** Constructor **/

    /// @notice Initialize the parameters
    /// @dev The different parameters needs to be validated very cautiously.
    /// It is highly recommended to never deploy this contract directly, use the factory
    /// as it validates the different parameters
    /// @param _factory The address of the factory.
    /// @param _token0 The address of the token0. Can't be address 0
    /// @param _token1 The address of the token1. Can't be address 0
    /// @param _log2Value The log(1 + binStep) value
    /// @param _packedFeeParameters The fee parameters packed in a single 256 bits slot
    constructor(
        ILBFactory _factory,
        IERC20 _token0,
        IERC20 _token1,
        int256 _log2Value,
        bytes32 _packedFeeParameters
    ) LBToken("Liquidity Book Token", "LBT") {
        factory = _factory;
        token0 = _token0;
        token1 = _token1;

        _setFeesParameters(_packedFeeParameters);

        log2Value = _log2Value;
    }

    /** External View Functions **/

    /// @notice View function to get the _pairInformation information
    /// @return The _pairInformation information
    function pairInformation() external view returns (PairInformation memory) {
        return _pairInformation;
    }

    /// @notice View function to get the fee parameters
    /// @return The fee parameters
    function feeParameters()
        external
        view
        returns (FeeHelper.FeeParameters memory)
    {
        return _feeParameters;
    }

    /// @notice View function to get the bin at `id`
    /// @param _id The bin id
    /// @return price The exchange price of y per x inside this bin (multiplied by 1e36)
    /// @return reserve0 The reserve of token0 of the bin
    /// @return reserve1 The reserve of token1 of the bin
    function getBin(uint24 _id)
        external
        view
        override
        returns (
            uint256 price,
            uint112 reserve0,
            uint112 reserve1
        )
    {
        uint256 _price = BinHelper.getPriceFromId(_id, log2Value);
        return (_price, _bins[_id].reserve0, _bins[_id].reserve1);
    }

    /// @notice View function to get the pending fees of a user
    /// @param _account The address of the user
    /// @param _ids The list of ids
    /// @return The unclaimed fees
    function pendingFees(address _account, uint256[] memory _ids)
        external
        view
        override
        returns (UnclaimedFees memory)
    {
        uint256 _len = _ids.length;
        UnclaimedFees memory _fees = _unclaimedFees[_account];

        uint256 _lastId;
        for (uint256 i; i < _len; ++i) {
            uint256 _id = _ids[i];
            uint256 _balance = balanceOf(_account, _id);

            if (_lastId >= _id && i != 0)
                revert LBPair__OnlyStrictlyIncreasingId();

            if (_balance != 0) {
                Bin memory _bin = _bins[_id];

                _collect(_fees, _bin, _account, _id, _balance);
            }

            _lastId = _id;
        }

        return _fees;
    }

    /** External Functions **/

    /// @notice Performs a low level swap, this needs to be called from a contract which performs important safety checks
    /// @param _amount0Out The amount of token0
    /// @param _amount1Out The amount of token1
    /// @param _to The address of the recipient
    function swap(
        uint256 _amount0Out,
        uint256 _amount1Out,
        address _to
    ) external override nonReentrant {
        PairInformation memory _pair = _pairInformation;

        uint256 _amount0In;
        uint256 _amount1In;

        (_amount0In, _amount0Out, _amount1In, _amount1Out) = _getAmounts(
            _pair,
            _to,
            _amount0Out,
            _amount1Out
        );

        if (_amount0In == 0 && _amount1In == 0)
            revert LBPair__InsufficientAmounts();

        if (_amount0Out != 0 && _amount1Out != 0)
            revert LBPair__WrongAmounts(_amount0Out, _amount1Out); // If this is wrong, then we're sure the amounts sent are wrong

        FeeHelper.FeeParameters memory _fp = _feeParameters;
        _fp.updateAccumulatorValue();
        uint256 _startId = _pair.id;

        uint256 _amountOutOfBin;
        uint256 _amountInToBin;
        uint256 _price;
        uint256 _totalSupply;
        // Performs the actual swap, bin per bin
        // It uses the findFirstBin function to make sure the bin we're currently looking at
        // has liquidity in it.
        while (true) {
            Bin memory _bin = _bins[_pair.id];
            if (_bin.reserve0 != 0 || _bin.reserve1 != 0) {
                _price = BinHelper.getPriceFromId(_pair.id, log2Value);
                _totalSupply = totalSupply(_pair.id);
                if (_amount0Out != 0) {
                    (_amountOutOfBin, _amountInToBin) = _swapHelper(
                        _amount0Out,
                        _bin.reserve0,
                        _price,
                        PRICE_PRECISION
                    );

                    FeeHelper.FeesDistribution memory _fees = _fp
                        .getFeesDistribution(
                            _amountInToBin,
                            _startId - _pair.id
                        );

                    _pair.fees1.total += _fees.total;
                    _pair.fees1.protocol += _fees.protocol;

                    _bin.accToken1PerShare +=
                        ((_fees.total - _fees.protocol) * PRICE_PRECISION) /
                        _totalSupply;

                    _amount1In -= _amountInToBin + _fees.total;
                    _bin.reserve1 = (_bin.reserve1 + _amountInToBin).safe112();

                    unchecked {
                        _amount0Out -= _amountOutOfBin;
                        _bin.reserve0 -= uint112(_amountOutOfBin);

                        _pair.reserve0 -= uint136(_amountOutOfBin);
                        _pair.reserve1 += uint136(_amountInToBin);
                    }
                } else {
                    (_amountOutOfBin, _amountInToBin) = _swapHelper(
                        _amount1Out,
                        _bin.reserve1,
                        PRICE_PRECISION,
                        _price
                    );

                    FeeHelper.FeesDistribution memory _fees = _fp
                        .getFeesDistribution(
                            _amountInToBin,
                            _startId - _pair.id
                        );

                    _pair.fees0.total += _fees.total;
                    _pair.fees0.protocol += _fees.protocol;

                    _bin.accToken0PerShare +=
                        ((_fees.total - _fees.protocol) * PRICE_PRECISION) /
                        _totalSupply;

                    _amount0In -= _amountInToBin + _fees.total;
                    _bin.reserve0 = (_bin.reserve0 + _amountInToBin).safe112();

                    unchecked {
                        _amount1Out -= _amountOutOfBin;
                        _bin.reserve1 -= uint112(_amountOutOfBin);

                        _pair.reserve0 += uint136(_amountInToBin);
                        _pair.reserve1 -= uint136(_amountOutOfBin);
                    }
                }
                _bins[_pair.id] = _bin;
            }

            if (_amount0Out != 0 || _amount1Out != 0) {
                _pair.id = uint24(
                    _tree.findFirstBin(_pair.id, _amount0Out == 0)
                );
            } else {
                break;
            }
        }

        _pairInformation = _pair;
        unchecked {
            _feeParameters.updateStoredFeeParameters(
                _fp.accumulator,
                _startId > _pair.id ? _startId - _pair.id : _pair.id - _startId
            );
        }
        if (_amount0Out != 0 || _amount1Out != 0)
            revert LBPair__BrokenSwapSafetyCheck(); // Safety check
        emit Swap(msg.sender, _to, _pair.id, _amount0Out, _amount1Out);
    }

    /// @notice Performs a flash loan
    /// @param _to the address that will execute the external call
    /// @param _amount0Out The amount of token0
    /// @param _amount1Out The amount of token1
    /// @param _data The bytes data that will be forwarded to _to
    function flashLoan(
        address _to,
        uint256 _amount0Out,
        uint256 _amount1Out,
        bytes memory _data
    ) external override nonReentrant {
        FeeHelper.FeeParameters memory _fp = _feeParameters;
        uint256 _reserve0 = _pairInformation.reserve0;
        uint256 _reserve1 = _pairInformation.reserve1;

        _fp.updateAccumulatorValue();

        FeeHelper.FeesDistribution memory _fees0 = _fp.getFeesDistribution(
            _amount0Out,
            0
        );
        FeeHelper.FeesDistribution memory _fees1 = _fp.getFeesDistribution(
            _amount1Out,
            0
        );

        _transferHelper(token0, _to, _amount0Out);
        _transferHelper(token1, _to, _amount1Out);

        ILBFlashLoanCallback(_to).LBFlashLoanCallback(
            msg.sender,
            _fees0.total,
            _fees1.total,
            _data
        );

        _flashLoanHelper(_pairInformation.fees0, _fees0, token0, _reserve0);
        _flashLoanHelper(_pairInformation.fees1, _fees1, token1, _reserve1);

        unchecked {
            uint256 _id = _pairInformation.id;
            uint256 _totalSupply = totalSupply(_id);
            _bins[_id].accToken0PerShare +=
                ((_fees0.total - _fees0.protocol) * PRICE_PRECISION) /
                _totalSupply;

            _bins[_id].accToken1PerShare +=
                ((_fees1.total - _fees1.protocol) * PRICE_PRECISION) /
                _totalSupply;
        }

        emit FlashLoan(
            msg.sender,
            _to,
            _amount0Out,
            _amount1Out,
            _fees0.total,
            _fees1.total
        );
    }

    /// @notice Performs a low level add, this needs to be called from a contract which performs important safety checks.
    /// The first LP provider sets the current id with the first index of its ids
    /// @param _ids The list of ids to add liquidity
    /// @param _liquidities The amounts of L you want to add
    /// @param _to The address of the recipient
    function mint(
        uint256[] memory _ids,
        uint256[] memory _liquidities,
        address _to
    ) external override nonReentrant {
        uint256 _len = _ids.length;
        if (_len == 0 || _len != _liquidities.length)
            revert LBPair__WrongLengths();

        PairInformation memory _pair = _pairInformation;
        if (_pair.reserve0 == 0 && _pair.reserve1 == 0) {
            _pair.id = uint24(_ids[0]);
        }

        uint256 _amount0In = _balanceHelper(token0, address(this)) -
            (_pair.reserve0 + _pair.fees0.total);
        uint256 _amount1In = _balanceHelper(token1, address(this)) -
            (_pair.reserve1 + _pair.fees1.total);

        uint256 _amount0;
        uint256 _amount1;

        unchecked {
            for (uint256 i; i < _len; ++i) {
                uint256 _id = _ids[i];
                uint256 _liquidity = _liquidities[i];
                if (_id > type(uint24).max) revert LBPair__IdOverflows(_id);

                if (_liquidity != 0) {
                    Bin memory _bin = _bins[_id];
                    uint256 _totalSupply = totalSupply(_id);
                    if (_totalSupply != 0) {
                        _amount0 = _liquidity.mulDivRoundUp(
                            _bin.reserve0,
                            _totalSupply
                        );
                        _amount1 = _liquidity.mulDivRoundUp(
                            _bin.reserve1,
                            _totalSupply
                        );
                    } else {
                        uint256 _price = BinHelper.getPriceFromId(
                            uint24(_id),
                            log2Value
                        );

                        if (_id < _pair.id) {
                            _amount1 = _liquidity.safe128();
                        } else if (_id > _pair.id) {
                            _amount0 = _liquidity.mulDivRoundUp(
                                PRICE_PRECISION,
                                _price
                            );
                        } else if (_id == _pair.id) {
                            _amount0 = (_liquidity - _liquidity / 2)
                                .mulDivRoundUp(PRICE_PRECISION, _price);
                            _amount1 = (_liquidity / 2).safe128();
                        }

                        // add 1 at the right indices if the _pairInformation was empty
                        uint256 _idDepth2 = _id / 256;
                        uint256 _idDepth1 = _id / 65_536;

                        _tree[2][_idDepth2] |= 1 << (_id % 256);
                        _tree[1][_idDepth1] |= 1 << (_idDepth2 % 256);
                        _tree[0][0] |= 1 << _idDepth1;
                    }

                    if (_amount0 == 0 && _amount1 == 0)
                        revert LBPair__BrokenMintSafetyCheck(_id);

                    if (_amount0 != 0) {
                        if (_amount0In < _amount0)
                            revert LBPair__MintExceedsAmountsIn(_id);
                        if (_amount0 > type(uint112).max)
                            revert LBPair__BinReserveOverflows(_id);
                        _amount0In -= _amount0;
                        _bin.reserve0 = (_bin.reserve0 + _amount0).safe112();
                        _pair.reserve0 += uint136(_amount0);
                    }

                    if (_amount1 != 0) {
                        if (_amount1In < _amount1)
                            revert LBPair__MintExceedsAmountsIn(_id);
                        if (_amount1 > type(uint112).max)
                            revert LBPair__BinReserveOverflows(_id);
                        _amount1In -= _amount1;
                        _bin.reserve1 = (_bin.reserve1 + _amount1).safe112();
                        _pair.reserve1 += uint136(_amount1);
                    }

                    _bins[_id] = _bin;
                    _mint(_to, _id, _liquidity);
                }
            }
        }

        _pairInformation = _pair;
        emit Mint(msg.sender, _to, _ids, _liquidities);
    }

    /// @notice Performs a low level remove, this needs to be called from a contract which performs important safety checks
    /// @param _ids The ids the user want to remove its liquidity
    /// @param _amounts The amount of token to burn
    /// @param _to The address of the recipient
    function burn(
        uint256[] memory _ids,
        uint256[] memory _amounts,
        address _to
    ) external override nonReentrant {
        uint256 _len = _ids.length;

        PairInformation memory _pair = _pairInformation;

        uint256 _amounts0;
        uint256 _amounts1;

        unchecked {
            for (uint256 i; i < _len; ++i) {
                uint256 _id = _ids[i];
                uint256 _amountToBurn = _amounts[i];
                if (_id > type(uint24).max) revert LBPair__IdOverflows(_id);

                if (_amountToBurn == 0)
                    revert LBPair__InsufficientLiquidityBurned(_id);

                Bin memory _bin = _bins[_id];

                uint256 totalSupply = totalSupply(_id);

                if (_id <= _pair.id) {
                    uint256 _amount1 = _amountToBurn.mulDivRoundDown(
                        _bin.reserve1,
                        totalSupply
                    );

                    if (_bin.reserve1 < _amount1)
                        revert LBPair__BurnExceedsReserve(_id);

                    _amounts1 += _amount1;
                    _bin.reserve1 -= uint112(_amount1);
                    _pair.reserve1 -= uint136(_amount1);
                }
                if (_id >= _pair.id) {
                    uint256 _amount0 = _amountToBurn.mulDivRoundDown(
                        _bin.reserve0,
                        totalSupply
                    );

                    if (_bin.reserve0 < _amount0)
                        revert LBPair__BurnExceedsReserve(_id);

                    _amounts0 += _amount0;
                    _bin.reserve0 -= uint112(_amount0);
                    _pair.reserve0 -= uint136(_amount0);
                }

                if (_bin.reserve0 == 0 && _bin.reserve1 == 0) {
                    // removes 1 at the right indices
                    uint256 _idDepth2 = _id / 256;
                    _tree[2][_idDepth2] -= 1 << (_id % 256);
                    if (_tree[2][_idDepth2] == 0) {
                        uint256 _idDepth1 = _id / 65_536;
                        _tree[1][_idDepth1] -= 1 << (_idDepth2 % 256);
                        if (_tree[1][_idDepth1] == 0) {
                            _tree[0][0] -= 1 << _idDepth1;
                        }
                    }
                }

                _bins[_id] = _bin;
                _burn(address(this), _id, _amountToBurn);
            }
        }

        _pairInformation = _pair;

        _transferHelper(token0, _to, _amounts0);
        _transferHelper(token1, _to, _amounts1);

        emit Burn(msg.sender, _to, _ids, _amounts);
    }

    /// @notice Collect fees of an user
    /// @param _account The address of the user
    /// @param _ids The list of bin ids to collect fees in
    function collectFees(address _account, uint256[] memory _ids)
        external
        nonReentrant
    {
        uint256 _len = _ids.length;

        UnclaimedFees memory _fees = _unclaimedFees[_account];
        delete _unclaimedFees[_account];

        for (uint256 i; i < _len; ++i) {
            uint256 _id = _ids[i];
            uint256 _balance = balanceOf(_account, _id);

            if (_balance != 0) {
                Bin memory _bin = _bins[_id];

                _collect(_fees, _bin, _account, _id, _balance);
                _update(_bin, _account, _id, _balance);
            }
        }

        if (_fees.token0 != 0) {
            _pairInformation.fees0.total -= _fees.token0;
        }
        if (_fees.token1 != 0) {
            _pairInformation.fees1.total -= _fees.token1;
        }

        _transferHelper(token0, _account, _fees.token0);
        _transferHelper(token1, _account, _fees.token1);

        emit FeesCollected(msg.sender, _account, _fees.token0, _fees.token1);
    }

    /// @notice Distribute the protocol fees to the feeRecipient
    /// @dev The balances are not zeroed to save gas by not resetting the memory slot
    function distributeProtocolFees() external nonReentrant {
        FeeHelper.FeesDistribution memory _fees0 = _pairInformation.fees0;
        FeeHelper.FeesDistribution memory _fees1 = _pairInformation.fees1;

        address _feeRecipient = factory.feeRecipient();
        uint256 _fees0Out;
        uint256 _fees1Out;

        if (_fees0.protocol != 0) {
            unchecked {
                _fees0Out = _fees0.protocol - 1;
                _fees0.total -= uint128(_fees0Out);
                _fees0.protocol = 1;
                _pairInformation.fees0 = _fees0;
            }
        }
        if (_fees1.protocol != 0) {
            unchecked {
                _fees1Out = _fees1.protocol - 1;
                _fees1.total -= uint128(_fees1Out);
                _fees1.protocol = 1;
                _pairInformation.fees1 = _fees1;
            }
        }

        _transferHelper(token0, _feeRecipient, _fees0Out);
        _transferHelper(token1, _feeRecipient, _fees1Out);

        emit ProtocolFeesCollected(
            msg.sender,
            _feeRecipient,
            _fees0Out,
            _fees1Out
        );
    }

    function setFeesParameters(bytes32 _packedFeeParameters)
        external
        override
        OnlyFactory
    {
        _setFeesParameters(_packedFeeParameters);
    }

    /** Public Functions **/

    function supportsInterface(bytes4 _interfaceId)
        public
        view
        override(LBToken, IERC165)
        returns (bool)
    {
        return
            _interfaceId == type(ILBPair).interfaceId ||
            super.supportsInterface(_interfaceId);
    }

    /** Internal Functions **/

    /// @notice Collect and update fees before any token transfer, mint or burn
    /// @param _from The address of the owner of the token
    /// @param _to The address of the recipient of the  token
    /// @param _id The id of the token
    /// @param _amount The amount of token of type `id`
    function _beforeTokenTransfer(
        address _from,
        address _to,
        uint256 _id,
        uint256 _amount
    ) internal override(LBToken) {
        super._beforeTokenTransfer(_from, _to, _id, _amount);

        UnclaimedFees memory _feesFrom = _unclaimedFees[_from];
        UnclaimedFees memory _feesTo = _unclaimedFees[_to];

        Bin memory _bin = _bins[_id];

        if (_from != address(0) && _from != address(this)) {
            uint256 _balanceFrom = balanceOf(_from, _id);

            _collect(_feesFrom, _bin, _from, _id, _balanceFrom);
            _update(_bin, _from, _id, _balanceFrom - _amount);

            _unclaimedFees[_from] = _feesFrom;
        }

        if (_to != address(0) && _to != address(this) && _from != _to) {
            uint256 _balanceTo = balanceOf(_to, _id);

            _collect(_feesTo, _bin, _to, _id, _balanceTo);
            _update(_bin, _to, _id, _balanceTo + _amount);

            _unclaimedFees[_to] = _feesTo;
        }
    }

    /** Private Functions **/

    /// @notice Collect fees of a given bin
    /// @param _fees The user's unclaimed fees
    /// @param _bin  The bin where the user is collecting fees
    /// @param _account The address of the user
    /// @param _id The id where the user is collecting fees
    /// @param _balance The previous balance of the user
    function _collect(
        UnclaimedFees memory _fees,
        Bin memory _bin,
        address _account,
        uint256 _id,
        uint256 _balance
    ) private view {
        Debts memory _debts = _accruedDebts[_account][_id];

        _fees.token0 += (_bin.accToken0PerShare.mulDivRoundDown(
            _balance,
            PRICE_PRECISION
        ) - _debts.debt0).safe128();

        _fees.token1 += (_bin.accToken1PerShare.mulDivRoundDown(
            _balance,
            PRICE_PRECISION
        ) - _debts.debt1).safe128();
    }

    /// @notice Update fees of a given user
    /// @param _bin The bin where the user has collected fees
    /// @param _account The address of the user
    /// @param _id The id where the user has collected fees
    /// @param _balance The new balance of the user
    function _update(
        Bin memory _bin,
        address _account,
        uint256 _id,
        uint256 _balance
    ) private {
        uint256 _debt0 = _bin.accToken0PerShare.mulDivRoundDown(
            _balance,
            PRICE_PRECISION
        );
        uint256 _debt1 = _bin.accToken1PerShare.mulDivRoundDown(
            _balance,
            PRICE_PRECISION
        );

        _accruedDebts[_account][_id] = Debts(_debt0, _debt1);
    }

    /// @notice Returns the amounts that needs to be swapped
    /// @param _pair The current pair information
    /// @param _to The address of the user
    /// @param _amount0Out The amount of token0 to send to the user
    /// @param _amount1Out The amount of token1 to send to the user
    /// @return The amount of token0 sent by users to the pair contract
    /// @return The amount of token0 sent to the user by the pair contract
    /// @return The amount of token1 sent by users to the pair contract
    /// @return The amount of token1 sent to the user by the pair contract
    function _getAmounts(
        PairInformation memory _pair,
        address _to,
        uint256 _amount0Out,
        uint256 _amount1Out
    )
        private
        returns (
            uint256,
            uint256,
            uint256,
            uint256
        )
    {
        uint256 _amount0In = _balanceHelper(token0, address(this)) -
            (_pair.reserve0 + _pair.fees0.total);
        uint256 _amount1In = _balanceHelper(token1, address(this)) -
            (_pair.reserve1 + _pair.fees1.total);

        _transferHelper(token0, _to, _amount0Out);
        _transferHelper(token1, _to, _amount1Out);

        if (_amount0Out != 0 && _amount0Out > _amount0In) {
            _amount0Out -= _amount0In;
        } else {
            _amount0Out = 0;
        }
        if (_amount1Out != 0 && _amount1Out > _amount1In) {
            _amount1Out -= _amount1In;
        } else {
            _amount1Out = 0;
        }
        return (_amount0In, _amount0Out, _amount1In, _amount1Out);
    }

    /// @notice Returns the swap amounts in the current bin
    /// @param _amountOut The amount sent to the user
    /// @param _reserve The reserve of the current bin
    /// @param _numerator The first param of mulDiv
    /// @param _denominator The denominator of the mulDiv
    /// @return _amountOutOfBin The amount taken from the bin reserve
    /// @return  _amountInToBin The amount added to the bin reserve
    function _swapHelper(
        uint256 _amountOut,
        uint256 _reserve,
        uint256 _numerator,
        uint256 _denominator
    ) private pure returns (uint256 _amountOutOfBin, uint256 _amountInToBin) {
        _amountOutOfBin = _amountOut > _reserve ? _reserve : _amountOut;
        _amountInToBin = _numerator.mulDivRoundUp(
            _amountOutOfBin,
            _denominator
        );
    }

    /// @notice Transfers token only if the amount is greater than zero
    /// @param _token The address of the token
    /// @param _recipient The address of the recipient
    /// @param _amount The amount to send
    function _transferHelper(
        IERC20 _token,
        address _recipient,
        uint256 _amount
    ) private {
        if (_amount != 0) {
            _token.safeTransfer(_recipient, _amount);
        }
    }

    /// @notice Returns the balance of an account
    /// @param _token The address of the token
    /// @param _account The address of the account
    /// @return The balance of the account
    function _balanceHelper(IERC20 _token, address _account)
        private
        view
        returns (uint256)
    {
        return _token.balanceOf(_account);
    }

    /// @notice Checks that the flash loan was done accordingly
    /// @param _pairFees The fees of the pair
    /// @param _fees The fees received by the pair
    /// @param _token The address of the token received
    /// @param _reserve The stored reserve of the current bin
    function _flashLoanHelper(
        FeeHelper.FeesDistribution storage _pairFees,
        FeeHelper.FeesDistribution memory _fees,
        IERC20 _token,
        uint256 _reserve
    ) private {
        uint256 _balanceAfter = _balanceHelper(_token, address(this));

        if (_reserve + _fees.total > _balanceAfter)
            revert LBPair__FlashLoanUnderflow(
                _reserve + _fees.total,
                _balanceAfter
            );
        else {
            _pairFees.total += _fees.total;
            _pairFees.protocol += _fees.protocol;
        }
    }

    /// @notice Internal function to set the fee parameters of the pair
    /// @param _packedFeeParameters The packed fee parameters
    function _setFeesParameters(bytes32 _packedFeeParameters) internal {
        assembly {
            sstore(add(_feeParameters.slot, 1), _packedFeeParameters)
        }
        emit FeesParametersSet(_packedFeeParameters);
    }
}