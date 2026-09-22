// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/NexusMarket.sol";

/**
 * @title NexusMarketTest
 * Real negative + integration + exploit tests.
 * Updated for MIN_COMMIT_DELAY, MAX_ROYALTY_FEE=2000, AlreadyListed, hash-squatting fix.
 */
contract NexusMarketTest is Test {
    NexusMarket public market;

    address public owner = address(0xA11CE);
    address public seller;
    uint256 public sellerPk = 0x1234;
    address public buyer = address(0xBEEF);
    address public attacker = address(0xBAD);

    uint96 constant PLATFORM_FEE = 200;
    uint96 constant ROYALTY_FEE = 500;

    function setUp() public {
        seller = vm.addr(sellerPk);
        vm.prank(owner);
        market = new NexusMarket();
        vm.deal(buyer, 100 ether);
        vm.deal(seller, 10 ether);
        vm.deal(attacker, 50 ether);
        vm.deal(owner, 1 ether);
    }

    function _mint(address to, uint96 royalty) internal returns (uint256) {
        vm.prank(owner);
        return market.mint(to, "ipfs://test", royalty);
    }

    function _list(uint256 tokenId, address listSeller, uint128 price, uint64 duration) internal {
        vm.prank(listSeller);
        market.list(tokenId, price, uint64(block.timestamp + duration));
    }

    function _directCommitment(address _buyer, address _seller, uint256 tokenId, uint128 price, uint256 nonce) internal view returns (bytes32) {
        return market.getDirectBuyCommitment(_buyer, _seller, tokenId, price, nonce);
    }

    function _signOrder(uint256 pk, address _buyer, uint256 tokenId, uint256 price, uint256 nonce, uint256 expiry, uint256 counter) internal view returns (bytes memory) {
        bytes32 structHash = market.getOrderStructHash(_buyer, tokenId, price, nonce, expiry, counter);
        bytes32 digest = market.getDigest(structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _commitAndWait(address user, bytes32 commitment) internal {
        vm.prank(user);
        market.commit(commitment);
        vm.warp(block.timestamp + 16);
    }

    // ---- Mint ----
    function test_Mint_Success() public {
        uint256 id = _mint(seller, ROYALTY_FEE);
        assertEq(market.ownerOf(id), seller);
    }

    function test_Mint_OnlyOwner() public {
        vm.prank(attacker);
        vm.expectRevert();
        market.mint(attacker, "ipfs://x", 0);
    }

    function test_Mint_RoyaltyTooHigh() public {
        vm.prank(owner);
        vm.expectRevert(NexusMarket.RoyaltyTooHigh.selector);
        market.mint(seller, "ipfs://x", 2001);
    }

    function test_Mint_ZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(NexusMarket.ZeroAddress.selector);
        market.mint(address(0), "ipfs://x", 0);
    }

    // ---- Listing ----
    function test_List_Success() public {
        uint256 id = _mint(seller, 0);
        _list(id, seller, 1 ether, 1 days);
        (uint128 price,, address s) = market.listings(id);
        assertEq(price, 1 ether);
        assertEq(s, seller);
    }

    function test_List_NotOwner() public {
        uint256 id = _mint(seller, 0);
        vm.prank(attacker);
        vm.expectRevert(NexusMarket.NotOwner.selector);
        market.list(id, 1 ether, uint64(block.timestamp + 1 days));
    }

    function test_List_AlreadyListed() public {
        uint256 id = _mint(seller, 0);
        _list(id, seller, 1 ether, 1 days);
        vm.prank(seller);
        vm.expectRevert(NexusMarket.AlreadyListed.selector);
        market.list(id, 2 ether, uint64(block.timestamp + 2 days));
    }

    function test_CancelListing_OnlySeller() public {
        uint256 id = _mint(seller, 0);
        _list(id, seller, 1 ether, 1 days);
        vm.prank(attacker);
        vm.expectRevert(NexusMarket.NotSeller.selector);
        market.cancelListing(id);
        vm.prank(seller);
        market.cancelListing(id);
        (uint128 price,,) = market.listings(id);
        assertEq(price, 0);
    }

    function test_ListingAutoCancelledOnTransfer() public {
        uint256 id = _mint(seller, 0);
        _list(id, seller, 1 ether, 1 days);
        vm.prank(seller);
        market.transferFrom(seller, buyer, id);
        (uint128 price,,) = market.listings(id);
        assertEq(price, 0);
    }

    // ---- Direct Buy ----
    function test_Buy_Success() public {
        uint256 id = _mint(seller, ROYALTY_FEE);
        uint128 price = 1 ether;
        _list(id, seller, price, 1 days);
        uint256 nonce = market.commitNonces(buyer);
        bytes32 commitment = _directCommitment(buyer, seller, id, price, nonce);
        _commitAndWait(buyer, commitment);
        vm.prank(buyer);
        market.buy{value: price}(id);
        assertEq(market.ownerOf(id), buyer);
    }

    function test_Buy_NoCommit() public {
        uint256 id = _mint(seller, 0);
        _list(id, seller, 1 ether, 1 days);
        vm.prank(buyer);
        vm.expectRevert(NexusMarket.InvalidCommit.selector);
        market.buy{value: 1 ether}(id);
    }

    function test_Buy_CommitTooRecent() public {
        uint256 id = _mint(seller, 0);
        uint128 price = 1 ether;
        _list(id, seller, price, 1 days);
        uint256 nonce = market.commitNonces(buyer);
        bytes32 commitment = _directCommitment(buyer, seller, id, price, nonce);
        vm.prank(buyer);
        market.commit(commitment);
        vm.prank(buyer);
        vm.expectRevert(NexusMarket.CommitTooRecent.selector);
        market.buy{value: price}(id);
    }

    function test_Buy_WrongCommitUser_NoLongerGriefs() public {
        uint256 id = _mint(seller, 0);
        uint128 price = 1 ether;
        _list(id, seller, price, 1 days);
        uint256 nonce = market.commitNonces(buyer);
        bytes32 commitment = _directCommitment(buyer, seller, id, price, nonce);
        vm.prank(attacker);
        market.commit(commitment);
        _commitAndWait(buyer, commitment);
        vm.prank(buyer);
        market.buy{value: price}(id);
        assertEq(market.ownerOf(id), buyer);
    }

    function test_PoC_HashSquatting_Fixed() public {
        uint256 id = _mint(seller, 0);
        uint128 price = 1 ether;
        _list(id, seller, price, 1 days);
        uint256 nonce = market.commitNonces(buyer);
        bytes32 commitment = _directCommitment(buyer, seller, id, price, nonce);
        vm.prank(attacker);
        market.commit(commitment);
        vm.prank(buyer);
        market.commit(commitment);
        vm.warp(block.timestamp + 16);
        vm.prank(buyer);
        market.buy{value: price}(id);
        assertEq(market.ownerOf(id), buyer);
    }

    function test_Buy_CommitExpired() public {
        uint256 id = _mint(seller, 0);
        uint128 price = 1 ether;
        _list(id, seller, price, 2 days);
        uint256 nonce = market.commitNonces(buyer);
        bytes32 commitment = _directCommitment(buyer, seller, id, price, nonce);
        vm.prank(buyer);
        market.commit(commitment);
        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(buyer);
        vm.expectRevert(NexusMarket.CommitExpired.selector);
        market.buy{value: price}(id);
    }

    function test_Buy_SelfBuy() public {
        uint256 id = _mint(seller, 0);
        uint128 price = 1 ether;
        _list(id, seller, price, 1 days);
        uint256 nonce = market.commitNonces(seller);
        bytes32 commitment = _directCommitment(seller, seller, id, price, nonce);
        _commitAndWait(seller, commitment);
        vm.prank(seller);
        vm.expectRevert(NexusMarket.SelfBuy.selector);
        market.buy{value: price}(id);
    }

    function test_Buy_SellerTransferredAway() public {
        uint256 id = _mint(seller, 0);
        uint128 price = 1 ether;
        _list(id, seller, price, 1 days);
        uint256 nonce = market.commitNonces(buyer);
        bytes32 commitment = _directCommitment(buyer, seller, id, price, nonce);
        _commitAndWait(buyer, commitment);
        vm.prank(seller);
        market.transferFrom(seller, attacker, id);
        vm.prank(buyer);
        vm.expectRevert(NexusMarket.NotListed.selector);
        market.buy{value: price}(id);
    }

    function test_Buy_ExcessRefund() public {
        uint256 id = _mint(seller, 0);
        uint128 price = 1 ether;
        _list(id, seller, price, 1 days);
        uint256 nonce = market.commitNonces(buyer);
        bytes32 commitment = _directCommitment(buyer, seller, id, price, nonce);
        _commitAndWait(buyer, commitment);
        uint256 balBefore = buyer.balance;
        vm.prank(buyer);
        market.buy{value: 1.5 ether}(id);
        assertEq(buyer.balance, balBefore - price);
    }

    // ---- Signature Buy ----
    function test_BuyWithSig_Success() public {
        uint256 id = _mint(seller, ROYALTY_FEE);
        uint256 price = 1 ether;
        uint256 nonce = 1;
        uint256 expiry = block.timestamp + 1 days;
        uint256 counter = market.counters(seller);
        bytes memory sig = _signOrder(sellerPk, buyer, id, price, nonce, expiry, counter);
        bytes32 structHash = market.getOrderStructHash(buyer, id, price, nonce, expiry, counter);
        bytes32 commitment = market.getSigBuyCommitment(buyer, seller, structHash);
        _commitAndWait(buyer, commitment);
        vm.prank(buyer);
        market.buyWithSig{value: price}(id, price, expiry, nonce, sig);
        assertEq(market.ownerOf(id), buyer);
        assertTrue(market.usedNonces(seller, nonce));
    }

    function test_BuyWithSig_ReplayProtected() public {
        uint256 id = _mint(seller, 0);
        uint256 price = 1 ether;
        uint256 nonce = 7;
        uint256 expiry = block.timestamp + 1 days;
        uint256 counter = market.counters(seller);
        bytes memory sig = _signOrder(sellerPk, buyer, id, price, nonce, expiry, counter);
        bytes32 structHash = market.getOrderStructHash(buyer, id, price, nonce, expiry, counter);
        bytes32 commitment = market.getSigBuyCommitment(buyer, seller, structHash);
        _commitAndWait(buyer, commitment);
        vm.prank(buyer);
        market.buyWithSig{value: price}(id, price, expiry, nonce, sig);

        uint256 id2 = _mint(seller, 0);
        bytes32 structHash2 = market.getOrderStructHash(buyer, id2, price, nonce, expiry, counter);
        bytes32 commitment2 = market.getSigBuyCommitment(buyer, seller, structHash2);
        _commitAndWait(buyer, commitment2);
        vm.prank(buyer);
        vm.expectRevert(NexusMarket.InvalidNonce.selector);
        market.buyWithSig{value: price}(id2, price, expiry, nonce, sig);
    }

    function test_CancelAllOrders_InvalidatesSignature() public {
        uint256 id = _mint(seller, 0);
        uint256 price = 1 ether;
        uint256 nonce = 1;
        uint256 expiry = block.timestamp + 1 days;
        uint256 counter = market.counters(seller);
        bytes memory sig = _signOrder(sellerPk, buyer, id, price, nonce, expiry, counter);
        vm.prank(seller);
        market.cancelAllOrders();
        bytes32 structHash = market.getOrderStructHash(buyer, id, price, nonce, expiry, counter);
        bytes32 commitment = market.getSigBuyCommitment(buyer, seller, structHash);
        _commitAndWait(buyer, commitment);
        vm.prank(buyer);
        vm.expectRevert(NexusMarket.InvalidSigner.selector);
        market.buyWithSig{value: price}(id, price, expiry, nonce, sig);
    }

    function test_CancelOrder_SingleNonce() public {
        uint256 id = _mint(seller, 0);
        uint256 price = 1 ether;
        uint256 nonce = 42;
        uint256 expiry = block.timestamp + 1 days;
        uint256 counter = market.counters(seller);
        bytes memory sig = _signOrder(sellerPk, buyer, id, price, nonce, expiry, counter);
        vm.prank(seller);
        market.cancelOrder(nonce);
        bytes32 structHash = market.getOrderStructHash(buyer, id, price, nonce, expiry, counter);
        bytes32 commitment = market.getSigBuyCommitment(buyer, seller, structHash);
        _commitAndWait(buyer, commitment);
        vm.prank(buyer);
        vm.expectRevert(NexusMarket.InvalidNonce.selector);
        market.buyWithSig{value: price}(id, price, expiry, nonce, sig);
    }

    // ---- Withdraw ----
    function test_Withdraw_WorksWhenPaused() public {
        uint256 id = _mint(seller, 0);
        uint128 price = 1 ether;
        _list(id, seller, price, 1 days);
        uint256 nonce = market.commitNonces(buyer);
        bytes32 commitment = _directCommitment(buyer, seller, id, price, nonce);
        _commitAndWait(buyer, commitment);
        vm.prank(buyer);
        market.buy{value: price}(id);
        vm.prank(owner);
        market.pause();
        vm.prank(seller);
        market.withdraw();
        assertEq(market.pendingWithdrawals(seller), 0);
    }

    function test_Withdraw_Nothing() public {
        vm.prank(buyer);
        vm.expectRevert(NexusMarket.NothingToWithdraw.selector);
        market.withdraw();
    }

    // ---- Pause ----
    function test_Pause_BlocksTrading() public {
        uint256 id = _mint(seller, 0);
        _list(id, seller, 1 ether, 1 days);
        vm.prank(owner);
        market.pause();
        vm.prank(buyer);
        vm.expectRevert();
        market.buy{value: 1 ether}(id);
    }

    // ---- Royalty / Fee ----
    function test_Sale_RoyaltyAtMax20Percent() public {
        uint256 id = _mint(seller, 2000);
        uint128 price = 1 ether;
        _list(id, seller, price, 1 days);
        uint256 nonce = market.commitNonces(buyer);
        bytes32 commitment = _directCommitment(buyer, seller, id, price, nonce);
        _commitAndWait(buyer, commitment);
        vm.prank(buyer);
        market.buy{value: price}(id);
        uint256 platformCut = (price * PLATFORM_FEE) / 10000;
        assertEq(market.pendingWithdrawals(market.feeRecipient()), platformCut);
        assertEq(market.pendingWithdrawals(seller), price - platformCut);
    }

    function test_Sale_TinyAmountPlatformFloor() public {
        uint256 id = _mint(seller, 0);
        uint128 price = 100;
        _list(id, seller, price, 1 days);
        uint256 nonce = market.commitNonces(buyer);
        bytes32 commitment = _directCommitment(buyer, seller, id, price, nonce);
        _commitAndWait(buyer, commitment);
        vm.prank(buyer);
        market.buy{value: price}(id);
        assertEq(market.pendingWithdrawals(market.feeRecipient()), 2);
        assertEq(market.pendingWithdrawals(seller), 98);
    }

    // ---- Full Lifecycle ----
    function test_FullLifecycle() public {
        uint256 id = _mint(seller, ROYALTY_FEE);
        uint128 price = 2 ether;
        _list(id, seller, price, 7 days);
        uint256 nonce = market.commitNonces(buyer);
        bytes32 commitment = _directCommitment(buyer, seller, id, price, nonce);
        _commitAndWait(buyer, commitment);
        vm.prank(buyer);
        market.buy{value: price}(id);
        assertEq(market.ownerOf(id), buyer);
        vm.prank(seller);
        market.withdraw();
        vm.prank(market.feeRecipient());
        market.withdraw();
        _list(id, buyer, 3 ether, 1 days);
        (uint128 p,, address s) = market.listings(id);
        assertEq(p, 3 ether);
        assertEq(s, buyer);
    }
}
