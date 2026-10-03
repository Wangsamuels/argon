# Live deployments

Redeployed 2026-10-03 with the scheduled-news pause. Addresses differ per chain (deployer nonces differ). Owner and keeper: `0x9642b6D1Db5D1A3B0A61a831099568bbCbC04D4E`.

| Contract | Arbitrum One (42161) | Robinhood Chain (4663) |
|----------|----------------------|------------------------|
| InferenceRegistry | [`0x8F288a7a6E28a5d44980De19502522C376965afe`](https://arbiscan.io/address/0x8F288a7a6E28a5d44980De19502522C376965afe) | [`0x256A61b459BFdb48B4C04DE5Ba13E0dFBC326508`](https://robinhoodchain.blockscout.com/address/0x256A61b459BFdb48B4C04DE5Ba13E0dFBC326508) |
| ChainlinkEthOracle | [`0x89403CA4AdB3A89A0173B7494903B4247881966f`](https://arbiscan.io/address/0x89403CA4AdB3A89A0173B7494903B4247881966f) | [`0x8F288a7a6E28a5d44980De19502522C376965afe`](https://robinhoodchain.blockscout.com/address/0x8F288a7a6E28a5d44980De19502522C376965afe) |
| ArgonVault | [`0xe0eb546A1F8dcEc7B124cF8fE253de34d54A6c61`](https://arbiscan.io/address/0xe0eb546A1F8dcEc7B124cF8fE253de34d54A6c61) | [`0x89403CA4AdB3A89A0173B7494903B4247881966f`](https://robinhoodchain.blockscout.com/address/0x89403CA4AdB3A89A0173B7494903B4247881966f) |
| UniswapV3Adapter | [`0x05734481536644bc20e671Db28f5b4c05B7D64D4`](https://arbiscan.io/address/0x05734481536644bc20e671Db28f5b4c05B7D64D4) | [`0xEDa50F3F5530E9BFFD427c1DB0E0a8f3D05cCC9D`](https://robinhoodchain.blockscout.com/address/0xEDa50F3F5530E9BFFD427c1DB0E0a8f3D05cCC9D) |

- Arbitrum: gated **pool 1** (WETH/USDC 500), deposit fee 10 bps, USDC/USD feed `0x50834F3163758fcC1Df9973b6e91f0F0F0434aD3`.
- Robinhood: gated **pool 4** (WETH/USDG 500), deposit fee 60 bps, Uniswap SwapRouter02
  [`0xCaf681a66D020601342297493863E78C959E5cb2`](https://robinhoodchain.blockscout.com/address/0xCaf681a66D020601342297493863E78C959E5cb2)
  ([configuration transaction](https://robinhoodchain.blockscout.com/tx/0x916826ad867715455303b2005659ee3432f21c5af41e95e366adad072186ddf2)).

## News pause

Around high-impact US releases (CPI, FOMC, NFP, PCE, GDP, Fed Chair and anything the calendar marks high-impact for USD)
the keeper calls `setNewsPause(from, until)` in UTC hour ids: `from` is one hour before the release hour, `until` is four
hours after it. While `newsPaused(hour)` is true, `rebalance` only accepts EXIT. A window is at most 24h, can be set at most
48h ahead, and an active window can be extended but not shortened. Only the owner can `clearNewsPause()`.

Retired (0 shares at redeploy): 2026-10-02 vaults Arb `0x744e2dD4Ce32148C8a4bf65BC37824cc129086aF` / RH `0xe8eA8f046152C36dC8c11a5434C31A1E2343f274`;
original vaults `0x9F844b4D1b28Be7413067f9d4fC08Bc276fd1C60` on both chains.
