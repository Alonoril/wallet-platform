// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC1271 } from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

contract TestToken is ERC20 {
    mapping(address => bool) public frozen;

    constructor() ERC20("Approved Test Token", "ATT") { }

    function mint(address destination, uint256 amount) external {
        _mint(destination, amount);
    }

    function setFrozen(address holder, bool blocked) external {
        frozen[holder] = blocked;
    }

    function _update(address from, address to, uint256 amount) internal virtual override {
        require(!frozen[from] && !frozen[to], "issuer frozen");
        super._update(from, to, amount);
    }
}

contract TaxToken is TestToken {
    function _update(address from, address to, uint256 amount) internal virtual override {
        if (from != address(0) && to != address(0)) {
            super._update(from, to, amount - amount / 10);
            super._update(from, address(0), amount / 10);
        } else {
            super._update(from, to, amount);
        }
    }
}

contract FalseToken {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address, uint256) external pure returns (bool) {
        return false;
    }
}

contract NoReturnToken {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
    }
}

contract ReturnBombToken {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address, uint256) external pure returns (bool) {
        assembly {
            revert(0, 0x10000)
        }
    }
}

/// @dev Test-only council, NOT a production multisig. Production uses independently managed Safe/ERC-1271.
contract TestCouncil is IERC1271 {
    address public immutable owner;

    constructor(address owner_) {
        owner = owner_;
    }

    function isValidSignature(bytes32 digest, bytes memory signature) external view returns (bytes4) {
        return ECDSA.recover(digest, signature) == owner
            ? IERC1271.isValidSignature.selector
            : bytes4(0xffffffff);
    }

    receive() external payable { }
}

contract RejectNative {
    receive() external payable {
        revert("reject");
    }
}

contract ReentrantRecipient {
    address public target;
    bytes public payload;
    bool public reentrySucceeded;

    function configure(address target_, bytes calldata payload_) external {
        target = target_;
        payload = payload_;
    }

    receive() external payable {
        (reentrySucceeded,) = target.call(payload);
    }
}
