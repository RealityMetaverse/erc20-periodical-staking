// SPDX-License-Identifier: BUSL-1.1
// Copyright 2024 Reality Metaverse
pragma solidity 0.8.20;

library ArrayLibrary {
    function findElementIndex(uint256[] storage targetArray, uint256 targetElement) internal view returns (uint256) {
        for (uint256 i = 0; i < targetArray.length; i++) {
            if (targetArray[i] == targetElement) return i;
        }
        return targetArray.length;
    }

    function removeElementByIndex(uint256[] storage targetArray, uint256 elementIndex) internal {
        if (elementIndex < targetArray.length - 1) {
            for (uint256 i = elementIndex; i < targetArray.length - 1; i++) {
                targetArray[i] = targetArray[i + 1];
            }
        }
        targetArray.pop();
    }

    function sortStorage(uint256[] storage targetArray) public {
        uint256 arrayLength = targetArray.length;
        if (arrayLength <= 1) return;

        uint256 lastElement = targetArray[arrayLength - 1];
        int256 i = int256(arrayLength) - 2;
        while (i >= 0 && targetArray[uint256(i)] > lastElement) {
            targetArray[uint256(i + 1)] = targetArray[uint256(i)];
            i--;
        }

        targetArray[uint256(i + 1)] = lastElement;
    }
}
