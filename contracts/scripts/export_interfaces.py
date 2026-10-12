#!/usr/bin/env python3
"""Export compiled v2 ABIs and EIP-712 vectors; only the Python stdlib and pinned cast are needed."""

import json
from pathlib import Path
import re
import subprocess


ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "interfaces"
CONTRACTS = (
    "TenantAuthority", "TenantTimelock", "RiskRegistry", "DepositFactory", "DepositVault",
    "HotPoolManager", "HotVault", "MilonWithdrawalVerifier", "WithdrawalBook",
)


def keccak(content: bytes) -> bytes:
    result = subprocess.run(
        ["rtk", "proxy", "cast", "keccak", "0x" + content.hex()],
        check=True, capture_output=True, text=True,
    )
    return bytes.fromhex(result.stdout.strip().removeprefix("0x"))


def word(kind: str, value: str | int) -> bytes:
    if kind == "bytes32":
        encoded = bytes.fromhex(str(value).removeprefix("0x"))
        if len(encoded) != 32:
            raise ValueError("bytes32 has incorrect length")
        return encoded
    if kind == "address":
        return int(str(value), 16).to_bytes(32, "big")
    if kind.startswith("uint"):
        integer = int(value)
        if not 0 <= integer < 2 ** int(kind[4:]):
            raise ValueError("unsigned integer exceeds declared bit width")
        return integer.to_bytes(32, "big")
    raise ValueError(f"unsupported vector field: {kind}")


def sample(kind: str, name: str, primary: str) -> str:
    if kind == "bytes32":
        return "0x" + keccak(("wallet-v2-vector:" + name).encode()).hex()
    if kind == "address":
        return "0x" + ("00" if name == "token" else "22") * 20
    values = {
        "amount": 12345678, "assetStateNonce": 7, "userSignerEpoch": 2, "refundSignerEpoch": 3,
        "validAfter": 1700000000, "deadline": 1700000300, "observedAt": 1699990000,
        "expectedBalance": 99999999, "sourceChainId": 567, "approvedHeight": 111,
        "action": 2 if primary == "CancellationAttestation" else 1,
    }
    return str(values.get(name, 1))


def domain_name(primary: str) -> str:
    if primary in ("WalletBinding", "UserSignerRotation"):
        return "DepositFactory"
    if primary in ("RefundPermit", "SweepPermit", "SourceAllocation"):
        return "DepositVault"
    if primary in ("WithdrawalPermit", "MovementPermit"):
        return "HotVault"
    return "WithdrawalBook" if primary == "CancelPermit" else "MilonWithdrawalVerifier"


def main() -> None:
    (OUTPUT / "abi").mkdir(parents=True, exist_ok=True)
    for contract in CONTRACTS:
        artifact = json.loads((ROOT / "out" / f"{contract}.sol" / f"{contract}.json").read_text())
        (OUTPUT / "abi" / f"{contract}.json").write_text(json.dumps(artifact["abi"], indent=2) + "\n")

    source = (ROOT / "src/common/PermitHash.sol").read_text()
    declarations = re.findall(r'bytes32 internal constant \w+\s*=\s*keccak256\(\s*"([^"]+)"\s*\);', source)
    types = {}
    vectors = {}
    for declaration in declarations:
        primary, body = declaration.split("(", 1)
        fields = [{"name": field.split()[1], "type": field.split()[0]} for field in body[:-1].split(",")]
        types[primary] = fields
        message = {field["name"]: sample(field["type"], field["name"], primary) for field in fields}
        encoded = b"".join(word(field["type"], message[field["name"]]) for field in fields)
        type_hash = keccak(declaration.encode())
        struct_hash = keccak(type_hash + encoded)
        name = domain_name(primary)
        domain_type = b"EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
        domain_separator = keccak(keccak(domain_type) + keccak(name.encode()) + keccak(b"2")
            + word("uint256", 31337) + word("address", "0x" + "11" * 20))
        vectors[primary] = {
            "domain": {"name": name, "version": "2", "chainId": "31337", "verifyingContract": "0x" + "11" * 20},
            "message": message, "typeString": declaration, "typeHash": "0x" + type_hash.hex(),
            "encodedValue": "0x" + encoded.hex(), "structHash": "0x" + struct_hash.hex(),
            "domainSeparator": "0x" + domain_separator.hex(),
            "digest": "0x" + keccak(b"\x19\x01" + domain_separator + struct_hash).hex(),
        }
    protocol = {
        "protocolVersion": "2", "signatureFormat": "EOA/committee: 65 bytes r || s || v, low-s, v=27/28; ERC1271: account-defined authorization bytes",
        "refund": "user signature AND distinct REFUND_SIGNER signature over the identical RefundPermit digest",
        "certificateEncoding": "abi.encode(WithdrawalAttestation or CancellationAttestation, bytes[] sortedSignatures)",
        "sourceAllocationArrayHash": "keccak256(concat(each SourceAllocation structHash))",
        "domains": {primary: domain_name(primary) for primary in types if primary != "SourceAllocation"},
        "types": types,
        "idDomains": {name: "0x" + keccak(name.encode()).hex() for name in (
            "CHAIN_V1", "WALLET_V1", "ASSET_V1", "DEPOSIT_V1", "REFUND_V1", "MOVE_V1")},
        "evmNamespace": "0x" + keccak(b"eip155").hex(),
        "nativeToken": "0x" + "00" * 20, "locatorKindLog": 1,
    }
    (OUTPUT / "eip712.json").write_text(json.dumps(protocol, indent=2) + "\n")
    (OUTPUT / "vectors.json").write_text(json.dumps(vectors, indent=2) + "\n")
    print(f"Exported {len(CONTRACTS)} ABIs and {len(types)} EIP-712 type/vector definitions.")


if __name__ == "__main__":
    main()
