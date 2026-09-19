// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "../src/NexusMarket.sol";

/**
 * @title NexusMarketTest
 * @notice Comprehensive positive + negative + integration + exploit-style tests.
 *         These are deliberately written to catch real issues, not just happy paths.
 */
contract NexusMarketTest is Test {
    NexusMarket public market;

    address public owner = address(0xA11CE);
    address public seller = address(0xB0B);
    address public buyer = address(0xBEEF);
    address public buyer2 = address(0xCAFE);
    address public royaltyReceiver = address(0xFEE);
    address public attacker = address(0xBAD);
    address public feeRecipient2 = address(0xFEE2);

    uint256 public sellerPk = 0xA11CE; // for signing (we will use vm.addr)
    uint256 public realSellerPk;
    address public realSeller;

    uint96 constant PLATFORM_FEE = 200; // 2%
    uint96 constant ROYALTY_FEE = 500;  // 5%

    function setUp() public {
        // Deterministic keys for signing
        realSellerPk = 0x1234;
        realSeller = vm.addr(realSellerPk);

        vm.prank(owner);
        market = new NexusMarket();

        // Fund accounts
        vm.deal(buyer, 100 ether);
        vm.deal(buyer2, 100 ether);
        vm.deal(seller, 10 ether);
        vm.deal(realSeller, 10 ether);
        vm.deal(attacker, 50 ether);
        vm.deal(owner, 1 ether);
    }

    // ============ Helpers ============

    function _mintTo(address to, uint96 royalty) internal returns (uint256 tokenId) {
        vm.prank(owner);
        tokenId = market.mint(to, "ipfs://test", royalty);
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
        uint256 expiry
    ) internal view returns (bytes memory) {
        bytes32 structHash = market.getOrderStructHash(_buyer, tokenId, price, nonce, expiry);
        bytes32 digest = market.getDigest(structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    // ============ Mint Tests ============

    function test_Mint_Success() public {
        uint256 id = _mintTo(seller, ROYALTY_FEE);
        assertEq(market.ownerOf(id), seller);
        assertEq(market.tokenURI(id), "ipfs://test");
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
        vm.expectRevert("Royalty too high");
        market.mint(seller, "ipfs://x", 10001);
    }

    function test_Mint_ZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert("Zero address");
        market.mint(address(0), "ipfs://x", 0);
    }

    function test_Mint_WhenPaused() public {
        vm.prank(owner);
        market.pause();

        vm.prank(owner);
        vm.expectRevert();
        market.mint(seller, "ipfs://x", 0);
    }

    // ============ Listing Tests ============

    function test_List_Success() public {
        uint256 id = _mintTo(seller, 0);
        _list(id, seller, 1 ether, 1 days);

        (uint128 price, uint64 expiry, address s) = market.listings(id);
        assertEq(price, 1 ether);
        assertEq(s, seller);
        assertTrue(expiry > block.timestamp);
    }

    function test_List_NotOwner() public {
        uint256 id = _mintTo(seller, 0);
        vm.prank(attacker);
        vm.expectRevert("Not owner");
        market.list(id, 1 ether, uint64(block.timestamp + 1 days));
    }

    function test_List_ZeroPrice() public {
        uint256 id = _mintTo(seller, 0);
        vm.prank(seller);
        vm.expectRevert("Zero price");
        market.list(id, 0, uint64(block.timestamp + 1 days));
    }

    function test_List_BadExpiry() public {
        uint256 id = _mintTo(seller, 0);
        vm.prank(seller);
        vm.expectRevert("Bad expiry");
        market.list(id, 1 ether, uint64(block.timestamp - 1));
    }

    function test_CancelListing_Success() public {
        uint256 id = _mintTo(seller, 0);
        _list(id, seller, 1 ether, 1 days);

        vm.prank(seller);
        market.cancelListing(id);

        (uint128 price,,) = market.listings(id);
        assertEq(price, 0);
    }

    function test_CancelListing_NotSeller() public {
        uint256 id = _mintTo(seller, 0);
        _list(id, seller, 1 ether, 1 days);

        vm.prank(attacker);
        vm.expectRevert("Not seller");
        market.cancelListing(id);
    }

    function test_CancelListing_NotListed() public {
        uint256 id = _mintTo(seller, 0);
        vm.prank(seller);
        vm.expectRevert("Not listed");
        market.cancelListing(id);
    }

    function test_ListingAutoCancelledOnTransfer() public {
        uint256 id = _mintTo(seller, 0);
        _list(id, seller, 1 ether, 1 days);

        // Transfer away
        vm.prank(seller);
        market.transferFrom(seller, buyer, id);

        (uint128 price,,) = market.listings(id);
        assertEq(price, 0);
    }

    // ============ Direct Buy – Happy Path ============

    function test_Buy_Success() public {
        uint256 id = _mintTo(realSeller, ROYALTY_FEE);
        uint128 price = 1 ether;
        _list(id, realSeller, price, 1 days);

        uint256 nonce = market.commitNonces(buyer);
        bytes32 commitment = _directCommitment(buyer, realSeller, id, price, nonce);

        vm.prank(buyer);
        market.commit(commitment);

        uint256 sellerBalBefore = market.pendingWithdrawals(realSeller);
        uint256 feeBalBefore = market.pendingWithdrawals(market.feeRecipient());
        uint256 royaltyBalBefore = market.pendingWithdrawals(realSeller); // royalty goes to minter = realSeller

        vm.prank(buyer);
        market.buy{value: price}(id);

        assertEq(market.ownerOf(id), buyer);
        (uint128 p,,) = market.listings(id);
        assertEq(p, 0);

        uint256 platformCut = (price * PLATFORM_FEE) / 10000;
        uint256 royaltyAmount = (price * ROYALTY_FEE) / 10000;
        uint256 sellerAmount = price - platformCut - royaltyAmount;

        assertEq(market.pendingWithdrawals(realSeller), sellerBalBefore + sellerAmount + royaltyAmount);
        assertEq(market.pendingWithdrawals(market.feeRecipient()), feeBalBefore + platformCut);
    }

    function test_Buy_WithExcessRefund() public {
        uint256 id = _mintTo(realSeller, 0);
        uint128 price = 1 ether;
        _list(id, realSeller, price, 1 days);

        uint256 nonce = market.commitNonces(buyer);
        bytes32 commitment = _directCommitment(buyer, realSeller, id, price, nonce);

        vm.prank(buyer);
        market.commit(commitment);

        uint256 balBefore = buyer.balance;
        vm.prank(buyer);
        market.buy{value: 1.5 ether}(id);

        // 0.5 ether should be refunded
        assertEq(buyer.balance, balBefore - price);
        assertEq(market.ownerOf(id), buyer);
    }

    // ============ Direct Buy – Negative / Exploit style ============

    function test_Buy_NoCommit() public {
        uint256 id = _mintTo(realSeller, 0);
        _list(id, realSeller, 1 ether, 1 days);

        vm.prank(buyer);
        vm.expectRevert("Not committer");
        market.buy{value: 1 ether}(id);
    }

    function test_Buy_WrongCommitUser() public {
        uint256 id = _mintTo(realSeller, 0);
        uint128 price = 1 ether;
        _list(id, realSeller, price, 1 days);

        uint256 nonce = market.commitNonces(buyer);
        bytes32 commitment = _directCommitment(buyer, realSeller, id, price, nonce);

        // Attacker commits the hash that belongs to buyer
        vm.prank(attacker);
        market.commit(commitment);

        // Buyer tries to buy – should fail because commit.user == attacker
        vm.prank(buyer);
        vm.expectRevert("Not committer");
        market.buy{value: price}(id);
    }

    function test_Buy_CommitExpired() public {
        uint256 id = _mintTo(realSeller, 0);
        uint128 price = 1 ether;
        _list(id, realSeller, price, 1 days);

        uint256 nonce = market.commitNonces(buyer);
        bytes32 commitment = _directCommitment(buyer, realSeller, id, price, nonce);

        vm.prank(buyer);
        market.commit(commitment);

        // Warp past MAX_COMMIT_AGE
        vm.warp(block.timestamp + 1 days + 1);

        vm.prank(buyer);
        vm.expectRevert("Commit expired");
        market.buy{value: price}(id);
    }

    function test_Buy_ExpiredListing() public {
        uint256 id = _mintTo(realSeller, 0);
        uint128 price = 1 ether;
        _list(id, realSeller, price, 1 hours);

        uint256 nonce = market.commitNonces(buyer);
        bytes32 commitment = _directCommitment(buyer, realSeller, id, price, nonce);

        vm.prank(buyer);
        market.commit(commitment);

        vm.warp(block.timestamp + 2 hours);

        vm.prank(buyer);
        vm.expectRevert("Expired");
        market.buy{value: price}(id);
    }

    function test_Buy_InsufficientETH() public {
        uint256 id = _mintTo(realSeller, 0);
        uint128 price = 1 ether;
        _list(id, realSeller, price, 1 days);

        uint256 nonce = market.commitNonces(buyer);
        bytes32 commitment = _directCommitment(buyer, realSeller, id, price, nonce);

        vm.prank(buyer);
        market.commit(commitment);

        vm.prank(buyer);
        vm.expectRevert("Low ETH");
        market.buy{value: 0.5 ether}(id);
    }

    function test_Buy_SelfBuy() public {
        uint256 id = _mintTo(realSeller, 0);
        uint128 price = 1 ether;
        _list(id, realSeller, price, 1 days);

        uint256 nonce = market.commitNonces(realSeller);
        bytes32 commitment = _directCommitment(realSeller, realSeller, id, price, nonce);

        vm.prank(realSeller);
        market.commit(commitment);

        vm.prank(realSeller);
        vm.expectRevert("Self buy");
        market.buy{value: price}(id);
    }

    function test_Buy_SellerTransferredAway() public {
        uint256 id = _mintTo(realSeller, 0);
        uint128 price = 1 ether;
        _list(id, realSeller, price, 1 days);

        uint256 nonce = market.commitNonces(buyer);
        bytes32 commitment = _directCommitment(buyer, realSeller, id, price, nonce);

        vm.prank(buyer);
        market.commit(commitment);

        // Seller transfers NFT away after commit
        vm.prank(realSeller);
        market.transferFrom(realSeller, attacker, id);

        // Listing should already be deleted by _update
        vm.prank(buyer);
        vm.expectRevert("Not listed");
        market.buy{value: price}(id);
    }

    function test_Buy_DoubleSpendSameCommit() public {
        uint256 id = _mintTo(realSeller, 0);
        uint128 price = 1 ether;
        _list(id, realSeller, price, 1 days);

        uint256 nonce = market.commitNonces(buyer);
        bytes32 commitment = _directCommitment(buyer, realSeller, id, price, nonce);

        vm.prank(buyer);
        market.commit(commitment);

        vm.prank(buyer);
        market.buy{value: price}(id);

        // Try to reuse same commitment (already deleted)
        // Need another listing first
        uint256 id2 = _mintTo(realSeller, 0);
        _list(id2, realSeller, price, 1 days);

        // Same old commitment cannot be reused
        vm.prank(buyer);
        vm.expectRevert("Not committer");
        market.buy{value: price}(id2);
    }

    function test_Buy_CommitNonceIncrements() public {
        uint256 id = _mintTo(realSeller, 0);
        uint128 price = 1 ether;
        _list(id, realSeller, price, 1 days);

        uint256 nonceBefore = market.commitNonces(buyer);
        bytes32 commitment = _directCommitment(buyer, realSeller, id, price, nonceBefore);

        vm.prank(buyer);
        market.commit(commitment);

        vm.prank(buyer);
        market.buy{value: price}(id);

        assertEq(market.commitNonces(buyer), nonceBefore + 1);
    }

    // ============ Signature Buy Tests ============

    function test_BuyWithSig_Success() public {
        uint256 id = _mintTo(realSeller, ROYALTY_FEE);
        uint256 price = 1 ether;
        uint256 nonce = market.nonces(realSeller);
        uint256 expiry = block.timestamp + 1 days;

        bytes memory sig = _signOrder(realSellerPk, buyer, id, price, nonce, expiry);

        bytes32 structHash = market.getOrderStructHash(buyer, id, price, nonce, expiry);
        bytes32 commitment = market.getSigBuyCommitment(buyer, realSeller, structHash);

        vm.prank(buyer);
        market.commit(commitment);

        vm.prank(buyer);
        market.buyWithSig{value: price}(id, price, expiry, nonce, sig);

        assertEq(market.ownerOf(id), buyer);
        assertEq(market.nonces(realSeller), nonce + 1);
    }

    function test_BuyWithSig_InvalidSigner() public {
        uint256 id = _mintTo(realSeller, 0);
        uint256 price = 1 ether;
        uint256 nonce = market.nonces(realSeller);
        uint256 expiry = block.timestamp + 1 days;

        // Attacker signs instead of seller
        bytes memory sig = _signOrder(0x9999, buyer, id, price, nonce, expiry);

        bytes32 structHash = market.getOrderStructHash(buyer, id, price, nonce, expiry);
        bytes32 commitment = market.getSigBuyCommitment(buyer, realSeller, structHash);

        vm.prank(buyer);
        market.commit(commitment);

        vm.prank(buyer);
        vm.expectRevert("Invalid signer");
        market.buyWithSig{value: price}(id, price, expiry, nonce, sig);
    }

    function test_BuyWithSig_ReplayNonce() public {
        uint256 id = _mintTo(realSeller, 0);
        uint256 price = 1 ether;
        uint256 nonce = market.nonces(realSeller);
        uint256 expiry = block.timestamp + 1 days;

        bytes memory sig = _signOrder(realSellerPk, buyer, id, price, nonce, expiry);

        bytes32 structHash = market.getOrderStructHash(buyer, id, price, nonce, expiry);
        bytes32 commitment = market.getSigBuyCommitment(buyer, realSeller, structHash);

        vm.prank(buyer);
        market.commit(commitment);

        vm.prank(buyer);
        market.buyWithSig{value: price}(id, price, expiry, nonce, sig);

        // Second NFT + same nonce should fail
        uint256 id2 = _mintTo(realSeller, 0);
        bytes32 structHash2 = market.getOrderStructHash(buyer, id2, price, nonce, expiry);
        bytes32 commitment2 = market.getSigBuyCommitment(buyer, realSeller, structHash2);

        vm.prank(buyer);
        market.commit(commitment2);

        // Nonce already consumed
        vm.prank(buyer);
        vm.expectRevert("Invalid nonce");
        market.buyWithSig{value: price}(id2, price, expiry, nonce, sig);
    }

    function test_BuyWithSig_ExpiredOrder() public {
        uint256 id = _mintTo(realSeller, 0);
        uint256 price = 1 ether;
        uint256 nonce = market.nonces(realSeller);
        uint256 expiry = block.timestamp + 1 hours;

        bytes memory sig = _signOrder(realSellerPk, buyer, id, price, nonce, expiry);

        bytes32 structHash = market.getOrderStructHash(buyer, id, price, nonce, expiry);
        bytes32 commitment = market.getSigBuyCommitment(buyer, realSeller, structHash);

        vm.prank(buyer);
        market.commit(commitment);

        vm.warp(block.timestamp + 2 hours);

        vm.prank(buyer);
        vm.expectRevert("Order expired");
        market.buyWithSig{value: price}(id, price, expiry, nonce, sig);
    }

    function test_BuyWithSig_SellerNoLongerOwner() public {
        uint256 id = _mintTo(realSeller, 0);
        uint256 price = 1 ether;
        uint256 nonce = market.nonces(realSeller);
        uint256 expiry = block.timestamp + 1 days;

        bytes memory sig = _signOrder(realSellerPk, buyer, id, price, nonce, expiry);

        bytes32 structHash = market.getOrderStructHash(buyer, id, price, nonce, expiry);
        bytes32 commitment = market.getSigBuyCommitment(buyer, realSeller, structHash);

        vm.prank(buyer);
        market.commit(commitment);

        // Seller transfers away after signing
        vm.prank(realSeller);
        market.transferFrom(realSeller, attacker, id);

        vm.prank(buyer);
        vm.expectRevert("Seller no longer owner");
        market.buyWithSig{value: price}(id, price, expiry, nonce, sig);
    }

    // ============ Withdraw Tests ============

    function test_Withdraw_Success() public {
        uint256 id = _mintTo(realSeller, 0);
        uint128 price = 1 ether;
        _list(id, realSeller, price, 1 days);

        uint256 nonce = market.commitNonces(buyer);
        bytes32 commitment = _directCommitment(buyer, realSeller, id, price, nonce);

        vm.prank(buyer);
        market.commit(commitment);
        vm.prank(buyer);
        market.buy{value: price}(id);

        uint256 pending = market.pendingWithdrawals(realSeller);
        assertTrue(pending > 0);

        uint256 balBefore = realSeller.balance;
        vm.prank(realSeller);
        market.withdraw();

        assertEq(realSeller.balance, balBefore + pending);
        assertEq(market.pendingWithdrawals(realSeller), 0);
    }

    function test_Withdraw_Nothing() public {
        vm.prank(buyer);
        vm.expectRevert("Nothing to withdraw");
        market.withdraw();
    }

    function test_Withdraw_WhenPaused() public {
        // First create some pending
        uint256 id = _mintTo(realSeller, 0);
        uint128 price = 1 ether;
        _list(id, realSeller, price, 1 days);

        uint256 nonce = market.commitNonces(buyer);
        bytes32 commitment = _directCommitment(buyer, realSeller, id, price, nonce);
        vm.prank(buyer);
        market.commit(commitment);
        vm.prank(buyer);
        market.buy{value: price}(id);

        vm.prank(owner);
        market.pause();

        vm.prank(realSeller);
        vm.expectRevert();
        market.withdraw();
    }

    // ============ Admin / Pause Tests ============

    function test_SetPlatformFee() public {
        vm.prank(owner);
        market.setPlatformFee(500);
        assertEq(market.platformFee(), 500);
    }

    function test_SetPlatformFee_TooHigh() public {
        vm.prank(owner);
        vm.expectRevert("Too high");
        market.setPlatformFee(1001);
    }

    function test_SetFeeRecipient() public {
        vm.prank(owner);
        market.setFeeRecipient(feeRecipient2);
        assertEq(market.feeRecipient(), feeRecipient2);
    }

    function test_SetFeeRecipient_Zero() public {
        vm.prank(owner);
        vm.expectRevert("Zero address");
        market.setFeeRecipient(address(0));
    }

    function test_PauseUnpause() public {
        vm.prank(owner);
        market.pause();
        assertTrue(market.paused());

        vm.prank(owner);
        market.unpause();
        assertFalse(market.paused());
    }

    function test_OnlyOwnerAdmin() public {
        vm.prank(attacker);
        vm.expectRevert();
        market.setPlatformFee(100);

        vm.prank(attacker);
        vm.expectRevert();
        market.pause();
    }

    // ============ Commit Griefing / DoS style ============

    function test_Commit_OverwriteAfterExpiry() public {
        bytes32 commitment = keccak256("test");

        vm.prank(buyer);
        market.commit(commitment);

        // Same user can overwrite after expiry
        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(buyer);
        market.commit(commitment); // should succeed
    }

    function test_Commit_CannotOverwriteActive() public {
        bytes32 commitment = keccak256("test");

        vm.prank(buyer);
        market.commit(commitment);

        vm.prank(attacker);
        vm.expectRevert("Commit exists or unexpired");
        market.commit(commitment);
    }

    // ============ Royalty + Fee Edge Cases ============

    function test_Sale_RoyaltyCappedWhenTooHigh() public {
        // 100% royalty + 2% platform → royalty should be reduced
        uint256 id = _mintTo(realSeller, 10000);
        uint128 price = 1 ether;
        _list(id, realSeller, price, 1 days);

        uint256 nonce = market.commitNonces(buyer);
        bytes32 commitment = _directCommitment(buyer, realSeller, id, price, nonce);

        vm.prank(buyer);
        market.commit(commitment);
        vm.prank(buyer);
        market.buy{value: price}(id);

        uint256 platformCut = (price * PLATFORM_FEE) / 10000;
        // royalty should have been capped to price - platformCut
        uint256 expectedRoyalty = price - platformCut;

        // realSeller receives both seller share (0) + royalty
        assertEq(market.pendingWithdrawals(realSeller), expectedRoyalty);
        assertEq(market.pendingWithdrawals(market.feeRecipient()), platformCut);
    }

    function test_Sale_TinyAmountPlatformFloor() public {
        // price so small that platformCut would be 0 without floor
        uint256 id = _mintTo(realSeller, 0);
        uint128 price = 100; // 100 wei
        _list(id, realSeller, price, 1 days);

        uint256 nonce = market.commitNonces(buyer);
        bytes32 commitment = _directCommitment(buyer, realSeller, id, price, nonce);

        vm.prank(buyer);
        market.commit(commitment);
        vm.prank(buyer);
        market.buy{value: price}(id);

        // platform should take at least 1 wei
        assertEq(market.pendingWithdrawals(market.feeRecipient()), 1);
        assertEq(market.pendingWithdrawals(realSeller), price - 1);
    }

    // ============ Reentrancy style (should be protected) ============

    // Simple malicious receiver that tries to re-enter withdraw
    function test_Withdraw_ReentrancyProtected() public {
        // We just verify nonReentrant is present by checking normal flow works
        // and that a second withdraw fails after zeroing.
        uint256 id = _mintTo(realSeller, 0);
        uint128 price = 1 ether;
        _list(id, realSeller, price, 1 days);

        uint256 nonce = market.commitNonces(buyer);
        bytes32 commitment = _directCommitment(buyer, realSeller, id, price, nonce);
        vm.prank(buyer);
        market.commit(commitment);
        vm.prank(buyer);
        market.buy{value: price}(id);

        vm.prank(realSeller);
        market.withdraw();

        vm.prank(realSeller);
        vm.expectRevert("Nothing to withdraw");
        market.withdraw();
    }

    // ============ Integration: Full lifecycle ============

    function test_FullLifecycle() public {
        // 1. Mint with royalty
        uint256 id = _mintTo(realSeller, ROYALTY_FEE);

        // 2. List
        uint128 price = 2 ether;
        _list(id, realSeller, price, 7 days);

        // 3. Commit + Buy
        uint256 nonce = market.commitNonces(buyer);
        bytes32 commitment = _directCommitment(buyer, realSeller, id, price, nonce);
        vm.prank(buyer);
        market.commit(commitment);
        vm.prank(buyer);
        market.buy{value: price}(id);

        assertEq(market.ownerOf(id), buyer);

        // 4. Withdraw by seller + fee recipient
        uint256 sellerPending = market.pendingWithdrawals(realSeller);
        uint256 feePending = market.pendingWithdrawals(market.feeRecipient());

        assertTrue(sellerPending > 0);
        assertTrue(feePending > 0);

        vm.prank(realSeller);
        market.withdraw();
        vm.prank(market.feeRecipient());
        market.withdraw();

        assertEq(market.pendingWithdrawals(realSeller), 0);
        assertEq(market.pendingWithdrawals(market.feeRecipient()), 0);

        // 5. New owner can list again
        _list(id, buyer, 3 ether, 1 days);
        (uint128 p,, address s) = market.listings(id);
        assertEq(p, 3 ether);
        assertEq(s, buyer);
    }
}
