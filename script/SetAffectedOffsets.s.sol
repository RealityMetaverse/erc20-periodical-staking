// SPDX-License-Identifier: MIT
// Copyright 2026 Reality Metaverse
pragma solidity 0.8.20;

import {Script} from "forge-std/Script.sol";

interface IRequirementCheckerV2 {
    function setPeriodicalStakingOffsetBatch(
        address[] calldata wallets,
        address[] calldata periodicalStakingContracts_,
        int256[] calldata offsets
    ) external;
}

/// @notice Applies negative periodical-staking offsets on RequirementCheckerV2 for every wallet
///         affected by the stuck-deposit incident (see README "Known Issues"). Offsets equal
///         the sum of the wallet's affected principal (not reward), scaled by 1e18.
contract SetAffectedOffsets is Script {
    address constant REQUIREMENT_CHECKER_V2 = 0x716ff1f64cC2B7c96ba9DDADfc08bB703F8bcA59;
    address constant PERIODICAL_STAKING     = 0xa816fC819c2BD73c0AEdf60E0b06daF2Bff9691F;

    uint256 constant COUNT = 71;

    function run() external {
        address[] memory wallets = new address[](COUNT);
        address[] memory stakingContracts = new address[](COUNT);
        int256[] memory offsets = new int256[](COUNT);

        wallets[0]          = 0xcE043A2c3572C111fc3E2e660600c6f83f98Cc74;
        stakingContracts[0] = PERIODICAL_STAKING;
        offsets[0]          = -int256(uint256(1000000000000000000000000)); // -1,000,000.00

        wallets[1]          = 0x5eFF5EB03d495904CB1fc318E3Fdf91f56b68295;
        stakingContracts[1] = PERIODICAL_STAKING;
        offsets[1]          = -int256(uint256(1000000000000000000000000)); // -1,000,000.00

        wallets[2]          = 0x47cABbA9ABf3Ff8a9dDe2Ac3675aB6E029C652c9;
        stakingContracts[2] = PERIODICAL_STAKING;
        offsets[2]          = -int256(uint256(623200000000000000000000)); // -623,200.00

        wallets[3]          = 0x06f860b593e509E3FF0617859418D2F99495eA81;
        stakingContracts[3] = PERIODICAL_STAKING;
        offsets[3]          = -int256(uint256(1000000000000000000000000)); // -1,000,000.00

        wallets[4]          = 0x2eb52d6c72919246d7370e16267F9DDE7CDcFCaa;
        stakingContracts[4] = PERIODICAL_STAKING;
        offsets[4]          = -int256(uint256(1000000000000000000000000)); // -1,000,000.00

        wallets[5]          = 0x986b088F2874FeC553f05644Aa22c4b0239d54e5;
        stakingContracts[5] = PERIODICAL_STAKING;
        offsets[5]          = -int256(uint256(1000000000000000000000000)); // -1,000,000.00

        wallets[6]          = 0x2Cb558577Ba4C70752F65B71188e6563e725E0a5;
        stakingContracts[6] = PERIODICAL_STAKING;
        offsets[6]          = -int256(uint256(443060270000000000000000)); // -443,060.27

        wallets[7]          = 0xF7E482d5e2a72CA9E1E17945192a83E81f4BfE71;
        stakingContracts[7] = PERIODICAL_STAKING;
        offsets[7]          = -int256(uint256(461000000000000000000000)); // -461,000.00

        wallets[8]          = 0xB322De242318f10b70959ACfc676e7a9e6056482;
        stakingContracts[8] = PERIODICAL_STAKING;
        offsets[8]          = -int256(uint256(1000000000000000000000000)); // -1,000,000.00

        wallets[9]          = 0x66e7315e8470CFDCe48059882eBb867Fd19920f6;
        stakingContracts[9] = PERIODICAL_STAKING;
        offsets[9]          = -int256(uint256(662500000000000000000000)); // -662,500.00

        wallets[10]          = 0xE9ce9be409E683A3a867a3A6581053F0DDaB4CA4;
        stakingContracts[10] = PERIODICAL_STAKING;
        offsets[10]          = -int256(uint256(1000000000000000000000000)); // -1,000,000.00

        wallets[11]          = 0xDCC62Cf1E7c6A242ed3f866FAEFbe8aEb87B28Ec;
        stakingContracts[11] = PERIODICAL_STAKING;
        offsets[11]          = -int256(uint256(243500000000000000000000)); // -243,500.00

        wallets[12]          = 0xf3cf2184d03B480aceEE416342446503dFcdcA19;
        stakingContracts[12] = PERIODICAL_STAKING;
        offsets[12]          = -int256(uint256(1000000000000000000000000)); // -1,000,000.00

        wallets[13]          = 0xfFD77FF7b9F30E120071187Ee9Cb1bdd87B0d891;
        stakingContracts[13] = PERIODICAL_STAKING;
        offsets[13]          = -int256(uint256(1000000000000000000000000)); // -1,000,000.00

        wallets[14]          = 0xF78411993c25C051f8f5678C80dcce54cCe8519D;
        stakingContracts[14] = PERIODICAL_STAKING;
        offsets[14]          = -int256(uint256(1000000000000000000000000)); // -1,000,000.00

        wallets[15]          = 0x20A8702b0626cA89C961dE94F7f3f1DA3DDe1a2E;
        stakingContracts[15] = PERIODICAL_STAKING;
        offsets[15]          = -int256(uint256(1000000000000000000000000)); // -1,000,000.00

        wallets[16]          = 0x808D2Acf6Ea6736D5C97e3b9167bcf630f4d583d;
        stakingContracts[16] = PERIODICAL_STAKING;
        offsets[16]          = -int256(uint256(1000000000000000000000000)); // -1,000,000.00

        wallets[17]          = 0xBE4528FBeEB821bc3E9697283a35F6C0808E30af;
        stakingContracts[17] = PERIODICAL_STAKING;
        offsets[17]          = -int256(uint256(1000000000000000000000000)); // -1,000,000.00

        wallets[18]          = 0x3dFBC5a761aEaf5d77dD8115453a96AD0C381FA5;
        stakingContracts[18] = PERIODICAL_STAKING;
        offsets[18]          = -int256(uint256(1000000000000000000000000)); // -1,000,000.00

        wallets[19]          = 0x664A006af27911F4D12A665c32b579C9509A1eEb;
        stakingContracts[19] = PERIODICAL_STAKING;
        offsets[19]          = -int256(uint256(1000000000000000000000000)); // -1,000,000.00

        wallets[20]          = 0xB9B089B16491264296fbB7C068cA73E8e61D6612;
        stakingContracts[20] = PERIODICAL_STAKING;
        offsets[20]          = -int256(uint256(1000000000000000000000000)); // -1,000,000.00

        wallets[21]          = 0xb22640a2A4f0C7e552e4289b826a349599E0937c;
        stakingContracts[21] = PERIODICAL_STAKING;
        offsets[21]          = -int256(uint256(1000000000000000000000000)); // -1,000,000.00

        wallets[22]          = 0x9B2Da3bb545909AD7406C99f0eACf81BE3B244b9;
        stakingContracts[22] = PERIODICAL_STAKING;
        offsets[22]          = -int256(uint256(1000000000000000000000000)); // -1,000,000.00

        wallets[23]          = 0xf4d7441c4D2118942F7fB36d55cbC6a9bAB693D8;
        stakingContracts[23] = PERIODICAL_STAKING;
        offsets[23]          = -int256(uint256(1000000000000000000000000)); // -1,000,000.00

        wallets[24]          = 0xc99b9d4bBB924E3DEC23DB4A65cADD250845e8Db;
        stakingContracts[24] = PERIODICAL_STAKING;
        offsets[24]          = -int256(uint256(1000000000000000000000000)); // -1,000,000.00

        wallets[25]          = 0xD2fB4a17fBF9016258EbFF090BcE3f9B6eB49116;
        stakingContracts[25] = PERIODICAL_STAKING;
        offsets[25]          = -int256(uint256(1000000000000000000000000)); // -1,000,000.00

        wallets[26]          = 0xF121408Daa6EdF4Db5F67D8adbF9EaF5293569Cd;
        stakingContracts[26] = PERIODICAL_STAKING;
        offsets[26]          = -int256(uint256(843927000000000000000000)); // -843,927.00

        wallets[27]          = 0xDbD875E570BAe83E23fc68fce1AeC7d63CeC4aDa;
        stakingContracts[27] = PERIODICAL_STAKING;
        offsets[27]          = -int256(uint256(1000000000000000000000000)); // -1,000,000.00

        wallets[28]          = 0x3042bf2B6c2001F92b3583C5415d9cA12aCF475B;
        stakingContracts[28] = PERIODICAL_STAKING;
        offsets[28]          = -int256(uint256(51200000000000000000000)); // -51,200.00

        wallets[29]          = 0xc4bb67A5361f1976c6327252A1ec21D2f1555F5B;
        stakingContracts[29] = PERIODICAL_STAKING;
        offsets[29]          = -int256(uint256(366300000000000000000000)); // -366,300.00

        wallets[30]          = 0x8a02d0809c7ff6749c4728C811e9c1f2d0351d2f;
        stakingContracts[30] = PERIODICAL_STAKING;
        offsets[30]          = -int256(uint256(176100000000000000000000)); // -176,100.00

        wallets[31]          = 0x412F30D40Cd80c4D6A175bDB07695978605bf247;
        stakingContracts[31] = PERIODICAL_STAKING;
        offsets[31]          = -int256(uint256(300000000000000000000000)); // -300,000.00

        wallets[32]          = 0xe52387A28AB7Db9882B3046CE3ABc5855a7425F4;
        stakingContracts[32] = PERIODICAL_STAKING;
        offsets[32]          = -int256(uint256(1000000000000000000000000)); // -1,000,000.00

        wallets[33]          = 0x4BE3275fb70805698450E7C5eA29cA7CaB732837;
        stakingContracts[33] = PERIODICAL_STAKING;
        offsets[33]          = -int256(uint256(892260000000000000000000)); // -892,260.00

        wallets[34]          = 0x24339502739640eB4DFaBfAB7F0ef3314ddC9c60;
        stakingContracts[34] = PERIODICAL_STAKING;
        offsets[34]          = -int256(uint256(243588900000000000000000)); // -243,588.90

        wallets[35]          = 0x840CfdB0b6d47dBBe215202A9d1fb9A165b734bF;
        stakingContracts[35] = PERIODICAL_STAKING;
        offsets[35]          = -int256(uint256(920000000000000000000000)); // -920,000.00

        wallets[36]          = 0xf01040A392A63f211a99De380d5c1B665320a863;
        stakingContracts[36] = PERIODICAL_STAKING;
        offsets[36]          = -int256(uint256(1000000000000000000000000)); // -1,000,000.00

        wallets[37]          = 0xA7D79178942235A34A33e25c379a635a41400F2c;
        stakingContracts[37] = PERIODICAL_STAKING;
        offsets[37]          = -int256(uint256(1000000000000000000000000)); // -1,000,000.00

        wallets[38]          = 0xd5851b50855DE755fb34C803A862b55423019fa9;
        stakingContracts[38] = PERIODICAL_STAKING;
        offsets[38]          = -int256(uint256(697000000000000000000000)); // -697,000.00

        wallets[39]          = 0x4a8b16E99689c6F1d55B922eEb1806327C1C9d3D;
        stakingContracts[39] = PERIODICAL_STAKING;
        offsets[39]          = -int256(uint256(1000000000000000000000000)); // -1,000,000.00

        wallets[40]          = 0x9e618986a6513EE8Fd67dEd0DD6d18bB17D1bd97;
        stakingContracts[40] = PERIODICAL_STAKING;
        offsets[40]          = -int256(uint256(1000000000000000000000000)); // -1,000,000.00

        wallets[41]          = 0xCBCB8439a22a01847757ceb784016083Cb6a0f65;
        stakingContracts[41] = PERIODICAL_STAKING;
        offsets[41]          = -int256(uint256(1000000000000000000000000)); // -1,000,000.00

        wallets[42]          = 0xa339b415398928f2C48c19f90b8e2804D7D29ecF;
        stakingContracts[42] = PERIODICAL_STAKING;
        offsets[42]          = -int256(uint256(1000000000000000000000000)); // -1,000,000.00

        wallets[43]          = 0x0866F421D2591b87f459b7373D2FA9F8f959b7D7;
        stakingContracts[43] = PERIODICAL_STAKING;
        offsets[43]          = -int256(uint256(1000000000000000000000000)); // -1,000,000.00

        wallets[44]          = 0x2329023eF31cfe7A84e9f53F15DFbcFaC3Aacf5a;
        stakingContracts[44] = PERIODICAL_STAKING;
        offsets[44]          = -int256(uint256(1000000000000000000000000)); // -1,000,000.00

        wallets[45]          = 0xE2030d09d8682E2771F9D179bD1a61366245d2CE;
        stakingContracts[45] = PERIODICAL_STAKING;
        offsets[45]          = -int256(uint256(421424270000000000000000)); // -421,424.27

        wallets[46]          = 0xd83F2e7768bBe2eaf597F54bD03Ea81A9596870F;
        stakingContracts[46] = PERIODICAL_STAKING;
        offsets[46]          = -int256(uint256(1000000000000000000000000)); // -1,000,000.00

        wallets[47]          = 0x2d4c79960bcE4161643e0f3a7b7C459F876BDEe6;
        stakingContracts[47] = PERIODICAL_STAKING;
        offsets[47]          = -int256(uint256(1000000000000000000000000)); // -1,000,000.00

        wallets[48]          = 0xA77A6701186402F251D342af9c73Eb9c7f81B0b1;
        stakingContracts[48] = PERIODICAL_STAKING;
        offsets[48]          = -int256(uint256(1000000000000000000000000)); // -1,000,000.00

        wallets[49]          = 0xd00bE684871aAE5e22042fe68dad498EB3811A3e;
        stakingContracts[49] = PERIODICAL_STAKING;
        offsets[49]          = -int256(uint256(1000000000000000000000000)); // -1,000,000.00

        wallets[50]          = 0x2ee2405dc72EA46BcEBDdbC089bc11897c86935d;
        stakingContracts[50] = PERIODICAL_STAKING;
        offsets[50]          = -int256(uint256(925801000000000000000000)); // -925,801.00

        wallets[51]          = 0x5Acd7734Fa4e93854F4459F7eeeA99d7dDff8734;
        stakingContracts[51] = PERIODICAL_STAKING;
        offsets[51]          = -int256(uint256(395297000000000000000000)); // -395,297.00

        wallets[52]          = 0x243FA6718905084b07C5fF665d34CEc0Bb57dF60;
        stakingContracts[52] = PERIODICAL_STAKING;
        offsets[52]          = -int256(uint256(1000000000000000000000000)); // -1,000,000.00

        wallets[53]          = 0xB513e2ADFB16c1E6F8f92d7Ba2533826C5fd4361;
        stakingContracts[53] = PERIODICAL_STAKING;
        offsets[53]          = -int256(uint256(1000000000000000000000000)); // -1,000,000.00

        wallets[54]          = 0x3aAf48118cAe0f66a8738C24D04E260728a186c7;
        stakingContracts[54] = PERIODICAL_STAKING;
        offsets[54]          = -int256(uint256(1000000000000000000000000)); // -1,000,000.00

        wallets[55]          = 0x247e8465D56972b09dE579C13eD40792a09BC278;
        stakingContracts[55] = PERIODICAL_STAKING;
        offsets[55]          = -int256(uint256(1000000000000000000000000)); // -1,000,000.00

        wallets[56]          = 0xfF3A58211068937E42fB2A580ccB5BA1540D6c7f;
        stakingContracts[56] = PERIODICAL_STAKING;
        offsets[56]          = -int256(uint256(1000000000000000000000000)); // -1,000,000.00

        wallets[57]          = 0xee8c8371B5e72447E664a31dC8Acc32875C0a4ad;
        stakingContracts[57] = PERIODICAL_STAKING;
        offsets[57]          = -int256(uint256(34511000000000000000000)); // -34,511.00

        wallets[58]          = 0xbDCD9Aa0Ba209B4DB573D846d40515af9A18Dc46;
        stakingContracts[58] = PERIODICAL_STAKING;
        offsets[58]          = -int256(uint256(1000000000000000000000000)); // -1,000,000.00

        wallets[59]          = 0x831094C075744fE564031F33A672D52b7CC07d23;
        stakingContracts[59] = PERIODICAL_STAKING;
        offsets[59]          = -int256(uint256(70988000000000000000000)); // -70,988.00

        wallets[60]          = 0x57a1BD324391ce1AC3a338CF7E1fd672CCafA46B;
        stakingContracts[60] = PERIODICAL_STAKING;
        offsets[60]          = -int256(uint256(1000000000000000000000000)); // -1,000,000.00

        wallets[61]          = 0x2D959946536408f3a5447E872FC3Df00bAD85097;
        stakingContracts[61] = PERIODICAL_STAKING;
        offsets[61]          = -int256(uint256(32116000000000000000000)); // -32,116.00

        wallets[62]          = 0x4D307A6E63486D01B95B691fbd1ee703b07DB259;
        stakingContracts[62] = PERIODICAL_STAKING;
        offsets[62]          = -int256(uint256(307559000000000000000000)); // -307,559.00

        wallets[63]          = 0x99dD14B704c246DA813f9589E7cd53F3b8d00010;
        stakingContracts[63] = PERIODICAL_STAKING;
        offsets[63]          = -int256(uint256(114000000000000000000000)); // -114,000.00

        wallets[64]          = 0x6148b13D0aeED932056469587F583C389F01a04b;
        stakingContracts[64] = PERIODICAL_STAKING;
        offsets[64]          = -int256(uint256(1000000000000000000000000)); // -1,000,000.00

        wallets[65]          = 0xaBd38386034C07FfbD37d87080F4deCcD7Bac245;
        stakingContracts[65] = PERIODICAL_STAKING;
        offsets[65]          = -int256(uint256(1000000000000000000000000)); // -1,000,000.00

        wallets[66]          = 0x8DFcEd54D2f84a53774D0D5974f3d5e81D4A5f78;
        stakingContracts[66] = PERIODICAL_STAKING;
        offsets[66]          = -int256(uint256(1000000000000000000000000)); // -1,000,000.00

        wallets[67]          = 0x0a6c8b37acfF745c89C1e9BB46F45E930ffD36fe;
        stakingContracts[67] = PERIODICAL_STAKING;
        offsets[67]          = -int256(uint256(212906000000000000000000)); // -212,906.00

        wallets[68]          = 0x4b78AFc593d70BF168c0871129524014e274C5Cf;
        stakingContracts[68] = PERIODICAL_STAKING;
        offsets[68]          = -int256(uint256(37170000000000000000000)); // -37,170.00

        wallets[69]          = 0x3FCf6ebeCe3aA8b5e8A44859a20cE817ff4e241c;
        stakingContracts[69] = PERIODICAL_STAKING;
        offsets[69]          = -int256(uint256(925821000000000000000000)); // -925,821.00

        wallets[70]          = 0x90Ab90bE2ce0DF9a0Bc3a75684d19BAA48E3354e;
        stakingContracts[70] = PERIODICAL_STAKING;
        offsets[70]          = -int256(uint256(31723920000000000000000)); // -31,723.92

        vm.startBroadcast();
        IRequirementCheckerV2(REQUIREMENT_CHECKER_V2)
            .setPeriodicalStakingOffsetBatch(wallets, stakingContracts, offsets);
        vm.stopBroadcast();
    }
}