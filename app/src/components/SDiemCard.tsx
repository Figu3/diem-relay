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
import { useDepositCSDiem } from "@/hooks/useDepositCSDiem";
import {
  useRequestRedeemCSDiem,
  useCompleteRedeemCSDiem,
  useCancelRedeemCSDiem,
} from "@/hooks/useRedeemCSDiem";
import { DIEM_TOKEN, SDIEM_ADDRESS, CSDIEM_ADDRESS, DIEM_DECIMALS } from "@/config/contracts";
import { formatDiem, formatUsdc } from "@/lib/format";
import { calcSDiemApr } from "@/lib/apr";

const CSDIEM_TOOLTIP = (
  <>
    <strong className="text-accent">csDIEM</strong> auto-compounds your yield:
    instead of receiving USDC, your stake earns <em>more DIEM</em> over time as
    rewards are harvested and re-staked. Same 24h withdrawal delay applies; exit
    uses request → wait → complete.
  </>
);

export function SDiemCard() {
  const { isConnected } = useAccount();
  const sdiem = useSDiem();
  const csdiem = useCSDiem();
  const { priceUsd: diemPriceUsd } = useDiemPrice();
  // Two reads of the DIEM token, one per spender, for the two allowance
  // surfaces. balance is the same on both — use whichever; we use diem.balance.
  const diem = useDiemToken(SDIEM_ADDRESS);
  const diemForCs = useDiemToken(CSDIEM_ADDRESS);

  // Approvals — DIEM may need to be approved for either sDIEM or csDIEM.
  const sdiemApproval = useApproval(DIEM_TOKEN, SDIEM_ADDRESS);
  const csdiemApproval = useApproval(DIEM_TOKEN, CSDIEM_ADDRESS);

  // Actions
  const stakeAction = useStake();
  const depositCs = useDepositCSDiem();
  const requestAction = useRequestWithdraw();
  const completeAction = useCompleteWithdraw();
  const cancelAction = useCancelWithdraw();
  const claimAction = useClaimReward();
  const exitAction = useExit();
  const requestRedeemCs = useRequestRedeemCSDiem();
  const completeRedeemCs = useCompleteRedeemCSDiem();
  const cancelRedeemCs = useCancelRedeemCSDiem();

  const [stakeAmt, setStakeAmt] = useState("");
  const [withdrawAmt, setWithdrawAmt] = useState("");
  const [wrapAmt, setWrapAmt] = useState("");
  const [redeemAmt, setRedeemAmt] = useState("");
  const [autoCompound, setAutoCompound] = useState(false);

  const apr = calcSDiemApr(sdiem.rewardRate, sdiem.totalStaked, diemPriceUsd);

  // ── Stake-tab approval routing ────────────────────────────────────────
  // When auto-compound is on, stake flow targets csDIEM instead of sDIEM —
  // approval target switches accordingly.
  const stakeTarget = autoCompound && isCSDiemDeployed ? "csdiem" : "sdiem";
  const activeApproval = stakeTarget === "csdiem" ? csdiemApproval : sdiemApproval;
  const allowanceForStake =
    stakeTarget === "csdiem" ? diemForCs.allowance : diem.allowance;
  const needsApproval =
    stakeAmt !== "" &&
    allowanceForStake < parseUnits(stakeAmt || "0", DIEM_DECIMALS);

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

  const handleWrap = () => {
    if (!wrapAmt) return;
    depositCs.deposit(parseUnits(wrapAmt, DIEM_DECIMALS));
  };

  const handleRequestRedeem = () => {
    if (!redeemAmt) return;
    // redeemAmt is denominated in csDIEM shares (treated like DIEM for UX
    // since 1 share ≈ 1 DIEM at deploy with the 1e6 virtual offset; the
    // user types in shares for now).
    requestRedeemCs.requestRedeem(parseUnits(redeemAmt, DIEM_DECIMALS));
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
  const redeeming = requestRedeemCs.isPending || requestRedeemCs.isConfirming;
  const completingCs = completeRedeemCs.isPending || completeRedeemCs.isConfirming;
  const cancellingCs = cancelRedeemCs.isPending || cancelRedeemCs.isConfirming;

  const hasPending = sdiem.pendingWithdrawAmount > 0n;
  const unlockTime = sdiem.pendingWithdrawRequestedAt + sdiem.withdrawalDelay;
  const canComplete = sdiem.canComplete;

  const csUnlockTime =
    csdiem.pendingRedemption.requestedAt + csdiem.withdrawalDelay;
  const hasCsPending = csdiem.pendingRedemption.assets > 0n;

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
        {isCSDiemDeployed && (
          <label className="flex cursor-pointer items-center gap-2 text-xs text-gray-400">
            <input
              type="checkbox"
              checked={autoCompound}
              onChange={(e) => setAutoCompound(e.target.checked)}
              disabled={csdiem.paused}
              className="h-3.5 w-3.5 cursor-pointer accent-accent disabled:cursor-not-allowed"
            />
            <span>
              Auto-compound yield in DIEM (csDIEM)
            </span>
            <Tooltip content={CSDIEM_TOOLTIP}>
              <span className="text-[10px]">ⓘ</span>
            </Tooltip>
          </label>
        )}
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
          <AmountInput
            value={wrapAmt}
            onChange={setWrapAmt}
            max={diem.balance}
            disabled={csdiem.paused}
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

        <div className="space-y-2 rounded-lg border border-border bg-card-inner p-3">
          <p className="text-xs font-medium text-gray-300">Unwrap csDIEM → DIEM</p>
          <AmountInput
            value={redeemAmt}
            onChange={setRedeemAmt}
            max={csdiem.userShares}
            disabled={csdiem.paused}
          />
          <ActionButton
            needsApproval={false}
            onApprove={() => {}}
            onAction={handleRequestRedeem}
            actionLabel="Request Unwrap (24h delay)"
            disabled={!redeemAmt || redeemAmt === "0" || csdiem.userShares === 0n}
            loading={redeeming}
          />
        </div>

        <TxStatus
          isPending={depositCs.isPending || requestRedeemCs.isPending || csdiemApproval.isPending}
          isConfirming={
            depositCs.isConfirming ||
            requestRedeemCs.isConfirming ||
            csdiemApproval.isConfirming
          }
          isSuccess={depositCs.isSuccess || requestRedeemCs.isSuccess}
          error={depositCs.error ?? requestRedeemCs.error ?? csdiemApproval.error}
          hash={depositCs.hash ?? requestRedeemCs.hash ?? csdiemApproval.hash}
          onReset={() => {
            depositCs.reset();
            requestRedeemCs.reset();
            csdiemApproval.reset();
          }}
        />
      </div>
    ),
  };

  const tabs = isCSDiemDeployed
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
