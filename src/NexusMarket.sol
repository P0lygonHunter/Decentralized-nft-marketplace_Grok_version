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
 * @title NexusMarket
 * @notice Production-oriented NFT marketplace with:
 *         - EIP-712 signature orders
 *         - Commit-reveal anti-front-running
 *         - ERC-2981 royalties
 *         - Platform fee
 *         - Pull payments
 *         - Emergency pause
 *         - Auto-cancel listing on transfer
 *
 * Security notes (for auditors):
 * - CEI is enforced in _executeSale (balances updated before transfer)
 * - Commitments bind buyer + seller + order data to reduce griefing
 * - Listings are deleted on any transfer (including sales)
 * - Nonces prevent signature replay
 * - Pull pattern for all payouts (no push to untrusted receivers during sale)
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

    // ============ Constants ============

    uint256 private constant MAX_COMMIT_AGE = 1 days;
    uint96 public constant MAX_PLATFORM_FEE = 1000; // 10%
    uint96 public constant MAX_ROYALTY_FEE = 10000; // 100%

    // ============ State ============

    uint256 private _tokenIds;

    uint96 public platformFee;          // basis points (200 = 2%)
    address public feeRecipient;

    struct Listing {
        uint128 price;
        uint64 expiry;
        address seller;
    }

    struct Commit {
        address user;
        uint64 timestamp;
    }

    mapping(uint256 => Listing) public listings;
    mapping(address => uint256) public pendingWithdrawals;

    // Signature nonces (per seller)
    mapping(address => uint256) public nonces;

    // Commit nonces (per buyer) – used in direct-buy commitment
    mapping(address => uint256) public commitNonces;

    // Commitment storage
    mapping(bytes32 => Commit) public commits;

    // ============ EIP-712 ============

    bytes32 private constant ORDER_TYPEHASH =
        keccak256(
            "Order(address buyer,uint256 tokenId,uint256 price,uint256 nonce,uint256 expiry)"
        );

    // ============ Events ============

    event NFTMinted(
        uint256 indexed tokenId,
        address indexed to,
        string uri,
        uint96 royaltyFee
    );

    event Listed(
        uint256 indexed tokenId,
        address indexed seller,
        uint128 price,
        uint64 expiry
    );

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

    /**
     * @notice Owner mints a new NFT with optional royalty.
     * @param to Recipient of the NFT
     * @param uri Token URI
     * @param royaltyFee Royalty in basis points (max 10000)
     */
    function mint(
        address to,
        string memory uri,
        uint96 royaltyFee
    ) external onlyOwner whenNotPaused returns (uint256) {
        require(to != address(0), "Zero address");
        require(royaltyFee <= MAX_ROYALTY_FEE, "Royalty too high");

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

    // ============ Commit (anti-front-running) ============

    /**
     * @notice Commit a hash before buying (commit-reveal).
     * @dev Commitment should bind msg.sender so others cannot grief.
     *      Recommended bindings are produced by the buy / buyWithSig helpers off-chain.
     */
    function commit(bytes32 commitment) external whenNotPaused {
        Commit memory existing = commits[commitment];

        // Allow overwrite only by same user after expiry, or if never used
        require(
            existing.user == address(0) ||
                (existing.user == msg.sender &&
                    block.timestamp > uint256(existing.timestamp) + MAX_COMMIT_AGE),
            "Commit exists or unexpired"
        );

        commits[commitment] = Commit({
            user: msg.sender,
            timestamp: uint64(block.timestamp)
        });

        emit Committed(commitment, msg.sender, uint64(block.timestamp));
    }

    // ============ Listing ============

    /**
     * @notice List an owned NFT for sale.
     */
    function list(
        uint256 tokenId,
        uint128 price,
        uint64 expiry
    ) external whenNotPaused {
        require(ownerOf(tokenId) == msg.sender, "Not owner");
        require(price > 0, "Zero price");
        require(expiry > block.timestamp, "Bad expiry");

        listings[tokenId] = Listing({
            price: price,
            expiry: expiry,
            seller: msg.sender
        });

        emit Listed(tokenId, msg.sender, price, expiry);
    }

    /**
     * @notice Cancel an active listing. Only the current seller can cancel.
     */
    function cancelListing(uint256 tokenId) external whenNotPaused {
        Listing memory l = listings[tokenId];
        require(l.seller == msg.sender, "Not seller");
        require(l.price > 0, "Not listed");

        delete listings[tokenId];
        emit ListingCancelled(tokenId, msg.sender);
    }

    // ============ Buy with Signature (EIP-712) ============

    /**
     * @notice Buy using an off-chain signed order from the current owner.
     * @dev Requires a prior matching commitment.
     */
    function buyWithSig(
        uint256 tokenId,
        uint256 price,
        uint256 expiry,
        uint256 nonce,
        bytes calldata signature
    ) external payable nonReentrant whenNotPaused {
        require(block.timestamp <= expiry, "Order expired");
        require(msg.value >= price, "Insufficient ETH");
        require(price > 0, "Zero price");

        address seller = ownerOf(tokenId);
        require(seller != msg.sender, "Self buy");
        require(seller != address(0), "Token does not exist");

        bytes32 structHash = keccak256(
            abi.encode(
                ORDER_TYPEHASH,
                msg.sender, // buyer is bound in the order
                tokenId,
                price,
                nonce,
                expiry
            )
        );

        bytes32 digest = _hashTypedDataV4(structHash);
        address signer = digest.recover(signature);

        require(signer == seller, "Invalid signer");
        require(nonce == nonces[seller], "Invalid nonce");

        // Effects: consume nonce early
        nonces[seller]++;

        // Stronger commitment binding: buyer + seller + order hash
        bytes32 commitment = keccak256(
            abi.encode(msg.sender, seller, structHash)
        );

        Commit memory c = commits[commitment];
        require(c.user == msg.sender, "Invalid commit");
        require(
            block.timestamp <= uint256(c.timestamp) + MAX_COMMIT_AGE,
            "Commit expired"
        );

        // Effects: consume commit
        delete commits[commitment];
        emit CommitConsumed(commitment, msg.sender);

        // Final ownership check (seller could have transferred after signing)
        require(ownerOf(tokenId) == seller, "Seller no longer owner");

        _executeSale(tokenId, seller, msg.sender, price);

        // Refund excess
        if (msg.value > price) {
            (bool ok, ) = msg.sender.call{value: msg.value - price}("");
            require(ok, "Refund failed");
        }
    }

    // ============ Direct Buy (from on-chain listing) ============

    /**
     * @notice Buy a listed NFT. Requires a prior matching commitment.
     */
    function buy(uint256 tokenId) external payable nonReentrant whenNotPaused {
        Listing memory l = listings[tokenId];

        require(l.price > 0, "Not listed");
        require(block.timestamp <= l.expiry, "Expired");
        require(msg.value >= l.price, "Low ETH");
        require(msg.sender != l.seller, "Self buy");

        // Commitment binds buyer, seller, token, price, buyer nonce, chainid
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
        require(c.user == msg.sender, "Not committer");
        require(
            block.timestamp <= uint256(c.timestamp) + MAX_COMMIT_AGE,
            "Commit expired"
        );

        // Effects first (CEI)
        delete commits[commitment];
        commitNonces[msg.sender]++;
        delete listings[tokenId];

        emit CommitConsumed(commitment, msg.sender);

        // Ownership still belongs to listed seller?
        require(ownerOf(tokenId) == l.seller, "Invalid seller");

        _executeSale(tokenId, l.seller, msg.sender, l.price);

        // Refund excess
        if (msg.value > l.price) {
            (bool ok, ) = msg.sender.call{value: msg.value - l.price}("");
            require(ok, "Refund failed");
        }
    }

    // ============ Internal Sale Logic ============

    /**
     * @dev Accounting first, transfer last (strict CEI).
     *      All payouts go to pendingWithdrawals (pull pattern).
     */
    function _executeSale(
        uint256 tokenId,
        address seller,
        address buyer,
        uint256 amount
    ) internal {
        uint256 platformCut = (amount * platformFee) / 10000;

        // Tiny fee floor so that non-zero platformFee always takes at least 1 wei when amount > 0
        if (amount > 0 && platformCut == 0 && platformFee > 0) {
            platformCut = 1;
        }

        (address royaltyReceiver, uint256 royaltyAmount) = royaltyInfo(tokenId, amount);

        if (royaltyReceiver == address(0)) {
            royaltyAmount = 0;
        }

        // Cap royalty so platform + royalty never exceed amount
        if (platformCut + royaltyAmount > amount) {
            royaltyAmount = amount - platformCut;
        }

        uint256 sellerAmount = amount - platformCut - royaltyAmount;

        // Effects: update balances before any external interaction
        pendingWithdrawals[seller] += sellerAmount;

        if (platformCut > 0) {
            pendingWithdrawals[feeRecipient] += platformCut;
        }

        if (royaltyAmount > 0) {
            pendingWithdrawals[royaltyReceiver] += royaltyAmount;
        }

        // Interaction last
        _transfer(seller, buyer, tokenId);

        emit Sale(
            tokenId,
            seller,
            buyer,
            amount,
            platformCut,
            royaltyAmount
        );
    }

    // ============ Withdraw ============

    /**
     * @notice Withdraw accumulated funds (pull pattern).
     */
    function withdraw() external nonReentrant whenNotPaused {
        uint256 amount = pendingWithdrawals[msg.sender];
        require(amount > 0, "Nothing to withdraw");

        pendingWithdrawals[msg.sender] = 0;

        (bool ok, ) = msg.sender.call{value: amount}("");
        require(ok, "Transfer failed");

        emit Withdrawn(msg.sender, amount);
    }

    // ============ Admin ============

    function setPlatformFee(uint96 fee) external onlyOwner {
        require(fee <= MAX_PLATFORM_FEE, "Too high");
        uint96 old = platformFee;
        platformFee = fee;
        emit PlatformFeeUpdated(old, fee);
    }

    function setFeeRecipient(address to) external onlyOwner {
        require(to != address(0), "Zero address");
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

    // ============ View helpers ============

    function getDigest(bytes32 structHash) public view returns (bytes32) {
        return _hashTypedDataV4(structHash);
    }

    function getOrderStructHash(
        address buyer,
        uint256 tokenId,
        uint256 price,
        uint256 nonce,
        uint256 expiry
    ) public pure returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    ORDER_TYPEHASH,
                    buyer,
                    tokenId,
                    price,
                    nonce,
                    expiry
                )
            );
    }

    /**
     * @notice Helper for frontends to compute the exact commitment used by buy()
     */
    function getDirectBuyCommitment(
        address buyer,
        address seller,
        uint256 tokenId,
        uint128 price,
        uint256 commitNonce
    ) public view returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    buyer,
                    seller,
                    tokenId,
                    price,
                    commitNonce,
                    block.chainid
                )
            );
    }

    /**
     * @notice Helper for frontends to compute the exact commitment used by buyWithSig()
     */
    function getSigBuyCommitment(
        address buyer,
        address seller,
        bytes32 structHash
    ) public pure returns (bytes32) {
        return keccak256(abi.encode(buyer, seller, structHash));
    }

    // ============ Transfer hook – auto cancel listing ============

    function _update(
        address to,
        uint256 tokenId,
        address auth
    ) internal virtual override returns (address) {
        address previousOwner = super._update(to, tokenId, auth);

        // Cancel any listing when token moves (mint/burn excluded by the zero checks)
        if (previousOwner != address(0) && to != address(0)) {
            if (listings[tokenId].price > 0) {
                delete listings[tokenId];
                emit ListingCancelled(tokenId, previousOwner);
            }
        }

        return previousOwner;
    }

    // ============ Interface support ============

    function supportsInterface(
        bytes4 interfaceId
    ) public view override(ERC721URIStorage, ERC2981) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}
