// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/NexusMarket.sol";

/**
 * @title NexusMarketFuzzTest
 * @notice Fuzz tests – random inputs se edge cases dhoondhne ke liye.
 *         Ye intentionally aggressive hain taake real bugs nikal sakein.
 */
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

    // ============ Fuzz: Mint ============

    function testFuzz_Mint_RoyaltyBounded(uint96 royalty) public {
        royalty = uint96(bound(royalty, 0, 10000));

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
        vm.assume(royalty > 10000);

        vm.prank(owner);
        vm.expectRevert("Royalty too high");
        market.mint(seller, "ipfs://fuzz", royalty);
    }

    // ============ Fuzz: List ============

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

    function testFuzz_List_RejectsZeroPrice(uint64 duration) public {
        duration = uint64(bound(duration, 1, 365 days));

        vm.prank(owner);
        uint256 id = market.mint(seller, "ipfs://fuzz", 0);

        vm.prank(seller);
        vm.expectRevert("Zero price");
        market.list(id, 0, uint64(block.timestamp + duration));
    }

    // ============ Fuzz: Direct Buy ============

    function testFuzz_Buy_Success(uint128 price, uint96 royalty) public {
        price = uint128(bound(price, 1e15, 50 ether)); // 0.001 ETH – 50 ETH
        royalty = uint96(bound(royalty, 0, 2000));     // max 20%

        vm.prank(owner);
        uint256 id = market.mint(seller, "ipfs://fuzz", royalty);

        vm.prank(seller);
        market.list(id, price, uint64(block.timestamp + 1 days));

        uint256 nonce = market.commitNonces(buyer);
        bytes32 commitment = market.getDirectBuyCommitment(
            buyer,
            seller,
            id,
            price,
            nonce
        );

        vm.prank(buyer);
        market.commit(commitment);

        uint256 balBefore = buyer.balance;

        vm.prank(buyer);
        market.buy{value: price}(id);

        assertEq(market.ownerOf(id), buyer);
        assertEq(buyer.balance, balBefore - price);

        // Accounting sanity
        uint256 platformCut = (uint256(price) * market.platformFee()) / 10000;
        if (price > 0 && platformCut == 0 && market.platformFee() > 0) {
            platformCut = 1;
        }

        (address royaltyRecv, uint256 royaltyAmount) = market.royaltyInfo(id, price);
        if (royaltyRecv == address(0)) royaltyAmount = 0;
        if (platformCut + royaltyAmount > price) {
            royaltyAmount = price - platformCut;
        }

        uint256 sellerAmount = price - platformCut - royaltyAmount;

        assertEq(market.pendingWithdrawals(seller), sellerAmount + (royaltyRecv == seller ? royaltyAmount : 0));
        assertEq(market.pendingWithdrawals(market.feeRecipient()), platformCut);
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

        vm.prank(buyer);
        vm.expectRevert("Low ETH");
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
        vm.expectRevert("Commit expired");
        market.buy{value: price}(id);
    }

    // ============ Fuzz: Signature Buy ============

    function testFuzz_BuyWithSig_Success(uint128 price, uint256 duration) public {
        price = uint128(bound(price, 1e15, 20 ether));
        duration = bound(duration, 1 hours, 7 days);

        vm.prank(owner);
        uint256 id = market.mint(seller, "ipfs://fuzz", 500);

        uint256 nonce = market.nonces(seller);
        uint256 expiry = block.timestamp + duration;

        bytes32 structHash = market.getOrderStructHash(buyer, id, price, nonce, expiry);
        bytes32 digest = market.getDigest(structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(sellerPk, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        bytes32 commitment = market.getSigBuyCommitment(buyer, seller, structHash);

        vm.prank(buyer);
        market.commit(commitment);

        vm.prank(buyer);
        market.buyWithSig{value: price}(id, price, expiry, nonce, sig);

        assertEq(market.ownerOf(id), buyer);
        assertEq(market.nonces(seller), nonce + 1);
    }

    function testFuzz_BuyWithSig_RejectsBadNonce(uint128 price, uint256 badNonce) public {
        price = uint128(bound(price, 1e15, 5 ether));
        uint256 realNonce = market.nonces(seller);
        vm.assume(badNonce != realNonce);

        vm.prank(owner);
        uint256 id = market.mint(seller, "ipfs://fuzz", 0);

        uint256 expiry = block.timestamp + 1 days;

        bytes32 structHash = market.getOrderStructHash(buyer, id, price, badNonce, expiry);
        bytes32 digest = market.getDigest(structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(sellerPk, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        bytes32 commitment = market.getSigBuyCommitment(buyer, seller, structHash);

        vm.prank(buyer);
        market.commit(commitment);

        vm.prank(buyer);
        vm.expectRevert("Invalid nonce");
        market.buyWithSig{value: price}(id, price, expiry, badNonce, sig);
    }

    // ============ Fuzz: Platform fee + accounting ============

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

        vm.prank(buyer);
        market.buy{value: price}(id);

        uint256 platformPending = market.pendingWithdrawals(market.feeRecipient());
        uint256 sellerPending = market.pendingWithdrawals(seller);

        assertLe(platformPending, price);
        assertEq(platformPending + sellerPending, price);
    }

    // ============ Fuzz: Commit overwrite rules ============

    function testFuzz_Commit_CannotBeStolen(bytes32 commitment) public {
        vm.prank(buyer);
        market.commit(commitment);

        // Attacker tries to overwrite
        vm.prank(attacker);
        vm.expectRevert("Commit exists or unexpired");
        market.commit(commitment);
    }

    function testFuzz_Commit_OwnerCanOverwriteAfterExpiry(bytes32 commitment, uint256 extraTime) public {
        extraTime = bound(extraTime, 1, 30 days);

        vm.prank(buyer);
        market.commit(commitment);

        vm.warp(block.timestamp + 1 days + extraTime);

        // Same user can overwrite
        vm.prank(buyer);
        market.commit(commitment);
    }
}
