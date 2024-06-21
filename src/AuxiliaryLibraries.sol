// SPDX-License-Identifier: BUSL-1.1
// Copyright 2024 Reality Metaverse
pragma solidity 0.8.20;

library ArrayLibrary {
    function findElementIndex(uint256[] storage targetArray, uint256 targetElement) internal view returns (uint256) {
        for (uint256 i = 0; i < targetArray.length; i++) {
            if (targetArray[i] == targetElement) return i;
        }
    }

    function removeElementByIndex(uint256[] storage targetArray, uint256 elementIndex) internal {
        if (elementIndex < targetArray.length - 1) {
            for (uint256 i = elementIndex; i < targetArray.length - 1; i++) {
                targetArray[i] = targetArray[i + 1];
            }
        }
        targetArray.pop();
    }

    function sortMemory(uint256[] memory targetArray) public pure {
        uint256 n = targetArray.length;
        for (uint256 i = 0; i < n - 1; i++) {
            for (uint256 j = 0; j < n - i - 1; j++) {
                if (targetArray[j] > targetArray[j + 1]) {
                    (targetArray[j], targetArray[j + 1]) = (targetArray[j + 1], targetArray[j]);
                }
            }
        }
    }

    function sortStorage(uint256[] storage targetArray) public {
        uint256 n = targetArray.length;
        for (uint256 i = 0; i < n - 1; i++) {
            for (uint256 j = 0; j < n - i - 1; j++) {
                if (targetArray[j] > targetArray[j + 1]) {
                    (targetArray[j], targetArray[j + 1]) = (targetArray[j + 1], targetArray[j]);
                }
            }
        }
    }

    function hasRepetitions(uint256[] memory targetArray) public pure returns (bool) {
        for (uint256 i = 0; i < targetArray.length; i++) {
            for (uint256 j = i + 1; j < targetArray.length; j++) {
                if (targetArray[i] == targetArray[j]) return true;
            }
        }
        return false;
    }
}
