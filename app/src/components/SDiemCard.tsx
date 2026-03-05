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

import { useSDiem } from "@/hooks/useSDiem";
import { useDiemToken } from "@/hooks/useDiemToken";
import { useApproval } from "@/hooks/useApproval";
import { useStake } from "@/hooks/useStake";
import { useWithdrawSDiem } from "@/hooks/useWithdrawSDiem";
import { useClaimReward } from "@/hooks/useClaimReward";
import { useExit } from "@/hooks/useExit";
import { DIEM_TOKEN, SDIEM_ADDRESS, DIEM_DECIMALS } from "@/config/contracts";
import { formatDiem, formatUsdc } from "@/lib/format";
import { calcSDiemApr } from "@/lib/apr";

export function SDiemCard() {
  const { isConnected } = useAccount();
  const sdiem = useSDiem();
  const diem = useDiemToken(SDIEM_ADDRESS);
  const approval = useApproval(DIEM_TOKEN, SDIEM_ADDRESS);
  const stakeAction = useStake();
  const withdrawAction = useWithdrawSDiem();
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

  const handleWithdraw = () => {
    if (!withdrawAmt) return;
    const amount = parseUnits(withdrawAmt, DIEM_DECIMALS);
    withdrawAction.withdraw(amount);
  };

  const staking =
    approval.isPending || approval.isConfirming ||
    stakeAction.isPending || stakeAction.isConfirming;
  const withdrawing =
    withdrawAction.isPending || withdrawAction.isConfirming;
  const claiming =
    claimAction.isPending || claimAction.isConfirming;
  const exiting =
    exitAction.isPending || exitAction.isConfirming;

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
                  <AmountInput
                    value={withdrawAmt}
                    onChange={setWithdrawAmt}
                    max={sdiem.userStaked}
                    disabled={sdiem.paused}
                  />
                  <ActionButton
                    needsApproval={false}
                    onApprove={() => {}}
                    onAction={handleWithdraw}
                    actionLabel="Withdraw DIEM"
                    disabled={!withdrawAmt || withdrawAmt === "0" || sdiem.paused}
                    loading={withdrawing}
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
                    isPending={withdrawAction.isPending || exitAction.isPending}
                    isConfirming={withdrawAction.isConfirming || exitAction.isConfirming}
                    isSuccess={withdrawAction.isSuccess || exitAction.isSuccess}
                    error={withdrawAction.error ?? exitAction.error}
                    hash={withdrawAction.hash ?? exitAction.hash}
                    onReset={() => { withdrawAction.reset(); exitAction.reset(); }}
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
