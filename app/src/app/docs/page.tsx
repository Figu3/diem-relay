import { Header } from "@/components/Header";
import { BASESCAN_ADDRESSES, GITHUB_URL } from "@/config/protocol-links";

export default function DocsPage() {
  return (
    <>
      <Header />
      <main className="pool-page">
        <article className="content-page">
          <h1>Diem Relay Docs</h1>

          <h2>Overview</h2>

          <p>
            Diem Relay is a marketplace that lets DIEM holders earn USDC on their credits.
            Stake your DIEM tokens, let others use the inference credits, and get paid daily
            in USDC. This page covers how the marketplace works,
            the sDIEM and csDIEM receipts, fees, withdrawals, contracts, and security status.
          </p>

          <h2>How it works</h2>

          <ol>
            <li>Supply DIEM to the pool and receive sDIEM or csDIEM.</li>
            <li>The pooled DIEM is forward-staked on Venice and backs AI inference sold to compute buyers.</li>
            <li>
              USDC from each sale is distributed to suppliers, with a 20% platform fee
              retained by Diem Relay.
            </li>
          </ol>

          <h2>DIEM — the base asset</h2>

          <p>
            DIEM is a perpetual $1 inference credit on Venice, held on Base, and the asset you
            supply to the relay. Diem Relay does not issue DIEM — it runs the marketplace that
            sells the inference your DIEM backs, and issues receipt tokens (sDIEM / csDIEM)
            representing your position.
          </p>

          <h2>Live contracts</h2>

          <p>
            The live staking system is deployed on Base. sDIEM is a transferable ERC-20
            receipt with EIP-2612 permit and reward checkpointing on transfers. csDIEM is a
            canonical ERC-4626 wrapper over sDIEM, with synchronous redeem support and a
            direct DIEM deposit zap.
          </p>

          <h2>Fees</h2>

          <p>
            Diem Relay keeps a 20% platform fee on inference revenue. The remaining 80% is
            distributed to suppliers in USDC, pro-rata to their share of the pool. The split is
            hardcoded in RevenueSplitter and requires redeploying the splitter to change. There
            is no fee to supply or withdraw beyond network gas.
          </p>

          <h2>Revenue distribution</h2>

          <p>
            Customer USDC lands on RevenueSplitter. Anyone can call <code>distribute()</code>
            {" "}once the balance is above the minimum floor and the cooldown has elapsed. The
            splitter sends 20% to the protocol Safe and forwards 80% to sDIEM through
            {" "}<code>notifyRewardAmount()</code>, where it streams over 24 hours.
          </p>

          <p>
            The project keeper runs daily: first it attempts csDIEM harvest, then it calls
            RevenueSplitter distribution. Each step has independent skip conditions, so a
            harvest-side issue does not block the revenue split.
          </p>

          <h2>sDIEM — liquid staking</h2>

          <p>
            Supply DIEM and you receive sDIEM, a liquid receipt for your position. sDIEM
            accrues claimable USDC rewards you collect manually, and stays transferable so you
            keep flexibility — hold it, move it, or wrap it into the compounding vault. The
            withdrawal queue is per address and does not transfer with sDIEM.
          </p>

          <h2>csDIEM — compounding vault</h2>

          <p>
            csDIEM is an ERC-4626 vault receipt over sDIEM. Instead of claiming by hand,
            rewards accrue through the csDIEM exchange rate, so each csDIEM is worth
            progressively more of the underlying over time. Enter by wrapping existing sDIEM,
            or by supplying DIEM directly into the vault.
          </p>

          <h2>Withdrawals</h2>

          <p>
            Withdrawals run through sDIEM. sDIEM withdraws back to DIEM after Venice&apos;s
            cooldown. The normal path is request, wait about 24 hours, then complete; batched
            withdrawals can make the practical worst case closer to 48 hours. If only part of a
            withdrawal is liquid when you complete it, the contract pays what is available and
            leaves the rest queued until the next Venice cooldown or vault-liquidity update.
            csDIEM unwraps to sDIEM first, then follows the same path to DIEM.
          </p>

          <h2 id="contracts">Contracts</h2>

          <p>Deployed on Base:</p>

          <ul>
            <li>
              DIEM token —{" "}
              <a href={BASESCAN_ADDRESSES.diemToken} rel="noreferrer" target="_blank">
                0xf4d97f2da56e8c3098f3a8d538db630a2606a024
              </a>
            </li>
            <li>
              DIEMVault — deposit and supply —{" "}
              <a href={BASESCAN_ADDRESSES.diemVault} rel="noreferrer" target="_blank">
                0xdc9625b026f6Dd17F9d96e608592A9C592e27eEF
              </a>
            </li>
            <li>
              sDIEM — transferable liquid staking receipt —{" "}
              <a href={BASESCAN_ADDRESSES.sdiemV2} rel="noreferrer" target="_blank">
                0x8065228a8156590A8BFca30678394e9db91f80Ee
              </a>
            </li>
            <li>
              csDIEM — ERC-4626 compounding vault —{" "}
              <a href={BASESCAN_ADDRESSES.csdiemV2} rel="noreferrer" target="_blank">
                0x78B8726929911044748374178CB2D417A54319e5
              </a>
            </li>
            <li>
              RevenueSplitter — USDC reward distribution —{" "}
              <a href={BASESCAN_ADDRESSES.revenueSplitter} rel="noreferrer" target="_blank">
                0x96DAE834f7276D50a09149D938e998b1766AFCDa
              </a>
            </li>
            <li>
              Admin / operator 2-of-2 Safe —{" "}
              <a href={BASESCAN_ADDRESSES.adminSafe} rel="noreferrer" target="_blank">
                0x01Ea790410D9863A57771D992D2A72ea326DD7C9
              </a>
            </li>
          </ul>

          <p>
            Source code:{" "}
            <a href={GITHUB_URL} rel="noreferrer" target="_blank">
              Figu3/diem-relay
            </a>
          </p>

          <h2>Risks</h2>

          <p>
            Crypto products involve risk, including smart contract bugs, market volatility,
            protocol changes, wallet mistakes, and loss of funds. This interface is provided
            as-is and is not financial, legal, or tax advice. Use it at your own risk.
          </p>
        </article>
      </main>
    </>
  );
}
