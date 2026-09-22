// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/token/common/ERC2981.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * @title NexusMarket (Upgraded Grok Version - Production Hardened)
 * @notice Single-collection NFT marketplace with advanced security features.
 *
 * RETAINED FROM ORIGINAL GROK VERSION:
 *  - Built-in minting + ERC-2981 royalties
 *  - Commit-reveal anti-front-running
 *  - Auto-cancel listing on any transfer
 *  - Pull payments + strict CEI
 *
 * ADDED / FIXED FROM NEW MARKETPLACE REVIEW:
 *  - Withdraw ALWAYS available even when paused (critical fix)
 *  - Seaport-style cancelAllOrders() via counter
 *  - Individual cancelOrder(nonce)
 *  - usedNonces mapping for precise replay protection
 *  - Post-transfer ownership recheck after sale
 *  - Custom errors (gas efficient + clear)
 *  - Stronger royalty edge-case handling
 *  - Better view helpers
 *
 * This remains SINGLE-COLLECTION (not multi-collection / non-custodial).
 */
contract NexusMarket is
    ERC721URIStorage,
    ERC2981,
    EIP712,
    ReentrancyGuard,
    Ownable,
    Pausable
{
    using ECDSA for bytes32;

    // ============ Custom Errors ============
    error ZeroAddress();
    error ZeroPrice();
    error BadExpiry();
    error NotOwner();
    error NotSeller();
    error NotListed();
    error SelfBuy();
    error InsufficientETH();
    error OrderExpired();
    error InvalidSigner();
    error InvalidNonce();
    error CommitExistsOrUnexpired();
    error InvalidCommit();
    error CommitExpired();
    error SellerNoLongerOwner();
    error NothingToWithdraw();
    error TransferFailed();
    error RoyaltyTooHigh();
    error FeeTooHigh();
    error TokenDoesNotExist();

    // ============ Constants ============
    uint256 private constant MAX_COMMIT_AGE = 1 days;
    uint96  public constant MAX_PLATFORM_FEE = 1000; // 10%
    uint96  public constant MAX_ROYALTY_FEE  = 10000; // 100%

    // ============ State ============
    uint256 private _tokenIds;

    uint96  public platformFee;
    address public feeRecipient;

    struct Listing {
        uint128 price;
        uint64  expiry;
        address seller;
    }

    struct Commit {
        address user;
        uint64  timestamp;
    }

    mapping(uint256 => Listing) public listings;
    mapping(address => uint256) public pendingWithdrawals;

    // Precise nonce tracking (seller => nonce => used)
    mapping(address => mapping(uint256 => bool)) public usedNonces;
    // Seaport-style bulk cancel
    mapping(address => uint256) public counters;

    mapping(address => uint256) public commitNonces;
    mapping(bytes32 => Commit)  public commits;

    // ============ EIP-712 ============
    bytes32 private constant ORDER_TYPEHASH =
        keccak256(
            "Order(address buyer,uint256 tokenId,uint256 price,uint256 nonce,uint256 expiry,uint256 counter)"
        );

    // ============ Events ============
    event NFTMinted(uint256 indexed tokenId, address indexed to, string uri, uint96 royaltyFee);
    event Listed(uint256 indexed tokenId, address indexed seller, uint128 price, uint64 expiry);
    event ListingCancelled(uint256 indexed tokenId, address indexed seller);
    event Sale(
        uint256 indexed tokenId,
        address indexed seller,
        address indexed buyer,
        uint256 price,
        uint256 platformCut,
        uint256 royaltyAmount
    );
    event Committed(bytes32 indexed commitment, address indexed user, uint64 timestamp);
    event CommitConsumed(bytes32 indexed commitment, address indexed user);
    event OrderCancelled(address indexed seller, uint256 nonce);
    event CounterIncremented(address indexed seller, uint256 newCounter);
    event Withdrawn(address indexed account, uint256 amount);
    event PlatformFeeUpdated(uint96 oldFee, uint96 newFee);
    event FeeRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);

    // ============ Constructor ============
    constructor()
        ERC721("NexusMarket", "NEX")
        EIP712("NexusMarket", "1")
        Ownable(msg.sender)
    {
        platformFee = 200; // 2%
        feeRecipient = msg.sender;
    }

    // ============ Mint ============
    function mint(address to, string memory uri, uint96 royaltyFee)
        external
        onlyOwner
        whenNotPaused
        returns (uint256)
    {
        if (to == address(0)) revert ZeroAddress();
        if (royaltyFee > MAX_ROYALTY_FEE) revert RoyaltyTooHigh();

        _tokenIds++;
        uint256 id = _tokenIds;

        _safeMint(to, id);
        _setTokenURI(id, uri);

        if (royaltyFee > 0) {
            _setTokenRoyalty(id, to, royaltyFee);
        }

        emit NFTMinted(id, to, uri, royaltyFee);
        return id;
    }

    // ============ Commit-Reveal ============
    function commit(bytes32 commitment) external whenNotPaused {
        Commit memory existing = commits[commitment];

        if (
            existing.user != address(0) &&
            !(existing.user == msg.sender && block.timestamp > uint256(existing.timestamp) + MAX_COMMIT_AGE)
        ) {
            revert CommitExistsOrUnexpired();
        }

        commits[commitment] = Commit({
            user: msg.sender,
            timestamp: uint64(block.timestamp)
        });

        emit Committed(commitment, msg.sender, uint64(block.timestamp));
    }

    // ============ Listing ============
    function list(uint256 tokenId, uint128 price, uint64 expiry) external whenNotPaused {
        if (ownerOf(tokenId) != msg.sender) revert NotOwner();
        if (price == 0) revert ZeroPrice();
        if (expiry <= block.timestamp) revert BadExpiry();

        listings[tokenId] = Listing({
            price: price,
            expiry: expiry,
            seller: msg.sender
        });

        emit Listed(tokenId, msg.sender, price, expiry);
    }

    function cancelListing(uint256 tokenId) external {
        Listing memory l = listings[tokenId];
        if (l.seller != msg.sender) revert NotSeller();
        if (l.price == 0) revert NotListed();

        delete listings[tokenId];
        emit ListingCancelled(tokenId, msg.sender);
    }

    // ============ Direct Buy ============
    function buy(uint256 tokenId) external payable nonReentrant whenNotPaused {
        Listing memory l = listings[tokenId];

        if (l.price == 0) revert NotListed();
        if (block.timestamp > l.expiry) revert OrderExpired();
        if (msg.value < l.price) revert InsufficientETH();
        if (msg.sender == l.seller) revert SelfBuy();

        bytes32 commitment = keccak256(
            abi.encode(
                msg.sender,
                l.seller,
                tokenId,
                l.price,
                commitNonces[msg.sender],
                block.chainid
            )
        );

        Commit memory c = commits[commitment];
        if (c.user != msg.sender) revert InvalidCommit();
        if (block.timestamp > uint256(c.timestamp) + MAX_COMMIT_AGE) revert CommitExpired();

        // Effects
        delete commits[commitment];
        commitNonces[msg.sender]++;
        delete listings[tokenId];
        emit CommitConsumed(commitment, msg.sender);

        if (ownerOf(tokenId) != l.seller) revert SellerNoLongerOwner();

        _executeSale(tokenId, l.seller, msg.sender, l.price);

        if (msg.value > l.price) {
            (bool ok, ) = msg.sender.call{value: msg.value - l.price}("");
            if (!ok) revert TransferFailed();
        }
    }

    // ============ Signature Buy ============
    function buyWithSig(
        uint256 tokenId,
        uint256 price,
        uint256 expiry,
        uint256 nonce,
        bytes calldata signature
    ) external payable nonReentrant whenNotPaused {
        if (block.timestamp > expiry) revert OrderExpired();
        if (msg.value < price) revert InsufficientETH();
        if (price == 0) revert ZeroPrice();

        address seller = ownerOf(tokenId);
        if (seller == msg.sender) revert SelfBuy();
        if (seller == address(0)) revert TokenDoesNotExist();

        uint256 currentCounter = counters[seller];

        bytes32 structHash = keccak256(
            abi.encode(
                ORDER_TYPEHASH,
                msg.sender,
                tokenId,
                price,
                nonce,
                expiry,
                currentCounter
            )
        );

        bytes32 digest = _hashTypedDataV4(structHash);
        address signer = digest.recover(signature);

        if (signer != seller) revert InvalidSigner();
        if (usedNonces[seller][nonce]) revert InvalidNonce();

        usedNonces[seller][nonce] = true;

        bytes32 commitment = keccak256(abi.encode(msg.sender, seller, structHash));

        Commit memory c = commits[commitment];
        if (c.user != msg.sender) revert InvalidCommit();
        if (block.timestamp > uint256(c.timestamp) + MAX_COMMIT_AGE) revert CommitExpired();

        delete commits[commitment];
        emit CommitConsumed(commitment, msg.sender);

        if (ownerOf(tokenId) != seller) revert SellerNoLongerOwner();

        _executeSale(tokenId, seller, msg.sender, price);

        if (msg.value > price) {
            (bool ok, ) = msg.sender.call{value: msg.value - price}("");
            if (!ok) revert TransferFailed();
        }
    }

    // ============ Signed Order Cancellation (New features) ============
    function cancelOrder(uint256 nonce) external {
        usedNonces[msg.sender][nonce] = true;
        emit OrderCancelled(msg.sender, nonce);
    }

    function cancelAllOrders() external {
        counters[msg.sender]++;
        emit CounterIncremented(msg.sender, counters[msg.sender]);
    }

    // ============ Internal Sale (strict CEI + post-check) ============
    function _executeSale(
        uint256 tokenId,
        address seller,
        address buyer,
        uint256 amount
    ) internal {
        uint256 platformCut = (amount * platformFee) / 10000;

        if (amount > 0 && platformCut == 0 && platformFee > 0) {
            platformCut = 1;
        }

        (address royaltyReceiver, uint256 royaltyAmount) = royaltyInfo(tokenId, amount);

        if (royaltyReceiver == address(0)) {
            royaltyAmount = 0;
        }

        if (platformCut + royaltyAmount > amount) {
            royaltyAmount = amount - platformCut;
        }

        uint256 sellerAmount = amount - platformCut - royaltyAmount;

        // Effects
        pendingWithdrawals[seller] += sellerAmount;
        if (platformCut > 0) {
            pendingWithdrawals[feeRecipient] += platformCut;
        }
        if (royaltyAmount > 0) {
            pendingWithdrawals[royaltyReceiver] += royaltyAmount;
        }

        // Interaction
        _transfer(seller, buyer, tokenId);

        // Defensive post-transfer check
        if (ownerOf(tokenId) != buyer) revert SellerNoLongerOwner();

        emit Sale(tokenId, seller, buyer, amount, platformCut, royaltyAmount);
    }

    // ============ Withdraw – ALWAYS available (even paused) ============
    function withdraw() external nonReentrant {
        uint256 amount = pendingWithdrawals[msg.sender];
        if (amount == 0) revert NothingToWithdraw();

        pendingWithdrawals[msg.sender] = 0;

        (bool ok, ) = msg.sender.call{value: amount}("");
        if (!ok) revert TransferFailed();

        emit Withdrawn(msg.sender, amount);
    }

    // ============ Admin ============
    function setPlatformFee(uint96 fee) external onlyOwner {
        if (fee > MAX_PLATFORM_FEE) revert FeeTooHigh();
        uint96 old = platformFee;
        platformFee = fee;
        emit PlatformFeeUpdated(old, fee);
    }

    function setFeeRecipient(address to) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        address old = feeRecipient;
        feeRecipient = to;
        emit FeeRecipientUpdated(old, to);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // ============ View Helpers ============
    function getDigest(bytes32 structHash) public view returns (bytes32) {
        return _hashTypedDataV4(structHash);
    }

    function getOrderStructHash(
        address buyer,
        uint256 tokenId,
        uint256 price,
        uint256 nonce,
        uint256 expiry,
        uint256 counter
    ) public pure returns (bytes32) {
        return keccak256(
            abi.encode(ORDER_TYPEHASH, buyer, tokenId, price, nonce, expiry, counter)
        );
    }

    function getDirectBuyCommitment(
        address buyer,
        address seller,
        uint256 tokenId,
        uint128 price,
        uint256 commitNonce
    ) public view returns (bytes32) {
        return keccak256(
            abi.encode(buyer, seller, tokenId, price, commitNonce, block.chainid)
        );
    }

    function getSigBuyCommitment(
        address buyer,
        address seller,
        bytes32 structHash
    ) public pure returns (bytes32) {
        return keccak256(abi.encode(buyer, seller, structHash));
    }

    // ============ Transfer Hook ============
    function _update(address to, uint256 tokenId, address auth)
        internal
        virtual
        override
        returns (address)
    {
        address previousOwner = super._update(to, tokenId, auth);

        if (previousOwner != address(0) && to != address(0)) {
            if (listings[tokenId].price > 0) {
                delete listings[tokenId];
                emit ListingCancelled(tokenId, previousOwner);
            }
        }

        return previousOwner;
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721URIStorage, ERC2981)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
