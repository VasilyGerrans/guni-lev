// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.6;

interface IERC20 {
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address recipient, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(
        address sender,
        address recipient,
        uint256 amount
    ) external returns (bool);
}

interface UniPoolLike {
    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool);
    function swap(address, bool, int256, uint160, bytes calldata) external;
    function positions(bytes32) external view returns (uint128, uint256, uint256, uint128, uint128);
}

interface GUNITokenLike is IERC20 {
    function mint(uint256 mintAmount, address receiver) external returns (
        uint256 amount0,
        uint256 amount1,
        uint128 liquidityMinted
    );
    function burn(uint256 burnAmount, address receiver) external returns (
        uint256 amount0,
        uint256 amount1,
        uint128 liquidityBurned
    );
    function getMintAmounts(uint256 amount0Max, uint256 amount1Max) external view returns (uint256 amount0, uint256 amount1, uint256 mintAmount);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function pool() external view returns (address);
    function getUnderlyingBalances() external view returns (uint256, uint256);
}

interface CurveSwapLike {
    function exchange(int128 i, int128 j, uint256 dx, uint256 min_dy) external;
    function get_dy(int128 i, int128 j, uint256 dx) external view returns (uint256);
    function coins(uint256) external view returns (address);
}

interface GUNIRouterLike {
    function addLiquidity(
        address _pool,
        uint256 _amount0Max,
        uint256 _amount1Max,
        uint256 _amount0Min,
        uint256 _amount1Min,
        address _receiver
    )
    external
    returns (
        uint256 amount0,
        uint256 amount1,
        uint256 mintAmount
    );
    function removeLiquidity(
        address _pool,
        uint256 _burnAmount,
        uint256 _amount0Min,
        uint256 _amount1Min,
        address _receiver
    )
    external
    returns (
        uint256 amount0,
        uint256 amount1,
        uint256 liquidityBurned
    );
}

interface GUNIResolverLike {
    function getRebalanceParams(
        address pool,
        uint256 amount0In,
        uint256 amount1In,
        uint256 price18Decimals
    ) external view returns (bool zeroForOne, uint256 swapAmount);
}

interface IERC3156FlashBorrower {
    function onFlashLoan(
        address initiator,
        address token,
        uint256 amount,
        uint256 fee,
        bytes calldata data
    ) external returns (bytes32);
}

interface IERC3156FlashLender {
    function maxFlashLoan(
        address token
    ) external view returns (uint256);
    function flashFee(
        address token,
        uint256 amount
    ) external view returns (uint256);
    function flashLoan(
        IERC3156FlashBorrower receiver,
        address token,
        uint256 amount,
        bytes calldata data
    ) external returns (bool);
}

interface GemJoinLike {
    function vat() external view returns (address);
    function ilk() external view returns (bytes32);
    function gem() external view returns (address);
    function dec() external view returns (uint256);
    function join(address, uint256) external;
    function exit(address, uint256) external;
}

interface DaiJoinLike {
    function vat() external view returns (address);
    function dai() external view returns (address);
    function join(address, uint256) external;
    function exit(address, uint256) external;
}

interface VatLike {
    function ilks(bytes32) external view returns (
        uint256 Art,  // [wad]
        uint256 rate, // [ray]
        uint256 spot, // [ray]
        uint256 line, // [rad]
        uint256 dust  // [rad]
    );
    function urns(bytes32, address) external view returns (uint256, uint256);
    function hope(address usr) external;
    function frob (bytes32 i, address u, address v, address w, int dink, int dart) external;
    function dai(address) external view returns (uint256);
}

interface SpotLike {
    function ilks(bytes32) external view returns (address pip, uint256 mat);
}

contract GuniLev is IERC3156FlashBorrower {

    uint256 constant RAY = 10 ** 27;

    enum Action {WIND, UNWIND}

    bytes32 public ilk;
    VatLike public immutable vat;
    DaiJoinLike public immutable daiJoin;
    SpotLike public immutable spotter;
    IERC20 public immutable dai;
    IERC3156FlashLender public immutable lender;
    GUNIRouterLike public immutable router;
    GUNIResolverLike public immutable resolver;

    constructor(
        GemJoinLike _join,
        DaiJoinLike _daiJoin,
        SpotLike _spotter,
        IERC3156FlashLender _lender,
        CurveSwapLike _curve,
        GUNIRouterLike _router,
        GUNIResolverLike _resolver, 
        int128 _curveIndexDai,
        int128 _curveIndexOtherToken
    ) {
        require(_curve.coins(smallIntToUint(_curveIndexDai)) == address(_daiJoin.dai()), "GuniLev/constructor/incorrect-curve-info-dai");
        
        GUNITokenLike guni = GUNITokenLike(_join.gem());
        IERC20 otherToken = guni.token0() != address(_daiJoin.dai()) ? IERC20(guni.token0()) : IERC20(guni.token1());
        require(_curve.coins(smallIntToUint(_curveIndexOtherToken)) == address(otherToken), "GuniLev/constructor/incorrect-curve-info-otherToken");
        
        ilk = _join.ilk();
        vat = VatLike(_join.vat());
        daiJoin = _daiJoin;
        spotter = _spotter;
        dai = IERC20(_daiJoin.dai());
        lender = _lender;
        router = _router;
        resolver = _resolver;

        poolWinderExists[ilk] = true;
        poolWinders[ilk] = PoolWinder(
            _join, 
            otherToken, 
            _curve, 
            _curveIndexDai, 
            _curveIndexOtherToken, 
            10 ** (18 - otherToken.decimals()),
            guni
        );

        VatLike(_join.vat()).hope(address(_daiJoin)); 
    }

    /// @notice Stores all data necessary to carry out a wind for a given LP.
    struct PoolWinder { 
        GemJoinLike join;
        IERC20 otherToken;
        CurveSwapLike curve;
        int128 curveIndexDai;
        int128 curveIndexOtherToken;
        uint256 otherTokenTo18Conversion;
        GUNITokenLike guni;
    }

    mapping(bytes32 => bool) private poolWinderExists;
    mapping(bytes32 => PoolWinder) private poolWinders;

    function setIlk(bytes32 _ilk) external {
        require(poolWinderExists[_ilk] == true, "GuniLev/setIlk/ilk-pool-does-not-exist");
        ilk = _ilk;
    }

    /// @notice Creates new or overwrites existing PoolWinder.
    function setPool(GemJoinLike join, CurveSwapLike curve, int128 curveIndexDai, int128 curveIndexOtherToken) 
    public returns (bool success) {
        require(curve.coins(smallIntToUint(curveIndexDai)) == address(dai), "GuniLev/setPool/incorrect-curve-info-dai");
        
        GUNITokenLike guni = GUNITokenLike(join.gem());
        IERC20 otherToken = guni.token0() != address(dai) ? IERC20(guni.token0()) : IERC20(guni.token1());
        require(curve.coins(smallIntToUint(curveIndexOtherToken)) == address(otherToken), "GuniLev/setPool/incorrect-curve-info-otherToken");
        
        bytes32 newIlk = join.ilk();
        poolWinderExists[newIlk] = true;
        poolWinders[newIlk] = PoolWinder(
            join, 
            otherToken, 
            curve, 
            curveIndexDai, 
            curveIndexOtherToken, 
            10 ** (18 - otherToken.decimals()),
            guni
        );

        return true;
    }    

    /// @notice Makes existing pool inaccessible.
    function deletePool(bytes32 _ilk) external returns(bool success) {
        require(poolWinderExists[_ilk] == true, "GuniLev/deletePool/pool-does-not-exist");
        poolWinderExists[_ilk] = false;
        return true;
    }

    function getWindEstimates(address usr, uint256 principal) public view returns (uint256 estimatedDaiRemaining, uint256 estimatedGuniAmount, uint256 estimatedDebt) {
        uint256 leveragedAmount;
        {
            (,uint256 mat) = spotter.ilks(ilk);
            leveragedAmount = principal*RAY/(mat - RAY);
        }

        uint256 swapAmount;
        {
            GUNITokenLike guni = poolWinders[ilk].guni;
            uint256 otherTokenTo18Conversion = poolWinders[ilk].otherTokenTo18Conversion;
            (uint256 sqrtPriceX96,,,,,,) = UniPoolLike(guni.pool()).slot0();
            (, swapAmount) = resolver.getRebalanceParams(
                address(guni),
                guni.token0() == address(dai) ? leveragedAmount : 0,
                guni.token1() == address(dai) ? leveragedAmount : 0,
                ((((sqrtPriceX96*sqrtPriceX96) >> 96) * 1e18) >> 96) * otherTokenTo18Conversion
            );
        }

        (estimatedGuniAmount, estimatedDebt) = getGuniAmountAndDebt(usr, leveragedAmount, swapAmount);

        uint256 daiBalance = dai.balanceOf(usr);

        require(leveragedAmount <= estimatedDebt + daiBalance, "not-enough-dai");

        estimatedDaiRemaining = estimatedDebt + daiBalance - leveragedAmount;
    }

    function getGuniAmountAndDebt(address usr, uint256 leveragedAmount, uint256 swapAmount) internal view returns (uint256 estimatedGuniAmount, uint256 estimatedDebt) {
        GUNITokenLike guni = poolWinders[ilk].guni;
        CurveSwapLike curve = poolWinders[ilk].curve;
        int128 curveIndexDai = poolWinders[ilk].curveIndexDai;
        int128 curveIndexOtherToken = poolWinders[ilk].curveIndexOtherToken;

        {
            (,, estimatedGuniAmount) = guni.getMintAmounts(
                guni.token0() == address(dai) ? leveragedAmount - swapAmount : curve.get_dy(curveIndexDai, curveIndexOtherToken, swapAmount), 
                guni.token1() == address(dai) ? leveragedAmount - swapAmount : curve.get_dy(curveIndexDai, curveIndexOtherToken, swapAmount));
            (,uint256 rate, uint256 spot,,) = vat.ilks(ilk);
            (uint256 ink, uint256 art) = vat.urns(ilk, usr);
            estimatedDebt = ((estimatedGuniAmount + ink) * spot / rate - art) * rate / RAY;
        }
    }

    function getUnwindEstimates(uint256 ink, uint256 art) public view returns (uint256 estimatedDaiRemaining) {
        GUNITokenLike guni = poolWinders[ilk].guni;
        CurveSwapLike curve = poolWinders[ilk].curve;
        int128 curveIndexOtherToken = poolWinders[ilk].curveIndexOtherToken;
        int128 curveIndexDai = poolWinders[ilk].curveIndexDai;

        (,uint256 rate,,,) = vat.ilks(ilk);
        (uint256 bal0, uint256 bal1) = guni.getUnderlyingBalances();
        uint256 totalSupply = guni.totalSupply();
        bal0 = bal0 * ink / totalSupply;
        bal1 = bal1 * ink / totalSupply;
        uint256 dy = curve.get_dy(curveIndexOtherToken, curveIndexDai, guni.token0() == address(dai) ? bal1 : bal0);

        return (guni.token0() == address(dai) ? bal0 : bal1) + dy - art * rate / RAY;
    }

    function getUnwindEstimates(address usr) external view returns (uint256 estimatedDaiRemaining) {
        (uint256 ink, uint256 art) = vat.urns(ilk, usr);
        return getUnwindEstimates(ink, art);
    }

    function getLeverageBPS() external view returns (uint256) {
        (,uint256 mat) = spotter.ilks(ilk);
        return 10000 * RAY/(mat - RAY);
    }

    /// @notice A hack workaround for converting int128 to uint256. This issue is introduced
    /// by curve.exchange and curve.coins functions that accept int128 and uint256 respectively.
    /// This shouldn't introduce major gas costs so long as the Curve pool has few coins
    /// in the pool (which it typically does). It should also never throw an error, as curve
    /// coin indexes are always positive.
    function smallIntToUint(int128 valInitial) internal pure returns (uint256) {
        require(valInitial >= 0, "GuniLev/smallIntToUint/unexpected-int128-value");
        uint256 valFinal;
        for (int128 index = 0; index < valInitial; index++) {
            valFinal++;
        }
        return valFinal;
    }

    function getEstimatedCostToWindUnwind(address usr, uint256 principal) external view returns (uint256) {
        (, uint256 estimatedGuniAmount, uint256 estimatedDebt) = getWindEstimates(usr, principal);
        (,uint256 rate,,,) = vat.ilks(ilk);
        return dai.balanceOf(usr) - getUnwindEstimates(estimatedGuniAmount, estimatedDebt * RAY / rate);
    }

    function wind(
        uint256 principal,
        uint256 minWalletDai
    ) external {
        bytes memory data = abi.encode(Action.WIND, msg.sender, minWalletDai);
        (,uint256 mat) = spotter.ilks(ilk);
        initFlashLoan(data, principal*RAY/(mat - RAY));
    }

    function unwind(
        uint256 minWalletDai
    ) external {
        bytes memory data = abi.encode(Action.UNWIND, msg.sender, minWalletDai);
        (,uint256 rate,,,) = vat.ilks(ilk);
        (, uint256 art) = vat.urns(ilk, msg.sender);
        initFlashLoan(data, art*rate/RAY);
    }

    function initFlashLoan(bytes memory data, uint256 amount) internal {
        uint256 _allowance = dai.allowance(address(this), address(lender));
        uint256 _fee = lender.flashFee(address(dai), amount);
        uint256 _repayment = amount + _fee;
        dai.approve(address(lender), _allowance + _repayment);
        lender.flashLoan(this, address(dai), amount, data);
    }

    function onFlashLoan(
        address initiator,
        address,
        uint256 amount,
        uint256 fee,
        bytes calldata data
    ) external override returns (bytes32) {
        require(
            msg.sender == address(lender),
            "FlashBorrower: Untrusted lender"
        );
        require(
            initiator == address(this),
            "FlashBorrower: Untrusted loan initiator"
        );
        (Action action, address usr, uint256 minWalletDai) = abi.decode(data, (Action, address, uint256));
        if (action == Action.WIND) {
            _wind(usr, amount + fee, minWalletDai);
        } else if (action == Action.UNWIND) {
            _unwind(usr, amount, fee, minWalletDai);
        }
        return keccak256("ERC3156FlashBorrower.onFlashLoan");
    }

    function _wind(address usr, uint256 totalOwed, uint256 minWalletDai) internal {
        CurveSwapLike curve = poolWinders[ilk].curve;
        int128 curveIndexDai = poolWinders[ilk].curveIndexDai;
        int128 curveIndexOtherToken = poolWinders[ilk].curveIndexOtherToken;
        IERC20 otherToken = poolWinders[ilk].otherToken;

        // Calculate how much DAI we should be swapping for otherToken
        uint256 swapAmount;
        {
            GUNITokenLike guni = poolWinders[ilk].guni;
            uint256 otherTokenTo18Conversion = poolWinders[ilk].otherTokenTo18Conversion;
            (uint256 sqrtPriceX96,,,,,,) = UniPoolLike(guni.pool()).slot0();
            (, swapAmount) = resolver.getRebalanceParams(
                address(guni),
                IERC20(guni.token0()).balanceOf(address(this)),
                IERC20(guni.token1()).balanceOf(address(this)),
                ((((sqrtPriceX96*sqrtPriceX96) >> 96) * 1e18) >> 96) * otherTokenTo18Conversion
            );
        }

        // Swap DAI for otherToken on Curve
        dai.approve(address(curve), swapAmount);
        curve.exchange(curveIndexDai, curveIndexOtherToken, swapAmount, 0);

        _guniAndVaultLogic(usr);

        uint256 daiBalance = dai.balanceOf(address(this));
        if (daiBalance > totalOwed) {
            // Send extra dai to user
            dai.transfer(usr, daiBalance - totalOwed);
        } else if (daiBalance < totalOwed) {
            // Pull remaining dai needed from usr
            dai.transferFrom(usr, address(this), totalOwed - daiBalance);
        }

        // Send any remaining dust from other token to user as well
        otherToken.transfer(usr, otherToken.balanceOf(address(this)));

        require(dai.balanceOf(address(usr)) + otherToken.balanceOf(address(this)) >= minWalletDai, "slippage");
    }

    /// @dev Separated to escape the 'stack too deep' error
    function _guniAndVaultLogic(address usr) internal {
        GUNITokenLike guni = poolWinders[ilk].guni;
        IERC20 otherToken = poolWinders[ilk].otherToken;
        GemJoinLike join = poolWinders[ilk].join;

        // Mint G-UNI
        uint256 guniBalance;
        {
            uint256 bal0 = IERC20(guni.token0()).balanceOf(address(this));
            uint256 bal1 = IERC20(guni.token1()).balanceOf(address(this));
            dai.approve(address(router), bal0);
            otherToken.approve(address(router), bal1);
            (,, guniBalance) = router.addLiquidity(address(guni), bal0, bal1, 0, 0, address(this));
            dai.approve(address(router), 0);
            otherToken.approve(address(router), 0);
        }

        // Open / Re-enforce vault
        {
            guni.approve(address(join), guniBalance);
            join.join(address(usr), guniBalance); 
            (,uint256 rate, uint256 spot,,) = vat.ilks(ilk);
            (uint256 ink, uint256 art) = vat.urns(ilk, usr);
            uint256 dart = (guniBalance + ink) * spot / rate - art;
            vat.frob(ilk, address(usr), address(usr), address(this), int256(guniBalance), int256(dart)); 
            daiJoin.exit(address(this), vat.dai(address(this)) / RAY);
        }
    }

    function _unwind(address usr, uint256 amount, uint256 fee, uint256 minWalletDai) internal {
        CurveSwapLike curve = poolWinders[ilk].curve;
        int128 curveIndexDai = poolWinders[ilk].curveIndexDai;
        int128 curveIndexOtherToken = poolWinders[ilk].curveIndexOtherToken;
        IERC20 otherToken = poolWinders[ilk].otherToken;
        
        // Pay back all CDP debt and exit g-uni
        _payBackDebtAndExitGuni(usr, amount);

        // Trade all otherToken for dai
        uint256 swapAmount = otherToken.balanceOf(address(this));
        otherToken.approve(address(curve), swapAmount);
        curve.exchange(curveIndexOtherToken, curveIndexDai, swapAmount, 0);

        uint256 daiBalance = dai.balanceOf(address(this));
        uint256 totalOwed = amount + fee;
        if (daiBalance > totalOwed) {
            // Send extra dai to user
            dai.transfer(usr, daiBalance - totalOwed);
        } else if (daiBalance < totalOwed) {
            // Pull remaining dai needed from usr
            dai.transferFrom(usr, address(this), totalOwed - daiBalance);
        }

        // Send any remaining dust from other token to user as well
        otherToken.transfer(usr, otherToken.balanceOf(address(this)));

        require(dai.balanceOf(address(usr)) + otherToken.balanceOf(address(this)) >= minWalletDai, "slippage");
    }

    /// @dev Separated to escape the 'stack too deep' error
    function _payBackDebtAndExitGuni(address usr, uint256 amount) internal {
        GUNITokenLike guni = poolWinders[ilk].guni;
        GemJoinLike join = poolWinders[ilk].join;

        (uint256 ink, uint256 art) = vat.urns(ilk, usr);
        dai.approve(address(daiJoin), amount);
        daiJoin.join(address(this), amount);
        vat.frob(ilk, address(usr), address(this), address(this), -int256(ink), -int256(art));
        join.exit(address(this), ink);

        // Burn G-UNI
        guni.approve(address(router), ink);
        router.removeLiquidity(address(guni), ink, 0, 0, address(this));
    }
}
