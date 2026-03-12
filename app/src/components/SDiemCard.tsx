"use client";

import { useState, useMemo } from "react";
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

import { useSDiem } from "@/hooks/useSDiem";
import { useDiemToken } from "@/hooks/useDiemToken";
import { useApproval } from "@/hooks/useApproval";
import { useStake } from "@/hooks/useStake";
import { useRequestWithdraw, useCompleteWithdraw } from "@/hooks/useWithdrawSDiem";
import { useClaimReward } from "@/hooks/useClaimReward";
import { useExit } from "@/hooks/useExit";
import { DIEM_TOKEN, SDIEM_ADDRESS, DIEM_DECIMALS } from "@/config/contracts";
import { formatDiem, formatUsdc } from "@/lib/format";
import { calcSDiemApr } from "@/lib/apr";

const WITHDRAWAL_DELAY = 24n * 60n * 60n; // 24h in seconds

export function SDiemCard() {
  const { isConnected } = useAccount();
  const sdiem = useSDiem();
  const diem = useDiemToken(SDIEM_ADDRESS);
  const approval = useApproval(DIEM_TOKEN, SDIEM_ADDRESS);
  const stakeAction = useStake();
  const requestAction = useRequestWithdraw();
  const completeAction = useCompleteWithdraw();
  const claimAction = useClaimReward();
  const exitAction = useExit();

  const [stakeAmt, setStakeAmt] = useState("");
  const [withdrawAmt, setWithdrawAmt] = useState("");

  const apr = calcSDiemApr(sdiem.rewardRate, sdiem.totalStaked);
  const needsApproval =
    stakeAmt !== "" &&
    diem.allowance < parseUnits(stakeAmt || "0", DIEM_DECIMALS);

  const handleStake = () => {
    if (!stakeAmt) return;
    const amount = parseUnits(stakeAmt, DIEM_DECIMALS);
    stakeAction.stake(amount);
  };

  const handleRequestWithdraw = () => {
    if (!withdrawAmt) return;
    const amount = parseUnits(withdrawAmt, DIEM_DECIMALS);
    requestAction.requestWithdraw(amount);
  };

  const staking =
    approval.isPending || approval.isConfirming ||
    stakeAction.isPending || stakeAction.isConfirming;
  const requesting =
    requestAction.isPending || requestAction.isConfirming;
  const completing =
    completeAction.isPending || completeAction.isConfirming;
  const claiming =
    claimAction.isPending || claimAction.isConfirming;
  const exiting =
    exitAction.isPending || exitAction.isConfirming;

  const hasPending = sdiem.pendingWithdrawAmount > 0n;
  const unlockTime = sdiem.pendingWithdrawRequestedAt + WITHDRAWAL_DELAY;
  const canComplete = useMemo(() => {
    if (!hasPending) return false;
    const now = BigInt(Math.floor(Date.now() / 1000));
    return now >= unlockTime;
  }, [hasPending, unlockTime]);

  return (
    <VaultCard
      title="sDIEM"
      subtitle="Stake DIEM, earn USDC"
      badge={apr !== null ? `${apr}% APR` : undefined}
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
            className="w-full rounded-xl border border-gold/40 py-2.5 text-sm font-medium text-gold transition hover:bg-gold/10 disabled:opacity-40"
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

      {isConnected && (
        <DepositWithdrawTabs
          tabs={[
            {
              label: "Stake",
              content: (
                <div className="space-y-3">
                  <AmountInput
                    value={stakeAmt}
                    onChange={setStakeAmt}
                    max={diem.balance}
                    disabled={sdiem.paused}
                  />
                  <ActionButton
                    needsApproval={needsApproval}
                    onApprove={() => approval.approve()}
                    onAction={handleStake}
                    actionLabel="Stake DIEM"
                    disabled={!stakeAmt || stakeAmt === "0" || sdiem.paused}
                    loading={staking}
                  />
                  <TxStatus
                    isPending={stakeAction.isPending || approval.isPending}
                    isConfirming={stakeAction.isConfirming || approval.isConfirming}
                    isSuccess={stakeAction.isSuccess}
                    error={stakeAction.error ?? approval.error}
                    hash={stakeAction.hash ?? approval.hash}
                    onReset={() => { stakeAction.reset(); approval.reset(); }}
                  />
                </div>
              ),
            },
            {
              label: "Withdraw",
              content: (
                <div className="space-y-3">
                  {/* Pending withdrawal banner */}
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
                      <button
                        onClick={() => completeAction.completeWithdraw()}
                        disabled={!canComplete || completing}
                        className="mt-2 w-full rounded-lg border border-green-500/40 py-2 text-sm font-medium text-green-400 transition hover:bg-green-500/10 disabled:opacity-40"
                      >
                        {completing ? "Completing..." : "Complete Withdrawal"}
                      </button>
                      <TxStatus
                        isPending={completeAction.isPending}
                        isConfirming={completeAction.isConfirming}
                        isSuccess={completeAction.isSuccess}
                        error={completeAction.error}
                        hash={completeAction.hash}
                        onReset={completeAction.reset}
                      />
                    </div>
                  )}

                  {/* Request new withdrawal */}
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
                    disabled={!withdrawAmt || withdrawAmt === "0" || sdiem.paused}
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
            },
          ]}
        />
      )}
    </VaultCard>
  );
}
