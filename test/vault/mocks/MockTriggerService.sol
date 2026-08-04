// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {ITriggerReceiver} from "../../../src/vault/flap/IFlapTriggerService.sol";

/// @title MockTriggerService
/// @notice Stand-in for the Flap Trigger Service (`IFlapTriggerService`) used by the vault's scheduling
///         tests. Mirrors the parts the vault depends on:
///           • `getFee()` — a settable, LIVE-read fee; `requestTrigger` requires `msg.value >= fee`.
///           • `getMaxCallbackGas()` — the service's hard callback budget (2,000,000 on the real service).
///           • `requestTrigger(executeAfter)` — hands out monotonically increasing ids from 1 and records
///             the requester, so the callback can be driven back at exactly that address.
///           • `fire(requestId)` — test-only driver standing in for the backend: invokes the requester's
///             `trigger(requestId)` under the SAME bounded gas limit the real service applies, so a
///             callback that would blow the 2M budget fails here too rather than passing silently.
contract MockTriggerService {
    struct Req {
        address requester;
        uint64 executeAfter;
        bool executed;
    }

    /// @notice Fee returned by {getFee}; settable so tests can exercise the shortfall path.
    uint256 public fee = 0.001 ether;
    /// @notice Callback gas budget; defaults to the real service's 2,000,000 hard cap.
    uint256 public maxCallbackGas = 2_000_000;

    uint256 public requestCount;
    mapping(uint256 => Req) public requests;

    /// @notice Total fees collected — lets a test assert the vault actually paid.
    uint256 public feesCollected;

    /// @notice Gas consumed by the most recent {fire} callback (excludes the outer call overhead).
    uint256 public lastCallbackGasUsed;
    /// @notice Whether the most recent {fire} callback succeeded.
    bool public lastCallbackOk;

    function setFee(uint256 f) external {
        fee = f;
    }

    function setMaxCallbackGas(uint256 g) external {
        maxCallbackGas = g;
    }

    function getFee() external view returns (uint256) {
        return fee;
    }

    function getMaxCallbackGas() external view returns (uint256) {
        return maxCallbackGas;
    }

    /// @notice Mirror of the real `requestTrigger`: charge the fee, record the request, return a fresh id.
    /// @dev    Ids start at 1. The vault must NOT rely on that (it tracks a separate `triggerPending`
    ///         flag), but starting at 1 keeps the mock closer to a typical implementation.
    function requestTrigger(uint64 executeAfter) external payable returns (uint256 requestId) {
        require(msg.value >= fee, "MockTriggerService: fee");
        feesCollected += msg.value;
        requestId = ++requestCount;
        requests[requestId] = Req({requester: msg.sender, executeAfter: executeAfter, executed: false});
    }

    /// @notice Test-only backend driver: run the requester's callback under the service's gas cap.
    /// @dev    Uses a low-level call so a reverting or out-of-gas callback is observable (mirroring the
    ///         real service recording FAILED) instead of bubbling up and failing the whole test.
    function fire(uint256 requestId) external returns (bool ok) {
        Req storage r = requests[requestId];
        require(r.requester != address(0), "MockTriggerService: bad id");
        require(!r.executed, "MockTriggerService: executed");
        require(block.timestamp >= r.executeAfter, "MockTriggerService: too early");
        r.executed = true;

        uint256 before = gasleft();
        (ok,) = r.requester.call{gas: maxCallbackGas}(abi.encodeCall(ITriggerReceiver.trigger, (requestId)));
        lastCallbackGasUsed = before - gasleft();
        lastCallbackOk = ok;
    }

    receive() external payable {}
}
