// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC1271 } from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/// @notice 仅供测试的 ERC20，可模拟发行方冻结、转账税及外部直接转入；不用于真实部署。
contract MockToken is ERC20 {
    mapping(address => bool) public blocked;
    bool public taxed;

    constructor() ERC20("Test USD", "TUSD") { }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setBlocked(address account, bool value) external {
        blocked[account] = value;
    }

    function setTaxed(bool value) external {
        taxed = value;
    }

    function _update(address from, address to, uint256 amount) internal override {
        require(!blocked[from] && !blocked[to], "issuer frozen");
        uint256 tax = taxed && from != address(0) && to != address(0) ? amount / 100 : 0;
        if (tax != 0) super._update(from, address(0), tax);
        super._update(from, to, amount - tax);
    }
}

/// @notice 用合成密钥模拟用户智能账户或独立 Council 的 ERC1271 验签，避免使用真实凭据。
contract MockSigner is IERC1271 {
    address public immutable owner;

    constructor(address signer) {
        owner = signer;
    }

    function isValidSignature(bytes32 digest, bytes calldata signature) external view returns (bytes4) {
        (address signer, ECDSA.RecoverError error,) = ECDSA.tryRecover(digest, signature);
        return error == ECDSA.RecoverError.NoError && signer == owner
            ? IERC1271.isValidSignature.selector
            : bytes4(0xffffffff);
    }
}

/// @notice 回调时尝试重入指定业务，用于验证重复付款和 nonce 消费保护。
contract ReenteringRecipient {
    address public target;
    bytes public payload;
    bool public attempted;
    bool public succeeded;

    function arm(address nextTarget, bytes calldata nextPayload) external {
        target = nextTarget;
        payload = nextPayload;
    }

    receive() external payable {
        attempted = true;
        (succeeded,) = target.call(payload);
    }
}

/// @notice 模拟拒收原生币的外部地址，验证资金转账失败时订单、预算与 nonce 均回滚。
contract RejectingRecipient {
    receive() external payable {
        revert("reject native");
    }
}
