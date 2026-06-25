"use client";

import { useState } from "react";
import { parseUnits } from "viem";
import { useAccount } from "wagmi";

import { VaultCard } from "./VaultCard";
import { StatRow } from "./StatRow";
import { CountdownTimer } from "./CountdownTimer";
import { PausedBanner } from "./PausedBanner";
import { DepositWithdrawTabs } from "./DepositWithdrawTabs";
import { AmountInput } from "./AmountInput";
import { ActionButton } from "./ActionButton";
import { TxStatus } from "./TxStatus";
import { Tooltip } from "./Tooltip";

import { useSDiem } from "@/hooks/useSDiem";
import { useDiemPrice } from "@/hooks/useDiemPrice";
import { useDiemToken } from "@/hooks/useDiemToken";
import { useApproval } from "@/hooks/useApproval";
import { useStake } from "@/hooks/useStake";
import { useRequestWithdraw, useCompleteWithdraw, useCancelWithdraw } from "@/hooks/useWithdrawSDiem";
import { useClaimReward } from "@/hooks/useClaimReward";
import { useExit } from "@/hooks/useExit";
import { useCSDiem, isCSDiemDeployed } from "@/hooks/useCSDiem";
import { useDepositCSDiem, useDepositSDiemToCSDiem } from "@/hooks/useDepositCSDiem";
import {
  useRequestRedeemCSDiem,
  useCompleteRedeemCSDiem,
  useCancelRedeemCSDiem,
  useRedeemCSDiemV2,
} from "@/hooks/useRedeemCSDiem";
import { useContracts } from "@/hooks/useContracts";
import { DIEM_TOKEN, DIEM_DECIMALS } from "@/config/contracts";
import { formatDiem, formatUsdc } from "@/lib/format";
import { calcSDiemApr } from "@/lib/apr";

const CSDIEM_TOOLTIP_V1 = (
  <>
    <strong className="text-accent">csDIEM</strong> is the DeFi wrapper for
    sDIEM — a transferable ERC-4626 share whose price grows as USDC rewards
    are harvested and re-staked into DIEM. Unlike sDIEM (non-transferable),
    csDIEM is usable as ERC-20 collateral, in LPs, and across DeFi. Same 24h
    exit (request → wait → complete).
  </>
);

const CSDIEM_TOOLTIP_V2 = (
  <>
    <strong className="text-accent">csDIEM</strong> is the canonical
    ERC-4626 wrapper over sDIEM. Share price grows as USDC rewards are
    harvested and re-staked into DIEM. Synchronous redeem returns sDIEM
    (then exit through sDIEM&apos;s 24h queue to get raw DIEM).
  </>
);

// Surfaces the on-chain allowance so users understand re-approval prompts.
// Some wallets (Rabby, MetaMask, Coinbase) cap the dApp's max-uint256 request
// to the exact deposit amount, which gets consumed on transferFrom — hence
// "approve every time" symptoms despite the dApp requesting unlimited.
function AllowanceHint({
  allowance,
  needsApproval,
  unlimitedThreshold,
}: {
  allowance: bigint;
  needsApproval: boolean;
  unlimitedThreshold: bigint;
}) {
  if (allowance >= unlimitedThreshold) return null;
  if (allowance === 0n && !needsApproval) return null;

  return (
    <div className="space-y-1 text-[10px] leading-relaxed text-gray-500">
      <p>
        Current DIEM allowance:{" "}
        <span className="font-mono text-gray-400">
          {formatDiem(allowance)} DIEM
        </span>
      </p>
      {needsApproval && (
        <p>
          Tip: some wallets cap approvals to the exact deposit amount. Set the
          spending cap to <span className="text-gray-300">unlimited</span> in
          your wallet to skip re-approving on every deposit.
        </p>
      )}
    </div>
  );
}

export function SDiemCard() {
  const { isConnected } = useAccount();
  const { sdiem: sdiemAddr, csdiem: csdiemAddr, isV2 } = useContracts();
  const sdiem = useSDiem();
  const csdiem = useCSDiem();
  const { priceUsd: diemPriceUsd } = useDiemPrice();
  // Two reads of the DIEM token, one per spender, for the two allowance
  // surfaces. balance is the same on both — use whichever; we use diem.balance.
  const diem = useDiemToken(sdiemAddr);
  const diemForCs = useDiemToken(csdiemAddr);

  // v2-only: read the user's sDIEM v2 ERC-20 balance + allowance against
  // csDIEM v2 so the atomic sDIEM→csDIEM wrap path can render. On v1 sDIEM
  // is non-transferable, so this is ignored.
  const sdiemAsToken = useDiemToken(csdiemAddr, sdiemAddr);

  // Approvals — DIEM may need to be approved for either sDIEM or csDIEM,
  // and (v2 only) sDIEM v2 may need to be approved for csDIEM v2.
  const sdiemApproval = useApproval(DIEM_TOKEN, sdiemAddr);
  const csdiemApproval = useApproval(DIEM_TOKEN, csdiemAddr);
  const sdiemToCsdiemApproval = useApproval(sdiemAddr, csdiemAddr);

  // Actions
  const stakeAction = useStake();
  const depositCs = useDepositCSDiem();
  const depositSDiemCs = useDepositSDiemToCSDiem();
  const requestAction = useRequestWithdraw();
  const completeAction = useCompleteWithdraw();
  const cancelAction = useCancelWithdraw();
  const claimAction = useClaimReward();
  const exitAction = useExit();
  // v1 async redeem
  const requestRedeemCs = useRequestRedeemCSDiem();
  const completeRedeemCs = useCompleteRedeemCSDiem();
  const cancelRedeemCs = useCancelRedeemCSDiem();
  // v2 sync redeem
  const redeemCsV2 = useRedeemCSDiemV2();

  const [stakeAmt, setStakeAmt] = useState("");
  const [withdrawAmt, setWithdrawAmt] = useState("");
  const [wrapAmt, setWrapAmt] = useState("");
  const [wrapSDiemAmt, setWrapSDiemAmt] = useState("");
  const [redeemAmt, setRedeemAmt] = useState("");
  const [autoCompound, setAutoCompound] = useState(false);

  // Gate APR on an active reward period: rewardRate persists after
  // periodFinish in the Synthetix model, so without this the badge would show
  // a phantom APR for a vault that has stopped paying.
  const apr = calcSDiemApr(
    sdiem.rewardRate,
    sdiem.totalStaked,
    diemPriceUsd,
    sdiem.periodFinish,
    BigInt(Math.floor(Date.now() / 1000))
  );

  const csdiemAvailable = isV2 || isCSDiemDeployed;

  // ── Stake-tab approval routing ────────────────────────────────────────
  // When auto-compound is on, stake flow targets csDIEM instead of sDIEM —
  // approval target switches accordingly.
  const stakeTarget = autoCompound && csdiemAvailable ? "csdiem" : "sdiem";
  const activeApproval = stakeTarget === "csdiem" ? csdiemApproval : sdiemApproval;
  const allowanceForStake =
    stakeTarget === "csdiem" ? diemForCs.allowance : diem.allowance;
  const needsApproval =
    stakeAmt !== "" &&
    allowanceForStake < parseUnits(stakeAmt || "0", DIEM_DECIMALS);

  // Above 1T DIEM we treat allowance as effectively unlimited and skip the
  // wallet-cap hint. Wallets rendering max-uint256 as a literal number land
  // far above this; user-edited caps land well below.
  const UNLIMITED_THRESHOLD = parseUnits("1000000000000", DIEM_DECIMALS);

  const handleStake = () => {
    if (!stakeAmt) return;
    const amount = parseUnits(stakeAmt, DIEM_DECIMALS);
    if (stakeTarget === "csdiem") {
      depositCs.deposit(amount);
    } else {
      stakeAction.stake(amount);
    }
  };

  const handleRequestWithdraw = () => {
    if (!withdrawAmt) return;
    requestAction.requestWithdraw(parseUnits(withdrawAmt, DIEM_DECIMALS));
  };

  // ── Wrap tab handlers ─────────────────────────────────────────────────
  const wrapNeedsApproval =
    wrapAmt !== "" &&
    diemForCs.allowance < parseUnits(wrapAmt || "0", DIEM_DECIMALS);

  const wrapSDiemNeedsApproval =
    wrapSDiemAmt !== "" &&
    sdiemAsToken.allowance < parseUnits(wrapSDiemAmt || "0", DIEM_DECIMALS);

  const handleWrap = () => {
    if (!wrapAmt) return;
    depositCs.deposit(parseUnits(wrapAmt, DIEM_DECIMALS));
  };

  const handleWrapSDiem = () => {
    if (!wrapSDiemAmt) return;
    depositSDiemCs.depositSDiem(parseUnits(wrapSDiemAmt, DIEM_DECIMALS));
  };

  const handleRequestRedeem = () => {
    if (!redeemAmt) return;
    requestRedeemCs.requestRedeem(parseUnits(redeemAmt, DIEM_DECIMALS));
  };

  const handleSyncRedeem = () => {
    if (!redeemAmt) return;
    redeemCsV2.redeem(parseUnits(redeemAmt, DIEM_DECIMALS));
  };

  // ── Loading flags ─────────────────────────────────────────────────────
  const staking =
    activeApproval.isPending || activeApproval.isConfirming ||
    stakeAction.isPending || stakeAction.isConfirming ||
    depositCs.isPending || depositCs.isConfirming;
  const requesting = requestAction.isPending || requestAction.isConfirming;
  const completing = completeAction.isPending || completeAction.isConfirming;
  const cancelling = cancelAction.isPending || cancelAction.isConfirming;
  const claiming = claimAction.isPending || claimAction.isConfirming;
  const exiting = exitAction.isPending || exitAction.isConfirming;
  const wrapping =
    csdiemApproval.isPending || csdiemApproval.isConfirming ||
    depositCs.isPending || depositCs.isConfirming;
  const wrappingSDiem =
    sdiemToCsdiemApproval.isPending || sdiemToCsdiemApproval.isConfirming ||
    depositSDiemCs.isPending || depositSDiemCs.isConfirming;
  const redeemingV1 = requestRedeemCs.isPending || requestRedeemCs.isConfirming;
  const completingCs = completeRedeemCs.isPending || completeRedeemCs.isConfirming;
  const cancellingCs = cancelRedeemCs.isPending || cancelRedeemCs.isConfirming;
  const redeemingV2 = redeemCsV2.isPending || redeemCsV2.isConfirming;

  const hasPending = sdiem.pendingWithdrawAmount > 0n;
  const unlockTime = sdiem.pendingWithdrawRequestedAt + sdiem.withdrawalDelay;
  const canComplete = sdiem.canComplete;

  // v1-only: csDIEM has a pending unwrap state. v2's redeem is synchronous,
  // so these fields stay at their zero defaults.
  const csUnlockTime =
    csdiem.pendingRedemption.requestedAt + csdiem.withdrawalDelay;
  const hasCsPending = !isV2 && csdiem.pendingRedemption.assets > 0n;

  // ── Tab construction ──────────────────────────────────────────────────
  const stakeTab = {
    label: "Stake",
    content: (
      <div className="space-y-3">
        <AmountInput
          value={stakeAmt}
          onChange={setStakeAmt}
          max={diem.balance}
          disabled={sdiem.paused || (autoCompound && csdiem.paused)}
        />
        {csdiemAvailable && (
          <label className="flex cursor-pointer items-center gap-2 text-xs text-gray-400">
            <input
              type="checkbox"
              checked={autoCompound}
              onChange={(e) => setAutoCompound(e.target.checked)}
              disabled={csdiem.paused}
              className="h-3.5 w-3.5 cursor-pointer accent-accent disabled:cursor-not-allowed"
            />
            <span>
              Mint csDIEM instead — auto-compound + DeFi-composable
            </span>
            <Tooltip content={isV2 ? CSDIEM_TOOLTIP_V2 : CSDIEM_TOOLTIP_V1}>
              <span className="text-[10px]">ⓘ</span>
            </Tooltip>
          </label>
        )}
        <AllowanceHint
          allowance={allowanceForStake}
          needsApproval={needsApproval}
          unlimitedThreshold={UNLIMITED_THRESHOLD}
        />
        <ActionButton
          needsApproval={needsApproval}
          onApprove={() => activeApproval.approve()}
          onAction={handleStake}
          actionLabel={
            stakeTarget === "csdiem" ? "Stake DIEM (auto-compound)" : "Stake DIEM"
          }
          disabled={
            !stakeAmt ||
            stakeAmt === "0" ||
            (stakeTarget === "csdiem" ? csdiem.paused : sdiem.paused)
          }
          loading={staking}
        />
        <TxStatus
          isPending={
            stakeAction.isPending || depositCs.isPending || activeApproval.isPending
          }
          isConfirming={
            stakeAction.isConfirming ||
            depositCs.isConfirming ||
            activeApproval.isConfirming
          }
          isSuccess={stakeAction.isSuccess || depositCs.isSuccess}
          error={stakeAction.error ?? depositCs.error ?? activeApproval.error}
          hash={stakeAction.hash ?? depositCs.hash ?? activeApproval.hash}
          onReset={() => {
            stakeAction.reset();
            depositCs.reset();
            activeApproval.reset();
          }}
        />
      </div>
    ),
  };

  const withdrawTab = {
    label: "Withdraw",
    content: (
      <div className="space-y-3">
        {hasPending && (
          <div className="rounded-lg border border-amber-500/30 bg-amber-500/5 p-3">
            <p className="text-sm font-medium text-amber-400">
              Pending: {formatDiem(sdiem.pendingWithdrawAmount)} DIEM
            </p>
            {canComplete ? (
              <p className="mt-1 text-xs text-green-400">Ready to complete</p>
            ) : (
              <div className="mt-1 flex items-center gap-1 text-xs text-gray-400">
                <span>Unlocks in</span>
                <CountdownTimer periodFinish={unlockTime} />
              </div>
            )}
            <div className="mt-2 flex gap-2">
              <button
                onClick={() => completeAction.completeWithdraw()}
                disabled={!canComplete || completing}
                className="flex-1 rounded-lg border border-green-500/40 py-2 text-sm font-medium text-green-400 transition hover:bg-green-500/10 disabled:opacity-40"
              >
                {completing ? "Completing..." : "Complete Withdrawal"}
              </button>
              <button
                onClick={() => cancelAction.cancelWithdraw()}
                disabled={cancelling}
                className="rounded-lg border border-gray-500/40 px-3 py-2 text-sm font-medium text-gray-400 transition hover:bg-gray-500/10 disabled:opacity-40"
              >
                {cancelling ? "..." : "Cancel"}
              </button>
            </div>
            <TxStatus
              isPending={completeAction.isPending || cancelAction.isPending}
              isConfirming={completeAction.isConfirming || cancelAction.isConfirming}
              isSuccess={completeAction.isSuccess || cancelAction.isSuccess}
              error={completeAction.error ?? cancelAction.error}
              hash={completeAction.hash ?? cancelAction.hash}
              onReset={() => { completeAction.reset(); cancelAction.reset(); }}
            />
          </div>
        )}
        <AmountInput
          value={withdrawAmt}
          onChange={setWithdrawAmt}
          max={sdiem.userStaked}
          disabled={sdiem.paused}
        />
        <ActionButton
          needsApproval={false}
          onApprove={() => {}}
          onAction={handleRequestWithdraw}
          actionLabel="Request Withdraw (24h delay)"
          disabled={
            !withdrawAmt ||
            withdrawAmt === "0" ||
            sdiem.paused ||
            (sdiem.minWithdraw > 0n && parseUnits(withdrawAmt || "0", DIEM_DECIMALS) < sdiem.minWithdraw)
          }
          loading={requesting}
        />
        {sdiem.userStaked > 0n && (
          <button
            onClick={() => exitAction.exit()}
            disabled={exiting || sdiem.paused}
            className="w-full rounded-lg py-2 text-xs text-gray-400 transition hover:text-gray-200 disabled:opacity-40"
          >
            {exiting ? "Exiting..." : "Exit (withdraw all + claim)"}
          </button>
        )}
        <TxStatus
          isPending={requestAction.isPending || exitAction.isPending}
          isConfirming={requestAction.isConfirming || exitAction.isConfirming}
          isSuccess={requestAction.isSuccess || exitAction.isSuccess}
          error={requestAction.error ?? exitAction.error}
          hash={requestAction.hash ?? exitAction.hash}
          onReset={() => { requestAction.reset(); exitAction.reset(); }}
        />
      </div>
    ),
  };

  const wrapTab = {
    label: "Wrap",
    content: (
      <div className="space-y-3">
        {csdiem.paused && <PausedBanner />}

        <p className="text-xs leading-relaxed text-gray-400">
          {isV2 ? (
            <>
              <strong className="text-accent">csDIEM</strong> is the
              canonical ERC-4626 wrapper over sDIEM that auto-compounds USDC
              rewards into DIEM. Use it as ERC-20 collateral, in LPs, or in
              Pendle / Morpho / Spectra / Silo.
            </>
          ) : (
            <>
              <strong className="text-accent">csDIEM</strong> is the DeFi wrapper
              for sDIEM — a transferable ERC-4626 share that auto-compounds USDC
              rewards into DIEM. Use it as ERC-20 collateral, in LPs, or anywhere
              across DeFi.
            </>
          )}
        </p>

        <StatRow
          label="Your csDIEM"
          value={`${formatDiem(csdiem.userShares)} csDIEM`}
        />
        <StatRow
          label="DIEM value"
          value={`${formatDiem(csdiem.userAssetsValue)} DIEM`}
        />

        {hasCsPending && (
          <div className="rounded-lg border border-amber-500/30 bg-amber-500/5 p-3">
            <p className="text-sm font-medium text-amber-400">
              Pending unwrap: {formatDiem(csdiem.pendingRedemption.assets)} DIEM
            </p>
            {csdiem.canCompleteRedeem ? (
              <p className="mt-1 text-xs text-green-400">Ready to complete</p>
            ) : (
              <div className="mt-1 flex items-center gap-1 text-xs text-gray-400">
                <span>Unlocks in</span>
                <CountdownTimer periodFinish={csUnlockTime} />
              </div>
            )}
            <div className="mt-2 flex gap-2">
              <button
                onClick={() => completeRedeemCs.completeRedeem()}
                disabled={!csdiem.canCompleteRedeem || completingCs}
                className="flex-1 rounded-lg border border-green-500/40 py-2 text-sm font-medium text-green-400 transition hover:bg-green-500/10 disabled:opacity-40"
              >
                {completingCs ? "Completing..." : "Complete Unwrap"}
              </button>
              <button
                onClick={() => cancelRedeemCs.cancelRedeem()}
                disabled={cancellingCs}
                className="rounded-lg border border-gray-500/40 px-3 py-2 text-sm font-medium text-gray-400 transition hover:bg-gray-500/10 disabled:opacity-40"
              >
                {cancellingCs ? "..." : "Cancel"}
              </button>
            </div>
            <TxStatus
              isPending={completeRedeemCs.isPending || cancelRedeemCs.isPending}
              isConfirming={completeRedeemCs.isConfirming || cancelRedeemCs.isConfirming}
              isSuccess={completeRedeemCs.isSuccess || cancelRedeemCs.isSuccess}
              error={completeRedeemCs.error ?? cancelRedeemCs.error}
              hash={completeRedeemCs.hash ?? cancelRedeemCs.hash}
              onReset={() => { completeRedeemCs.reset(); cancelRedeemCs.reset(); }}
            />
          </div>
        )}

        <div className="space-y-2 rounded-lg border border-border bg-card-inner p-3">
          <p className="text-xs font-medium text-gray-300">Wrap DIEM → csDIEM</p>
          {!isV2 && (
            <p className="text-[11px] leading-relaxed text-gray-500">
              Already staking in sDIEM? Withdraw it first (24h delay), then
              wrap the resulting DIEM here.
            </p>
          )}
          {isV2 && (
            <p className="text-[11px] leading-relaxed text-gray-500">
              Zaps raw DIEM straight into csDIEM (stakes into sDIEM
              internally). No 24h delay.
            </p>
          )}
          <AmountInput
            value={wrapAmt}
            onChange={setWrapAmt}
            max={diem.balance}
            disabled={csdiem.paused}
          />
          <AllowanceHint
            allowance={diemForCs.allowance}
            needsApproval={wrapNeedsApproval}
            unlimitedThreshold={UNLIMITED_THRESHOLD}
          />
          <ActionButton
            needsApproval={wrapNeedsApproval}
            onApprove={() => csdiemApproval.approve()}
            onAction={handleWrap}
            actionLabel="Wrap"
            disabled={!wrapAmt || wrapAmt === "0" || csdiem.paused}
            loading={wrapping}
          />
        </div>

        {/* v2-only: atomic sDIEM v2 → csDIEM v2 via standard ERC-4626 deposit.
            The v2 vault's asset() is sDIEM v2, so existing stakers can wrap
            without going through the 24h Venice cooldown. */}
        {isV2 && (
          <div className="space-y-2 rounded-lg border border-border bg-card-inner p-3">
            <p className="text-xs font-medium text-gray-300">
              Wrap sDIEM → csDIEM
            </p>
            <p className="text-[11px] leading-relaxed text-gray-500">
              Already staking sDIEM? Wrap it directly — atomic, no 24h
              delay. Rewards accrued by your sDIEM stay with the position.
            </p>
            <AmountInput
              value={wrapSDiemAmt}
              onChange={setWrapSDiemAmt}
              max={sdiemAsToken.balance}
              disabled={csdiem.paused}
            />
            {sdiemAsToken.allowance < UNLIMITED_THRESHOLD && (
              <p className="text-[10px] text-gray-500">
                Current sDIEM allowance:{" "}
                <span className="font-mono text-gray-400">
                  {formatDiem(sdiemAsToken.allowance)} sDIEM
                </span>
              </p>
            )}
            <ActionButton
              needsApproval={wrapSDiemNeedsApproval}
              onApprove={() => sdiemToCsdiemApproval.approve()}
              onAction={handleWrapSDiem}
              actionLabel="Wrap sDIEM"
              disabled={
                !wrapSDiemAmt ||
                wrapSDiemAmt === "0" ||
                csdiem.paused ||
                sdiemAsToken.balance === 0n
              }
              loading={wrappingSDiem}
            />
            <TxStatus
              isPending={
                depositSDiemCs.isPending || sdiemToCsdiemApproval.isPending
              }
              isConfirming={
                depositSDiemCs.isConfirming || sdiemToCsdiemApproval.isConfirming
              }
              isSuccess={depositSDiemCs.isSuccess}
              error={depositSDiemCs.error ?? sdiemToCsdiemApproval.error}
              hash={depositSDiemCs.hash ?? sdiemToCsdiemApproval.hash}
              onReset={() => {
                depositSDiemCs.reset();
                sdiemToCsdiemApproval.reset();
              }}
            />
          </div>
        )}

        <div className="space-y-2 rounded-lg border border-border bg-card-inner p-3">
          <p className="text-xs font-medium text-gray-300">
            Unwrap csDIEM → {isV2 ? "sDIEM" : "DIEM"}
          </p>
          {isV2 && (
            <p className="text-[11px] leading-relaxed text-gray-500">
              Atomic, one tx — returns sDIEM to your wallet immediately.
              To exit to raw DIEM, then withdraw the sDIEM on the Withdraw
              tab (24h Venice cooldown).
            </p>
          )}
          <AmountInput
            value={redeemAmt}
            onChange={setRedeemAmt}
            max={csdiem.userShares}
            disabled={csdiem.paused}
          />
          <ActionButton
            needsApproval={false}
            onApprove={() => {}}
            onAction={isV2 ? handleSyncRedeem : handleRequestRedeem}
            actionLabel={isV2 ? "Unwrap" : "Request Unwrap (24h delay)"}
            disabled={!redeemAmt || redeemAmt === "0" || csdiem.userShares === 0n}
            loading={isV2 ? redeemingV2 : redeemingV1}
          />
        </div>

        <TxStatus
          isPending={
            depositCs.isPending ||
            requestRedeemCs.isPending ||
            redeemCsV2.isPending ||
            csdiemApproval.isPending
          }
          isConfirming={
            depositCs.isConfirming ||
            requestRedeemCs.isConfirming ||
            redeemCsV2.isConfirming ||
            csdiemApproval.isConfirming
          }
          isSuccess={
            depositCs.isSuccess || requestRedeemCs.isSuccess || redeemCsV2.isSuccess
          }
          error={
            depositCs.error ??
            requestRedeemCs.error ??
            redeemCsV2.error ??
            csdiemApproval.error
          }
          hash={
            depositCs.hash ??
            requestRedeemCs.hash ??
            redeemCsV2.hash ??
            csdiemApproval.hash
          }
          onReset={() => {
            depositCs.reset();
            requestRedeemCs.reset();
            redeemCsV2.reset();
            csdiemApproval.reset();
          }}
        />
      </div>
    ),
  };

  const tabs = csdiemAvailable
    ? [stakeTab, withdrawTab, wrapTab]
    : [stakeTab, withdrawTab];

  return (
    <VaultCard
      title="sDIEM"
      subtitle="Stake DIEM, earn USDC"
      badge={apr !== null ? `${apr.toFixed(2)}% APR` : undefined}
    >
      {sdiem.paused && <PausedBanner />}

      <StatRow
        label="Total Staked"
        value={`${formatDiem(sdiem.totalStaked)} DIEM`}
      />
      <StatRow label="Your Staked" value={`${formatDiem(sdiem.userStaked)} DIEM`} />
      <StatRow label="USDC Earned" value={`${formatUsdc(sdiem.earned)} USDC`} />
      <div className="flex items-center justify-between py-2">
        <span className="text-sm text-gray-400">Reward Period</span>
        <CountdownTimer periodFinish={sdiem.periodFinish} />
      </div>

      {isConnected && sdiem.earned > 0n && (
        <div className="mt-2">
          <button
            onClick={() => claimAction.claim()}
            disabled={claiming || sdiem.paused}
            className="w-full rounded-xl border border-accent/40 py-2.5 text-sm font-medium text-accent transition hover:bg-accent/10 disabled:opacity-40"
          >
            {claiming ? "Claiming..." : "Claim USDC"}
          </button>
          <TxStatus
            isPending={claimAction.isPending}
            isConfirming={claimAction.isConfirming}
            isSuccess={claimAction.isSuccess}
            error={claimAction.error}
            hash={claimAction.hash}
            onReset={claimAction.reset}
          />
        </div>
      )}

      {isConnected && <DepositWithdrawTabs tabs={tabs} />}
    </VaultCard>
  );
}
