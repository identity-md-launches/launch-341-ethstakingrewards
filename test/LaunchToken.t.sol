// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {ETHStakingRewards} from "../src/ETHStakingRewards.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract FactoryFixture {
    function deploy() external returns (LaunchToken token, ETHStakingRewards staking) {
        token = new LaunchToken();
        staking = new ETHStakingRewards(address(token));
    }
}

contract LaunchTokenTest is Test {
    LaunchToken private token;
    address private constant ALICE = address(0xA11CE);
    address private constant BOB = address(0xB0B);
    uint256 private constant SUPPLY = 1e27;

    function setUp() public {
        token = new LaunchToken();
    }

    function test_fixedSupplyAndMetadata() public view {
        assertEq(token.name(), "Trickle");
        assertEq(token.symbol(), "TRKL");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    function test_factoryOwnsSupplyAndApplicationNeedsNoTokens() public {
        FactoryFixture factory = new FactoryFixture();
        (LaunchToken deployedToken, ETHStakingRewards staking) = factory.deploy();
        assertEq(deployedToken.balanceOf(address(factory)), SUPPLY);
        assertEq(deployedToken.balanceOf(address(staking)), 0);
        assertEq(address(staking.token()), address(deployedToken));
        assertEq(staking.totalStaked(), 0);
    }

    function testFuzz_transferExactAmount(uint256 rawAmount) public {
        uint256 amount = bound(rawAmount, 0, SUPPLY);
        assertTrue(token.transfer(ALICE, amount));
        assertEq(token.balanceOf(ALICE), amount);
        assertEq(token.balanceOf(address(this)), SUPPLY - amount);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_allowanceTransferAndUnlimitedApproval() public {
        token.transfer(ALICE, 10 ether);
        vm.prank(ALICE);
        token.approve(BOB, 3 ether);
        vm.prank(BOB);
        assertTrue(token.transferFrom(ALICE, BOB, 2 ether));
        assertEq(token.allowance(ALICE, BOB), 1 ether);
        assertEq(token.balanceOf(BOB), 2 ether);
        vm.prank(ALICE);
        token.approve(BOB, type(uint256).max);
        vm.prank(BOB);
        token.transferFrom(ALICE, BOB, 1 ether);
        assertEq(token.allowance(ALICE, BOB), type(uint256).max);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_invalidTransfersRevert() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 0, 1));
        token.transfer(BOB, 1);
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, BOB, 0, 1));
        token.transferFrom(address(this), BOB, 1);
    }

    function test_noMintAdminOrUpgradeEntryPoints() public {
        string[11] memory selectors = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "pause()",
            "unpause()",
            "setMinter(address)"
        ];
        for (uint256 i; i < selectors.length; ++i) {
            bytes memory data = abi.encodeWithSignature(selectors[i], ALICE, uint256(1));
            (bool deployerSuccess,) = address(token).call(data);
            assertFalse(deployerSuccess);
            vm.prank(ALICE);
            (bool otherSuccess,) = address(token).call(data);
            assertFalse(otherSuccess);
        }
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    function test_runtimeBoundsAndForbiddenOpcodes() public {
        ETHStakingRewards staking = new ETHStakingRewards(address(token));
        _checkRuntime(address(token));
        _checkRuntime(address(staking));
    }

    function _checkRuntime(address target) private view {
        bytes memory code = target.code;
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden opcode");
        }
    }
}
