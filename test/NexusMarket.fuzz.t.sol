// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/NexusMarket.sol";

contract NexusMarketFuzzTest is Test {
    NexusMarket public market;

    address public owner = address(0xA11CE);
    uint256 public sellerPk = 0x1234;
    address public seller;
    address public buyer = address(0xBEEF);
    address public attacker = address(0xBAD);

    function setUp() public {
        seller = vm.addr(sellerPk);
        vm.prank(owner);
        market = new NexusMarket();
        vm.deal(buyer, 1000 ether);
        vm.deal(seller, 10 ether);
        vm.deal(attacker, 100 ether);
        vm.deal(owner, 1 ether);
    }

    function testFuzz_Mint_RoyaltyBounded(uint96 royalty) public {
        royalty = uint96(bound(royalty, 0, 2000));
        vm.prank(owner);
        uint256 id = market.mint(seller, "ipfs://fuzz", royalty);
        assertEq(market.ownerOf(id), seller);
        if (royalty > 0) {
            (address recv, uint256 amount) = market.royaltyInfo(id, 1 ether);
            assertEq(recv, seller);
            assertEq(amount, (1 ether * royalty) / 10000);
        }
    }

    function testFuzz_Mint_RejectsHighRoyalty(uint96 royalty) public {
        vm.assume(royalty > 2000);
        vm.prank(owner);
        vm.expectRevert(NexusMarket.RoyaltyTooHigh.selector);
        market.mint(seller, "ipfs://fuzz", royalty);
    }

    function testFuzz_List_ValidParams(uint128 price, uint64 duration) public {
        price = uint128(bound(price, 1, type(uint128).max));
        duration = uint64(bound(duration, 1, 365 days));
        vm.prank(owner);
        uint256 id = market.mint(seller, "ipfs://fuzz", 0);
        vm.prank(seller);
        market.list(id, price, uint64(block.timestamp + duration));
        (uint128 p, uint64 exp, address s) = market.listings(id);
        assertEq(p, price);
        assertEq(s, seller);
        assertEq(exp, block.timestamp + duration);
    }

    function testFuzz_Buy_Success(uint128 price, uint96 royalty) public {
        price = uint128(bound(price, 1e15, 50 ether));
        royalty = uint96(bound(royalty, 0, 2000));
        vm.prank(owner);
        uint256 id = market.mint(seller, "ipfs://fuzz", royalty);
        vm.prank(seller);
        market.list(id, price, uint64(block.timestamp + 1 days));
        uint256 nonce = market.commitNonces(buyer);
        bytes32 commitment = market.getDirectBuyCommitment(buyer, seller, id, price, nonce);
        vm.prank(buyer);
        market.commit(commitment);
        vm.warp(block.timestamp + 16);
        uint256 balBefore = buyer.balance;
        vm.prank(buyer);
        market.buy{value: price}(id);
        assertEq(market.ownerOf(id), buyer);
        assertEq(buyer.balance, balBefore - price);
        uint256 platformPending = market.pendingWithdrawals(market.feeRecipient());
        uint256 sellerPending = market.pendingWithdrawals(seller);
        assertLe(platformPending, price);
        assertEq(platformPending + sellerPending, price);
    }

    function testFuzz_Buy_RejectsInsufficientETH(uint128 price, uint128 sent) public {
        price = uint128(bound(price, 1e15, 10 ether));
        sent = uint128(bound(sent, 0, price - 1));
        vm.prank(owner);
        uint256 id = market.mint(seller, "ipfs://fuzz", 0);
        vm.prank(seller);
        market.list(id, price, uint64(block.timestamp + 1 days));
        uint256 nonce = market.commitNonces(buyer);
        bytes32 commitment = market.getDirectBuyCommitment(buyer, seller, id, price, nonce);
        vm.prank(buyer);
        market.commit(commitment);
        vm.warp(block.timestamp + 16);
        vm.prank(buyer);
        vm.expectRevert(NexusMarket.InsufficientETH.selector);
        market.buy{value: sent}(id);
    }

    function testFuzz_Buy_RejectsExpiredCommit(uint128 price, uint256 warpTime) public {
        price = uint128(bound(price, 1e15, 5 ether));
        warpTime = bound(warpTime, 1 days + 1, 30 days);
        vm.prank(owner);
        uint256 id = market.mint(seller, "ipfs://fuzz", 0);
        vm.prank(seller);
        market.list(id, price, uint64(block.timestamp + 30 days));
        uint256 nonce = market.commitNonces(buyer);
        bytes32 commitment = market.getDirectBuyCommitment(buyer, seller, id, price, nonce);
        vm.prank(buyer);
        market.commit(commitment);
        vm.warp(block.timestamp + warpTime);
        vm.prank(buyer);
        vm.expectRevert(NexusMarket.CommitExpired.selector);
        market.buy{value: price}(id);
    }

    function testFuzz_PlatformFee_NeverExceedsAmount(uint128 price, uint96 fee) public {
        fee = uint96(bound(fee, 0, 1000));
        price = uint128(bound(price, 1, 100 ether));
        vm.prank(owner);
        market.setPlatformFee(fee);
        vm.prank(owner);
        uint256 id = market.mint(seller, "ipfs://fuzz", 0);
        vm.prank(seller);
        market.list(id, price, uint64(block.timestamp + 1 days));
        uint256 nonce = market.commitNonces(buyer);
        bytes32 commitment = market.getDirectBuyCommitment(buyer, seller, id, price, nonce);
        vm.prank(buyer);
        market.commit(commitment);
        vm.warp(block.timestamp + 16);
        vm.prank(buyer);
        market.buy{value: price}(id);
        uint256 platformPending = market.pendingWithdrawals(market.feeRecipient());
        uint256 sellerPending = market.pendingWithdrawals(seller);
        assertLe(platformPending, price);
        assertEq(platformPending + sellerPending, price);
    }

    function testFuzz_Commit_CannotBlockOtherUser(bytes32 commitment) public {
        vm.prank(buyer);
        market.commit(commitment);
        // attacker can also commit same hash (own slot)
        vm.prank(attacker);
        market.commit(commitment);
    }

    function testFuzz_CancelAllOrders_IncrementsCounter(uint256 times) public {
        times = bound(times, 1, 50);
        uint256 start = market.counters(seller);
        for (uint256 i = 0; i < times; i++) {
            vm.prank(seller);
            market.cancelAllOrders();
        }
        assertEq(market.counters(seller), start + times);
    }
}
