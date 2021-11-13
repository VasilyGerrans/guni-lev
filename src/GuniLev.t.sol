// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.6;

import "ds-test/test.sol";

import "./GuniLev.sol";
import "./GuniLevProxy.sol";

interface Hevm {
    function warp(uint256) external;
    function store(address,bytes32,bytes32) external;
    function load(address, bytes32 slot) external returns (bytes32);
}

interface PipLike {
    function kiss(address) external;
    function read() external view returns (uint256);
}

interface AuthLike {
    function wards(address) external returns (uint256);
}

contract GuniLevTest is DSTest {

    Hevm public hevm;
    VatLike public vat;
    bytes32 public ilk;
    GemJoinLike public join;
    DaiJoinLike public daiJoin;
    PipLike public pip;
    SpotLike public spotter;
    GUNITokenLike public guni;
    IERC20 public dai;
    IERC20 public otherToken;
    IERC3156FlashLender public lender;
    CurveSwapLike public curve;
    GUNIRouterLike public router;
    GUNIResolverLike public resolver;
    GuniLev public lev;
    GuniLevProxy public proxy;
    GuniLev public wrappedProxy;

    function setUp() public {
        hevm = Hevm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

        vat = VatLike(0x35D1b3F3D7966A1DFe207aa4514C12a259A0492B);
        join = GemJoinLike(0xbFD445A97e7459b0eBb34cfbd3245750Dba4d7a4);
        daiJoin = DaiJoinLike(0x9759A6Ac90977b93B58547b4A71c78317f391A28);
        pip = PipLike(0x7F6d78CC0040c87943a0e0c140De3F77a273bd58);
        spotter = SpotLike(0x65C79fcB50Ca1594B025960e539eD7A9a6D434A3);
        guni = GUNITokenLike(join.gem());
        ilk = join.ilk();
        dai = IERC20(daiJoin.dai());
        otherToken = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);    // USDC
        lender = IERC3156FlashLender(0x1EB4CF3A948E7D72A198fe073cCb8C7a948cD853);
        curve = CurveSwapLike(0xbEbc44782C7dB0a1A60Cb6fe97d0b483032FF1C7);      // 3-pool
        router = GUNIRouterLike(0x14E6D67F824C3a7b4329d3228807f8654294e4bd);
        resolver = GUNIResolverLike(0x0317650Af6f184344D7368AC8bB0bEbA5EDB214a);

        lev = new GuniLev();
        lev.initialize();
        proxy = new GuniLevProxy(address(lev), join, daiJoin, spotter, lender, router, resolver, curve, 0, 1);
        wrappedProxy = GuniLev(address(proxy));

        // Give read access to Oracle
        giveAuthAccess(address(pip), address(this));
        pip.kiss(address(this));

        // Set the user up with some money
        giveTokens(address(dai), 50_000 * 1e18);
        vat.hope(address(lev));
        dai.approve(address(lev), type(uint256).max);
        vat.hope(address(wrappedProxy));
        dai.approve(address(wrappedProxy), type(uint256).max);
    }

    function assertEqApprox(uint256 _a, uint256 _b, uint256 _tolerance) internal {
        uint256 a = _a;
        uint256 b = _b;
        if (a < b) {
            uint256 tmp = a;
            a = b;
            b = tmp;
        }
        if (a - b > _tolerance * a / 1e4) {
            emit log_bytes32("Error: Wrong `uint' value");
            emit log_named_uint("  Expected", _b);
            emit log_named_uint("    Actual", _a);
            fail();
        }
    }

    function giveAuthAccess (address _base, address target) internal {
        AuthLike base = AuthLike(_base);

        // Edge case - ward is already set
        if (base.wards(target) == 1) return;

        for (int i = 0; i < 100; i++) {
            // Scan the storage for the ward storage slot
            bytes32 prevValue = hevm.load(
                address(base),
                keccak256(abi.encode(target, uint256(i)))
            );
            hevm.store(
                address(base),
                keccak256(abi.encode(target, uint256(i))),
                bytes32(uint256(1))
            );
            if (base.wards(target) == 1) {
                // Found it
                return;
            } else {
                // Keep going after restoring the original value
                hevm.store(
                    address(base),
                    keccak256(abi.encode(target, uint256(i))),
                    prevValue
                );
            }
        }

        // We have failed if we reach here
        assertTrue(false);
    }

    function giveTokens(address token, uint256 amount) internal {
        // Edge case - balance is already set for some reason
        if (IERC20(token).balanceOf(address(this)) == amount) return;

        for (int i = 0; i < 100; i++) {
            // Scan the storage for the balance storage slot
            bytes32 prevValue = hevm.load(
                token,
                keccak256(abi.encode(address(this), uint256(i)))
            );
            hevm.store(
                token,
                keccak256(abi.encode(address(this), uint256(i))),
                bytes32(amount)
            );
            if (IERC20(token).balanceOf(address(this)) == amount) {
                // Found it
                return;
            } else {
                // Keep going after restoring the original value
                hevm.store(
                    token,
                    keccak256(abi.encode(address(this), uint256(i))),
                    prevValue
                );
            }
        }

        // We have failed if we reach here
        assertTrue(false);
    }

    function test_proxy_estimatedCost() public {
        uint256 bal = dai.balanceOf(address(this));
        uint256 cost = wrappedProxy.getEstimatedCostToWindUnwind(address(this), bal);
        uint256 relCostBPS = uint256(cost) * 10000 / bal;

        // Expect up to 8% in losses due to slippage
        assertTrue(relCostBPS < 800); 
    }

    function test_proxy_delete_create_pool() public {
        bytes32 myIlk = wrappedProxy.userIlks(address(this));
        bool successDelete = proxy.deletePool(myIlk);

        assertTrue(successDelete);
    }

    function testFail_set_nonexistent_ilk() public {
        bytes32 nonexistentIlk = bytes32(0);
        proxy.setIlk(nonexistentIlk);
    } 
    
    function test_getUnwindEstimates() public {
        uint256 startingAmount = dai.balanceOf(address(this));

        // Need to wind up a vault first
        wrappedProxy.wind(startingAmount, 0);

        uint256 daiAfterUnwind = wrappedProxy.getUnwindEstimates(address(this));

        // Should be roughly the same as what you started with around 8% expected losses from slippage
        assertEqApprox(daiAfterUnwind, startingAmount, 800);
    }
    
    /// @notice Fails, but is very close to the correct answer,
    /// just like the original GuniLev contract. The failure depends on
    /// curve.
    function test_proxy_getWindEstimates() public {
        (uint256 expectedRemainingDai,,) = wrappedProxy.getWindEstimates(address(this), dai.balanceOf(address(this)));

        assertEqApprox(expectedRemainingDai, 2122 * 1e18, 500);
    }    

    function test_proxy_open_position() public {
        uint256 principal = dai.balanceOf(address(this));
        uint256 leveragedAmount = principal * wrappedProxy.getLeverageBPS()/10000;

        wrappedProxy.wind(dai.balanceOf(address(this)), 0);

        // Should never be leftovers
        assertEq(dai.balanceOf(address(wrappedProxy)), 0);
        assertEq(otherToken.balanceOf(address(lev)), 0);
        assertEq(guni.balanceOf(address(wrappedProxy)), 0);

        // Should never be leftover approvals
        assertEq(dai.allowance(address(wrappedProxy), address(lender)), 0);
        assertEq(dai.allowance(address(wrappedProxy), address(curve)), 0);
        assertEq(dai.allowance(address(wrappedProxy), address(router)), 0);
        assertEq(otherToken.allowance(address(wrappedProxy), address(router)), 0);
        assertEq(guni.allowance(address(wrappedProxy), address(join)), 0);

        // Should have a position open worth roughly 20x the original investment
         (,uint256 rate,,,) = vat.ilks(ilk);
        (uint256 ink, uint256 art) = vat.urns(ilk, address(this));
        assertEqApprox(ink * pip.read() / 1e18, leveragedAmount, 100);
        assertEqApprox(art * rate / 1e27, leveragedAmount * (wrappedProxy.getLeverageBPS() - 10000) / wrappedProxy.getLeverageBPS(), 100);
    }

    function test_proxy_open_close_position() public {
        uint256 principal = dai.balanceOf(address(this));

        wrappedProxy.wind(dai.balanceOf(address(this)), 0);
        wrappedProxy.unwind(0);

        // Should never be leftovers
        assertEq(dai.balanceOf(address(wrappedProxy)), 0);
        assertEq(otherToken.balanceOf(address(wrappedProxy)), 0);
        assertEq(guni.balanceOf(address(wrappedProxy)), 0);

        // Should never be leftover approvals
        assertEq(dai.allowance(address(wrappedProxy), address(daiJoin)), 0);
        assertEq(otherToken.allowance(address(wrappedProxy), address(curve)), 0);
        assertEq(guni.allowance(address(wrappedProxy), address(router)), 0);

        // Position should be completely closed out
        (uint256 ink, uint256 art) = vat.urns(ilk, address(this));
        assertEq(ink, 0);
        assertEq(art, 0);
        assertEqApprox(dai.balanceOf(address(this)), principal, 500);      // Amount you get back should be approximately the same as the initial investment (minus some slippage/fees)
    } 

}
