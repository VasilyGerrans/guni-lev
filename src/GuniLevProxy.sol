// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.6;

import "./GuniLev.sol";
import "./Proxy.sol";
import "./Proxiable.sol";

contract GuniLevProxy is Proxiable, Proxy {
        
    VatLike public vat;
    DaiJoinLike public daiJoin;
    SpotLike public spotter;
    IERC20 public dai;
    IERC3156FlashLender public lender;
    GUNIRouterLike public router;
    GUNIResolverLike public resolver;

    bool private allowLenderCall;

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

    mapping(bytes32 => bool) public poolWinderExists;
    mapping(bytes32 => PoolWinder) public poolWinders;

    /// @notice Introduced to make sure each user is always certain
    /// what ilk he is interacting with.
    mapping(address => bytes32) internal userIlks;
    
    /// @dev Helps reduce variables per function.
    function _userIlk() internal view returns(bytes32) {
        return userIlks[msg.sender];
    }

    constructor(
        address _lev,
        GemJoinLike _join,
        DaiJoinLike _daiJoin,
        SpotLike _spotter,
        IERC3156FlashLender _lender,
        GUNIRouterLike _router,
        GUNIResolverLike _resolver,
        CurveSwapLike _curve,
        int128 _curveIndexDai,
        int128 _curveIndexOtherToken
    ) {        
        vat = VatLike(_join.vat());
        daiJoin = _daiJoin;
        spotter = _spotter;
        dai = IERC20(_daiJoin.dai());
        lender = _lender;
        router = _router;
        resolver = _resolver;

        require(setPool(_join, _curve, _curveIndexDai, _curveIndexOtherToken) == true, "GuniLevProxy/contructor/invalid-pool-data");

        setIlk(_join.ilk());
        setLevLogic(_lev);
        VatLike(_join.vat()).hope(address(_daiJoin));
    }

    function getIlk() external view returns(bytes32) {
        return _userIlk();
    }

    function setIlk(bytes32 _ilk) public returns(bool) {
        require(poolWinderExists[_ilk] == true, "GuniLevProxy/setIlk/ilk-pool-does-not-exist");
        userIlks[msg.sender] = _ilk;
        return true;
    }

    /// @notice Creates new or overwrites existing PoolWinder.
    function setPool(GemJoinLike join, CurveSwapLike curve, int128 curveIndexDai, int128 curveIndexOtherToken) 
    public returns (bool success) {
        require(curve.coins(smallIntToUint(curveIndexDai)) == address(dai), "GuniLevProxy/setPool/incorrect-curve-info-dai");
        
        GUNITokenLike guni = GUNITokenLike(join.gem());
        IERC20 otherToken = guni.token0() != address(dai) ? IERC20(guni.token0()) : IERC20(guni.token1());
        require(curve.coins(smallIntToUint(curveIndexOtherToken)) == address(otherToken), "GuniLevProxy/setPool/incorrect-curve-info-otherToken");
        
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
        require(poolWinderExists[_ilk] == true, "GuniLevProxy/deletePool/pool-does-not-exist");
        poolWinderExists[_ilk] = false;
        return true;
    }

    /// @notice A hack workaround for converting int128 to uint256. This issue is introduced
    /// by curve.exchange and curve.coins functions that accept int128 and uint256 respectively.
    /// This shouldn't introduce major gas costs so long as the Curve pool has few coins
    /// in the pool (which it typically does). It should also never throw an error, as curve
    /// coin indexes are always positive.
    function smallIntToUint(int128 valInitial) internal pure returns (uint256) {
        require(valInitial >= 0, "GuniLevProxy/smallIntToUint/unexpected-int128-value");
        uint256 valFinal;
        for (int128 index = 0; index < valInitial; index++) {
            valFinal++;
        }
        return valFinal;
    }

    function _implementation() internal view override returns (address) {
        return levLogic;
    }

    function _beforeFallback() internal view override {
        if (allowLenderCall == false || msg.sender != address(lender)) {
            require(poolWinderExists[_userIlk()] == true, "GuniLevProxy/_beforeFallback/not-lender-or-no-valid-ilk");
        }
    }
}
