// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/NexusMarket.sol";

/**
 * @title NexusMarketTest
 * @notice Real-world negative, integration, exploit-style tests.
 *          Focus on attacks, edge cases, and the new features (cancelAllOrders, withdraw when paused).
 */
contract NexusMarketTest is Test {
    NexusMarket public market;

    address public owner = address(0xA11CE);
    address public seller;
    uint256 public sellerPk = 0x1234;
    address public buyer = address(0xBEEF);
    address public buyer2 = address(0xCAFE);
    address public attacker = address(0xBAD);
    address public feeRecipient2 = address(0xFEE2);

    uint96 constant PLATFORM_FEE = 200;
    uint96 constant ROYALTY_FEE = 500;

    function setUp() public {
        seller = vm.addr(sellerPk);

        vm.prank(owner);
        market = new NexusMarket();

        vm.deal(buyer, 100 ether);
        vm.deal(buyer2, 100 ether);
        vm.deal(seller, 10 ether);
        vm.deal(attacker, 50 ether);
        vm.deal(owner, 1 ether);
    }

    // ============ Helpers ============

    function _mint(address to, uint96 royalty) internal returns (uint256) {
        vm.prank(owner);
        return market.mint(to, "ipfs://test", royalty);
    }

    function _list(uint256 tokenId, address listSeller, uint128 price, uint64 duration) internal {
        vm.prank(listSeller);
        market.list(tokenId, price, uint64(block.timestamp + duration));
    }

    function _directCommitment(
        address _buyer,
        address _seller,
        uint256 tokenId,
        uint128 price,
        uint256 nonce
    ) internal view returns (bytes32) {
        return market.getDirectBuyCommitment(_buyer, _seller, tokenId, price, nonce);
    }

    function _signOrder(
        uint256 pk,
        address _buyer,
        uint256 tokenId,
        uint256 price,
        uint256 nonce,
        uint256 expiry,
        uint256 counter
    ) internal view returns (bytes memory) {
        bytes32 structHash = market.getOrderStructHash(_buyer, tokenId, price, nonce, expiry, counter);
        bytes32 digest = market.getDigest(structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    // ============ Mint ============

    function test_Mint_Success() public {
        uint256 id = _mint(seller, ROYALTY_FEE);
        assertEq(market.ownerOf(id), seller);
        (address recv, uint256 amount) = market.royaltyInfo(id, 1 ether);
        assertEq(recv, seller);
        assertEq(amount, (1 ether * ROYALTY_FEE) / 10000);
    }

    function test_Mint_OnlyOwner() public {
        vm.prank(attacker);
        vm.expectRevert();
        market.mint(attacker, "ipfs://x", 0);
    }

    function test_Mint_RoyaltyTooHigh() public {
        vm.prank(owner);
        vm.expectRevert(NexusMarket.RoyaltyTooHigh.selector);
        market.mint(seller, "ipfs://x", 10001);
    }

    function test_Mint_ZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(NexusMarket.ZeroAddress.selector);
        market.mint(address(0), "ipfs://x", 0);
    }

    // ============ Listing ============

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

    // ============ Direct Buy ============

    function test_Buy_Success() public {
        uint256 id = _mint(seller, ROYALTY_FEE);
        uint128 price = 1 ether;
        _list(id, seller, price, 1 days);

        uint256 nonce = market.commitNonces(buyer);
        bytes32 commitment = _directCommitment(buyer, seller, id, price, nonce);

        vm.prank(buyer);
        market.commit(commitment);

        vm.prank(buyer);
        market.buy{value: price}(id);

        assertEq(market.ownerOf(id), buyer);
        (uint128 p,,) = market.listings(id);
        assertEq(p, 0);
    }

    function test_Buy_NoCommit() public {
        uint256 id = _mint(seller, 0);
        _list(id, seller, 1 ether, 1 days);

        vm.prank(buyer);
        vm.expectRevert(NexusMarket.InvalidCommit.selector);
        market.buy{value: 1 ether}(id);
    }

    function test_Buy_WrongCommitUser_Griefing() public {
        uint256 id = _mint(seller, 0);
        uint128 price = 1 ether;
        _list(id, seller, price, 1 days);

        uint256 nonce = market.commitNonces(buyer);
        bytes32 commitment = _directCommitment(buyer, seller, id, price, nonce);

        // Attacker tries to grief by committing the hash
        vm.prank(attacker);
        market.commit(commitment);

        vm.prank(buyer);
        vm.expectRevert(NexusMarket.InvalidCommit.selector);
        market.buy{value: price}(id);
    }

    function test_Buy_CommitExpired() public {
        uint256 id = _mint(seller, 0);
        uint128 price = 1 ether;
        _list(id, seller, price, 1 days);

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

        vm.prank(seller);
        market.commit(commitment);

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

        vm.prank(buyer);
        market.commit(commitment);

        vm.prank(seller);
        market.transferFrom(seller, attacker, id);

        // Listing deleted by _update
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

        vm.prank(buyer);
        market.commit(commitment);

        uint256 balBefore = buyer.balance;
        vm.prank(buyer);
        market.buy{value: 1.5 ether}(id);

        assertEq(buyer.balance, balBefore - price);
    }

    // ============ Signature Buy + New Cancel Features ============

    function test_BuyWithSig_Success() public {
        uint256 id = _mint(seller, ROYALTY_FEE);
        uint256 price = 1 ether;
        uint256 nonce = 1;
        uint256 expiry = block.timestamp + 1 days;
        uint256 counter = market.counters(seller);

        bytes memory sig = _signOrder(sellerPk, buyer, id, price, nonce, expiry, counter);

        bytes32 structHash = market.getOrderStructHash(buyer, id, price, nonce, expiry, counter);
        bytes32 commitment = market.getSigBuyCommitment(buyer, seller, structHash);

        vm.prank(buyer);
        market.commit(commitment);

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

        vm.prank(buyer);
        market.commit(commitment);
        vm.prank(buyer);
        market.buyWithSig{value: price}(id, price, expiry, nonce, sig);

        // Replay attempt
        uint256 id2 = _mint(seller, 0);
        bytes32 structHash2 = market.getOrderStructHash(buyer, id2, price, nonce, expiry, counter);
        bytes32 commitment2 = market.getSigBuyCommitment(buyer, seller, structHash2);

        vm.prank(buyer);
        market.commit(commitment2);

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

        // Bulk cancel
        vm.prank(seller);
        market.cancelAllOrders();
        assertEq(market.counters(seller), counter + 1);

        bytes32 structHash = market.getOrderStructHash(buyer, id, price, nonce, expiry, counter);
        bytes32 commitment = market.getSigBuyCommitment(buyer, seller, structHash);

        vm.prank(buyer);
        market.commit(commitment);

        // Old signature is now invalid because counter changed
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

        vm.prank(buyer);
        market.commit(commitment);

        vm.prank(buyer);
        vm.expectRevert(NexusMarket.InvalidNonce.selector);
        market.buyWithSig{value: price}(id, price, expiry, nonce, sig);
    }

    // ============ CRITICAL: Withdraw when Paused ============

    function test_Withdraw_WorksWhenPaused() public {
        uint256 id = _mint(seller, 0);
        uint128 price = 1 ether;
        _list(id, seller, price, 1 days);

        uint256 nonce = market.commitNonces(buyer);
        bytes32 commitment = _directCommitment(buyer, seller, id, price, nonce);

        vm.prank(buyer);
        market.commit(commitment);
        vm.prank(buyer);
        market.buy{value: price}(id);

        // Pause the market
        vm.prank(owner);
        market.pause();

        uint256 pending = market.pendingWithdrawals(seller);
        assertTrue(pending > 0);

        // This must succeed even while paused
        vm.prank(seller);
        market.withdraw();

        assertEq(market.pendingWithdrawals(seller), 0);
    }

    function test_Withdraw_Nothing() public {
        vm.prank(buyer);
        vm.expectRevert(NexusMarket.NothingToWithdraw.selector);
        market.withdraw();
    }

    // ============ Pause Blocks Trading ============

    function test_Pause_BlocksTrading() public {
        uint256 id = _mint(seller, 0);
        _list(id, seller, 1 ether, 1 days);

        vm.prank(owner);
        market.pause();

        vm.prank(buyer);
        vm.expectRevert(); // Pausable
        market.buy{value: 1 ether}(id);
    }

    // ============ Royalty / Fee Edge Cases ============

    function test_Sale_RoyaltyCappedWhen100Percent() public {
        uint256 id = _mint(seller, 10000);
        uint128 price = 1 ether;
        _list(id, seller, price, 1 days);

        uint256 nonce = market.commitNonces(buyer);
        bytes32 commitment = _directCommitment(buyer, seller, id, price, nonce);

        vm.prank(buyer);
        market.commit(commitment);
        vm.prank(buyer);
        market.buy{value: price}(id);

        uint256 platformCut = (price * PLATFORM_FEE) / 10000;
        assertEq(market.pendingWithdrawals(seller), price - platformCut);
        assertEq(market.pendingWithdrawals(market.feeRecipient()), platformCut);
    }

    function test_Sale_TinyAmountPlatformFloor() public {
        uint256 id = _mint(seller, 0);
        uint128 price = 100;
        _list(id, seller, price, 1 days);

        uint256 nonce = market.commitNonces(buyer);
        bytes32 commitment = _directCommitment(buyer, seller, id, price, nonce);

        vm.prank(buyer);
        market.commit(commitment);
        vm.prank(buyer);
        market.buy{value: price}(id);

        assertEq(market.pendingWithdrawals(market.feeRecipient()), 1);
        assertEq(market.pendingWithdrawals(seller), price - 1);
    }

    // ============ Full Integration ============

    function test_FullLifecycle() public {
        uint256 id = _mint(seller, ROYALTY_FEE);
        uint128 price = 2 ether;
        _list(id, seller, price, 7 days);

        uint256 nonce = market.commitNonces(buyer);
        bytes32 commitment = _directCommitment(buyer, seller, id, price, nonce);
        vm.prank(buyer);
        market.commit(commitment);
        vm.prank(buyer);
        market.buy{value: price}(id);

        assertEq(market.ownerOf(id), buyer);

        vm.prank(seller);
        market.withdraw();
        vm.prank(market.feeRecipient());
        market.withdraw();

        // Buyer can re-list
        _list(id, buyer, 3 ether, 1 days);
        (uint128 p,, address s) = market.listings(id);
        assertEq(p, 3 ether);
        assertEq(s, buyer);
    }
}
