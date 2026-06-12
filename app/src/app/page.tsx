"use client";

import { useEffect, useMemo, useState } from 'react';
import {
  useAccount,
  useChainId,
  useReadContracts,
  useSwitchChain,
  useWaitForTransactionReceipt,
  useWriteContract,
} from 'wagmi';
import { base } from 'wagmi/chains';
import { formatUnits, parseUnits, type Address } from 'viem';
import { Header } from '@/components/Header';
import { csDiemV2Abi, erc20Abi, revenueSplitterAbi, sDiemV2Abi } from '@/config/abis';
import { CSDIEM_V2_ADDRESS, DIEM_TOKEN, REVENUE_SPLITTER_ADDRESS, SDIEM_V2_ADDRESS, USDC_BASE } from '@/config/contracts';
import {
  CHEAPTOKENS_BUY_URL,
  CONTRACTS_SECTION_URL,
  DIEMPOOL_URL,
  GITHUB_URL,
  VENICE_URL,
} from '@/config/protocol-links';


type SupplyMode = 'liquid' | 'direct';
type ActionMode = 'supply' | 'withdraw' | 'convert';
type ConvertMode = 'wrap' | 'unwrap';
type WithdrawMode = 'liquid' | 'exit';

const ZERO_ADDRESS = '0x0000000000000000000000000000000000000000' as Address;
const DAY_SECONDS = 86_400n;
const CSDIEM_DECIMALS = 24;

function formatToken(value: bigint, decimals = 18, maxFraction = 4) {
  const numeric = Number(formatUnits(value, decimals));
  if (!Number.isFinite(numeric)) return '0';
  return numeric.toLocaleString(undefined, {
    maximumFractionDigits: numeric >= 100 ? 2 : maxFraction,
  });
}

function formatUsd(value: bigint, maxFraction = 2) {
  const numeric = Number(formatUnits(value, 6));
  if (!Number.isFinite(numeric)) return '$0.00';
  return numeric.toLocaleString(undefined, {
    style: 'currency',
    currency: 'USD',
    maximumFractionDigits: maxFraction,
  });
}

function formatApy(usdcPerDiemDay: bigint) {
  const annualPercent = Number(formatUnits(usdcPerDiemDay, 6)) * 365 * 100;
  if (!Number.isFinite(annualPercent) || annualPercent <= 0) return '0%';
  return `${annualPercent.toLocaleString(undefined, {
    maximumFractionDigits: annualPercent >= 100 ? 0 : 2,
  })}%`;
}

function shortAddress(address: Address) {
  return `${address.slice(0, 6)}...${address.slice(-4)}`;
}

function parseDiemAmount(value: string) {
  try {
    return value.trim() ? parseUnits(value, 18) : 0n;
  } catch {
    return 0n;
  }
}

function parseCsDiemAmount(value: string) {
  try {
    return value.trim() ? parseUnits(value, CSDIEM_DECIMALS) : 0n;
  } catch {
    return 0n;
  }
}

function secondsUntil(timestamp: bigint) {
  const now = BigInt(Math.floor(Date.now() / 1000));
  return timestamp > now ? timestamp - now : 0n;
}

function formatDuration(seconds: bigint) {
  const total = Number(seconds);
  const hours = Math.floor(total / 3600);
  const minutes = Math.floor((total % 3600) / 60);
  if (hours <= 0) return `${minutes}m`;
  return `${hours}h ${minutes}m`;
}

function minBigInt(a: bigint, b: bigint) {
  return a < b ? a : b;
}

export default function PoolPage() {
  const { address, isConnected } = useAccount();
  const chainId = useChainId();
  const { switchChain, isPending: isSwitching } = useSwitchChain();
  const [actionMode, setActionMode] = useState<ActionMode>('supply');
  const [mode, setMode] = useState<SupplyMode>('liquid');
  const [convertMode, setConvertMode] = useState<ConvertMode>('wrap');
  const [withdrawMode, setWithdrawMode] = useState<WithdrawMode>('liquid');
  const [depositAmount, setDepositAmount] = useState('');
  const [redeemAmount, setRedeemAmount] = useState('');
  const [withdrawAmount, setWithdrawAmount] = useState('');

  const account = address ?? ZERO_ADDRESS;
  const diem = DIEM_TOKEN as Address;
  const usdc = USDC_BASE as Address;
  const sdiem = SDIEM_V2_ADDRESS as Address;
  const csdiem = CSDIEM_V2_ADDRESS as Address;
  const revenueSplitter = REVENUE_SPLITTER_ADDRESS as Address;
  const spender = mode === 'liquid' ? sdiem : csdiem;
  const parsedDeposit = parseDiemAmount(depositAmount);
  const parsedRedeem = parseCsDiemAmount(redeemAmount);
  const parsedWithdraw = parseDiemAmount(withdrawAmount);
  const isBase = chainId === base.id;

  const reads = useReadContracts({
    contracts: [
      { address: diem, abi: erc20Abi, functionName: 'balanceOf', args: [account] },
      { address: diem, abi: erc20Abi, functionName: 'allowance', args: [account, csdiem] },
      { address: diem, abi: erc20Abi, functionName: 'allowance', args: [account, sdiem] },
      { address: sdiem, abi: sDiemV2Abi, functionName: 'balanceOf', args: [account] },
      { address: sdiem, abi: sDiemV2Abi, functionName: 'earned', args: [account] },
      { address: sdiem, abi: sDiemV2Abi, functionName: 'withdrawalRequests', args: [account] },
      { address: sdiem, abi: sDiemV2Abi, functionName: 'canCompleteWithdraw', args: [account] },
      { address: sdiem, abi: sDiemV2Abi, functionName: 'totalStaked' },
      { address: sdiem, abi: sDiemV2Abi, functionName: 'totalSupply' },
      { address: sdiem, abi: sDiemV2Abi, functionName: 'balanceOf', args: [csdiem] },
      { address: sdiem, abi: sDiemV2Abi, functionName: 'rewardRate' },
      { address: sdiem, abi: sDiemV2Abi, functionName: 'periodFinish' },
      { address: sdiem, abi: sDiemV2Abi, functionName: 'paused' },
      { address: csdiem, abi: csDiemV2Abi, functionName: 'totalSupply' },
      { address: csdiem, abi: csDiemV2Abi, functionName: 'balanceOf', args: [account] },
      { address: csdiem, abi: csDiemV2Abi, functionName: 'convertToAssets', args: [parseUnits('1', 18)] },
      { address: csdiem, abi: csDiemV2Abi, functionName: 'previewRedeem', args: [parsedRedeem] },
      { address: csdiem, abi: csDiemV2Abi, functionName: 'maxRedeem', args: [account] },
      { address: csdiem, abi: csDiemV2Abi, functionName: 'paused' },
      { address: sdiem, abi: erc20Abi, functionName: 'allowance', args: [account, csdiem] },
      { address: csdiem, abi: csDiemV2Abi, functionName: 'previewDeposit', args: [parsedDeposit] },
      { address: revenueSplitter, abi: revenueSplitterAbi, functionName: 'totalStakerPaid' },
      { address: usdc, abi: erc20Abi, functionName: 'balanceOf', args: [revenueSplitter] },
      { address: revenueSplitter, abi: revenueSplitterAbi, functionName: 'minAmount' },
      { address: sdiem, abi: sDiemV2Abi, functionName: 'veniceCooldownEnd' },
      { address: diem, abi: erc20Abi, functionName: 'balanceOf', args: [sdiem] },
      { address: diem, abi: erc20Abi, functionName: 'stakedInfos', args: [sdiem] },
    ],
    query: { refetchInterval: 20_000 },
  });

  const results = reads.data as Array<{ result?: unknown; status?: string }> | undefined;
  const read = <T,>(index: number, fallback: T): T =>
    results?.[index]?.status === 'success' ? (results[index].result as T) : fallback;

  const diemBalance = read<bigint>(0, 0n);
  const csAllowance = read<bigint>(1, 0n);
  const sAllowance = read<bigint>(2, 0n);
  const sdiemBalance = read<bigint>(3, 0n);
  const pendingUsdc = read<bigint>(4, 0n);
  const withdrawalRequest = read<readonly [bigint, bigint]>(5, [0n, 0n]);
  const canCompleteWithdraw = read<boolean>(6, false);
  const totalStaked = read<bigint>(7, 0n);
  const sdiemTotalSupply = read<bigint>(8, 0n);
  const sdiemWrappedSupply = read<bigint>(9, 0n);
  const rewardRate = read<bigint>(10, 0n);
  const periodFinish = read<bigint>(11, 0n);
  const sdiemPaused = read<boolean>(12, false);
  const csTotalSupply = read<bigint>(13, 0n);
  const csBalance = read<bigint>(14, 0n);
  const csSharePrice = read<bigint>(15, parseUnits('1', 18));
  const redeemPreview = read<bigint>(16, 0n);
  const maxRedeem = read<bigint>(17, 0n);
  const csdiemPaused = read<boolean>(18, false);
  const sdiemToCsAllowance = read<bigint>(19, 0n);
  const convertPreview = read<bigint>(20, 0n);
  const totalUsdcDistributed = read<bigint>(21, 0n);
  const splitterUsdcBalance = read<bigint>(22, 0n);
  const splitterMinAmount = read<bigint>(23, 0n);
  const veniceCooldownEnd = read<bigint>(24, 0n);
  const vaultLiquidDiem = read<bigint>(25, 0n);
  const vaultStakedInfo = read<readonly [bigint, bigint, bigint]>(26, [0n, 0n, 0n]);
  const vaultVenicePendingDiem = vaultStakedInfo[2] ?? 0n;
  const circulatingSdiemSupply =
    sdiemTotalSupply > sdiemWrappedSupply ? sdiemTotalSupply - sdiemWrappedSupply : 0n;
  const withdrawUsesCsdiem = withdrawMode !== 'liquid';
  const convertUsesCsdiem = convertMode === 'unwrap';
  const withdrawInputAmount = withdrawUsesCsdiem ? redeemAmount : withdrawAmount;
  const parsedWithdrawInput = withdrawUsesCsdiem ? parsedRedeem : parsedWithdraw;
  const withdrawBalance = withdrawUsesCsdiem ? maxRedeem : sdiemBalance;
  const withdrawToken = withdrawUsesCsdiem ? 'csDIEM' : 'sDIEM';
  const withdrawBalanceLabel = withdrawUsesCsdiem
    ? formatToken(withdrawBalance, CSDIEM_DECIMALS)
    : formatToken(withdrawBalance);
  const convertInputAmount = convertUsesCsdiem ? redeemAmount : depositAmount;
  const parsedConvertInput = convertUsesCsdiem ? parsedRedeem : parsedDeposit;
  const convertBalance = convertUsesCsdiem ? maxRedeem : sdiemBalance;
  const convertToken = convertUsesCsdiem ? 'csDIEM' : 'sDIEM';
  const convertBalanceLabel = convertUsesCsdiem
    ? formatToken(convertBalance, CSDIEM_DECIMALS)
    : formatToken(convertBalance);
  const depositToken = 'DIEM';
  const depositBalance = diemBalance;
  const activeAllowance = mode === 'direct' ? csAllowance : sAllowance;
  const approvalToken = diem;
  const needsApproval = parsedDeposit > 0n && parsedDeposit > activeAllowance;
  const convertNeedsApproval = convertMode === 'wrap' && parsedDeposit > 0n && parsedDeposit > sdiemToCsAllowance;

  const dailyReward = rewardRate * DAY_SECONDS;
  const usdcPerDiemDay = totalStaked > 0n ? (dailyReward * parseUnits('1', 18)) / totalStaked : 0n;
  const rewardStreamActive = dailyReward > 0n && totalStaked > 0n && secondsUntil(periodFinish) > 0n;
  const currentApyLabel = rewardStreamActive ? formatApy(usdcPerDiemDay) : '0%';
  const splitterWaitingForFloor = splitterUsdcBalance > 0n && splitterMinAmount > 0n && splitterUsdcBalance < splitterMinAmount;
  const apyStatusLabel = sdiemPaused || csdiemPaused
    ? 'Vault paused'
    : splitterWaitingForFloor
      ? `${formatUsd(splitterUsdcBalance)} pending; distributes at ${formatUsd(splitterMinAmount)}`
      : 'Paid in USDC on Base';
  const withdrawalAmount = withdrawalRequest[0] ?? 0n;
  const withdrawalStart = withdrawalRequest[1] ?? 0n;
  const withdrawalReadyAt = withdrawalStart + DAY_SECONDS;
  const withdrawalWait = secondsUntil(withdrawalReadyAt);
  const veniceWait = secondsUntil(veniceCooldownEnd);
  const maturedVeniceDiem = veniceWait === 0n ? vaultVenicePendingDiem : 0n;
  const nextClaimableDiem = withdrawalWait > 0n
    ? 0n
    : minBigInt(withdrawalAmount, vaultLiquidDiem + maturedVeniceDiem);
  const remainingAfterNextClaim = withdrawalAmount > nextClaimableDiem
    ? withdrawalAmount - nextClaimableDiem
    : 0n;
  const withdrawalStatus = nextClaimableDiem >= withdrawalAmount && withdrawalAmount > 0n
    ? 'Ready to claim'
    : nextClaimableDiem > 0n
      ? `${formatToken(nextClaimableDiem)} DIEM claimable now`
    : withdrawalWait > 0n
      ? `Request timer: ${formatDuration(withdrawalWait)} left`
      : veniceWait > 0n
        ? `Next batch unlocking: ${formatDuration(veniceWait)} left`
        : 'Waiting for vault liquidity';
  const withdrawalSummaryStatus = nextClaimableDiem >= withdrawalAmount && withdrawalAmount > 0n
    ? 'Ready to claim'
    : nextClaimableDiem > 0n
      ? `${formatToken(nextClaimableDiem)} DIEM claimable now`
    : withdrawalWait > 0n
      ? `Request timer: ${formatDuration(withdrawalWait)} remaining`
      : veniceWait > 0n
        ? `Next batch unlocking: ${formatDuration(veniceWait)} remaining`
        : 'Waiting for vault liquidity';

  const connectedLabel = useMemo(() => {
    if (!isConnected || !address) return 'Wallet not connected';
    return `${shortAddress(address)} on ${isBase ? 'Base' : 'wrong network'}`;
  }, [address, isBase, isConnected]);

  const { writeContract, data: txHash, isPending: isWriting, error: writeError } = useWriteContract();
  const receipt = useWaitForTransactionReceipt({ hash: txHash });

  useEffect(() => {
    if (receipt.isSuccess) {
      reads.refetch();
    }
  }, [receipt.isSuccess, reads]);

  const isBusy = isWriting || receipt.isLoading || isSwitching;
  const modePaused = mode === 'liquid' ? sdiemPaused : csdiemPaused;
  const disableReason = !isConnected
    ? 'Connect wallet'
    : !isBase
      ? 'Switch to Base'
      : modePaused
        ? mode === 'liquid' ? 'Staking paused' : 'Conversion paused'
        : parsedDeposit <= 0n
          ? 'Enter amount'
          : parsedDeposit > depositBalance
            ? `Insufficient ${depositToken}`
            : '';
  const withdrawDisableReason = !isConnected
    ? 'Connect wallet'
    : !isBase
      ? 'Switch to Base'
      : withdrawUsesCsdiem && csdiemPaused
        ? 'Conversion paused'
      : withdrawMode === 'liquid' && withdrawalAmount > 0n
        ? 'Withdrawal queued'
        : parsedWithdrawInput <= 0n
          ? 'Enter amount'
          : parsedWithdrawInput > withdrawBalance
            ? `Insufficient ${withdrawToken}`
            : '';
  const convertDisableReason = !isConnected
    ? 'Connect wallet'
    : !isBase
      ? 'Switch to Base'
      : csdiemPaused
        ? 'Conversion paused'
        : parsedConvertInput <= 0n
          ? 'Enter amount'
          : parsedConvertInput > convertBalance
            ? `Insufficient ${convertToken}`
            : '';

  const handlePrimaryAction = () => {
    if (!isConnected) return;
    if (!isBase) {
      switchChain({ chainId: base.id });
      return;
    }
    if (needsApproval) {
      writeContract({
        address: approvalToken,
        abi: erc20Abi,
        functionName: 'approve',
        args: [spender, parsedDeposit],
      });
      return;
    }
    if (mode === 'direct') {
      writeContract({
        address: csdiem,
        abi: csDiemV2Abi,
        functionName: 'depositDIEM',
        args: [parsedDeposit, account],
      });
      return;
    }
    writeContract({
      address: sdiem,
      abi: sDiemV2Abi,
      functionName: 'stake',
      args: [parsedDeposit],
    });
  };

  const handleClaim = () => {
    writeContract({ address: sdiem, abi: sDiemV2Abi, functionName: 'claimReward' });
  };

  const handleRedeem = () => {
    writeContract({
      address: csdiem,
      abi: csDiemV2Abi,
      functionName: 'redeem',
      args: [parsedRedeem, account, account],
    });
  };

  const handleRequestWithdraw = () => {
    writeContract({
      address: sdiem,
      abi: sDiemV2Abi,
      functionName: 'requestWithdraw',
      args: [parsedWithdraw],
    });
  };

  const handleWithdrawAction = () => {
    if (!isConnected) return;
    if (!isBase) {
      switchChain({ chainId: base.id });
      return;
    }
    if (withdrawUsesCsdiem) {
      handleRedeem();
      return;
    }
    handleRequestWithdraw();
  };

  const handleConvertAction = () => {
    if (!isConnected) return;
    if (!isBase) {
      switchChain({ chainId: base.id });
      return;
    }
    if (convertMode === 'wrap') {
      if (convertNeedsApproval) {
        writeContract({
          address: sdiem,
          abi: erc20Abi,
          functionName: 'approve',
          args: [csdiem, parsedDeposit],
        });
        return;
      }
      writeContract({
        address: csdiem,
        abi: csDiemV2Abi,
        functionName: 'deposit',
        args: [parsedDeposit, account],
      });
      return;
    }
    handleRedeem();
  };

  const handleCompleteWithdraw = () => {
    writeContract({ address: sdiem, abi: sDiemV2Abi, functionName: 'completeWithdraw' });
  };

  const handleCancelWithdraw = () => {
    writeContract({ address: sdiem, abi: sDiemV2Abi, functionName: 'cancelWithdraw' });
  };

  return (
    <>
      <Header />
      <div className="pool-page">
      <div className="pool-shell">
        <section className="pool-hero pool-hero-compact">
          <div>
            <div className="pool-kicker">Staking vault</div>
            <h1 className="pool-title">Stake Diem, earn USDC</h1>
            <p className="pool-subtitle">
              Stake your DIEM tokens. Let others use the inference credits.
              Get paid daily in USDC.
            </p>
          </div>
          <div className="pool-status-card">
            <span>Net APY</span>
            <strong>{currentApyLabel}</strong>
            <small>{apyStatusLabel}</small>
          </div>
        </section>

        <section className="pool-app-grid">
          <div className="pool-panel pool-primary-panel">
            <div className="pool-action-tabs">
              <button
                className={actionMode === 'supply' ? 'pool-action-tab-active' : ''}
                onClick={() => setActionMode('supply')}
                type="button"
              >
                Supply
              </button>
              <button
                className={actionMode === 'withdraw' ? 'pool-action-tab-active' : ''}
                onClick={() => setActionMode('withdraw')}
                type="button"
              >
                Withdraw
              </button>
              <button
                className={actionMode === 'convert' ? 'pool-action-tab-active' : ''}
                onClick={() => setActionMode('convert')}
                type="button"
              >
                Convert
              </button>
            </div>

            {actionMode === 'supply' ? (
              <div className="pool-form pool-form-main">
                <div className="pool-panel-header pool-inline-header">
                  <div>
                    <h2 className="pool-panel-title">Supply DIEM</h2>
                    <p className="pool-panel-copy">Choose liquid rewards or compounding vault mode.</p>
                  </div>
                </div>

                <div className="pool-token-tabs">
                  <button
                    className={mode === 'liquid' ? 'pool-token-tab-active' : ''}
                    onClick={() => setMode('liquid')}
                    type="button"
                  >
                    <strong>sDIEM</strong>
                    <span>Transferable ERC-20 receipt with EIP-2612 permit. Claim streamed USDC manually.</span>
                  </button>
                  <button
                    className={mode === 'direct' ? 'pool-token-tab-active' : ''}
                    onClick={() => setMode('direct')}
                    type="button"
                  >
                    <strong>Enter csDIEM</strong>
                    <span>Zap DIEM into csDIEM. Rewards compound into the vault share price.</span>
                  </button>
                </div>

                {!isConnected ? (
                  <div className="pool-connect">Connect a wallet to supply DIEM.</div>
                ) : (
                  <>
                    <div className="pool-input-row pool-input-row-large">
                      <div className="pool-input-meta">
                        <span>Supply amount</span>
                        <span>Wallet: {formatToken(depositBalance)} {depositToken}</span>
                      </div>
                      <div className="pool-input-line">
                        <input
                          className="pool-input"
                          inputMode="decimal"
                          onChange={(event) => setDepositAmount(event.target.value)}
                          placeholder="0.0"
                          value={depositAmount}
                        />
                        <button
                          className="pool-small-button"
                          onClick={() => setDepositAmount(formatUnits(depositBalance, 18))}
                          type="button"
                        >
                          MAX
                        </button>
                        <span className="pool-token">{depositToken}</span>
                      </div>
                    </div>

                    <div className="pool-preview pool-preview-quiet">
                      <div className="pool-preview-row">
                        <span>You receive</span>
                        <strong>
                          {mode === 'liquid'
                            ? 'sDIEM'
                            : 'csDIEM'}
                        </strong>
                      </div>
                      <div className="pool-preview-row">
                        <span>Rewards</span>
                        <strong>{mode === 'liquid' ? 'Claim USDC manually' : 'Compounds into csDIEM share price'}</strong>
                      </div>
                      <div className="pool-preview-row">
                        <span>Current APY</span>
                        <strong>{currentApyLabel}</strong>
                      </div>
                    </div>

                    <button
                      className="pool-action"
                      disabled={isBusy || (!!disableReason && disableReason !== 'Switch to Base') || (isBase && needsApproval && parsedDeposit <= 0n)}
                      onClick={handlePrimaryAction}
                      type="button"
                    >
                      {!isBase && isConnected
                        ? 'Switch to Base'
                        : needsApproval
                          ? `Approve ${depositToken}`
                          : disableReason ||
                            (mode === 'liquid'
                              ? 'Supply DIEM'
                              : 'Supply as csDIEM')}
                    </button>
                  </>
                )}
              </div>
            ) : actionMode === 'withdraw' ? (
              <div className="pool-form pool-form-main">
                <div className="pool-panel-header pool-inline-header">
                  <div>
                    <h2 className="pool-panel-title">Withdraw DIEM</h2>
                    <p className="pool-panel-copy">Pick the exit path. sDIEM queues a Venice cooldown; csDIEM exits back through sDIEM first.</p>
                  </div>
                </div>

                <div className="pool-token-tabs">
                  <button
                    className={withdrawMode === 'liquid' ? 'pool-token-tab-active' : ''}
                    onClick={() => setWithdrawMode('liquid')}
                    type="button"
                  >
                    <strong>sDIEM</strong>
                    <span>Request DIEM withdrawal after the cooldown</span>
                  </button>
                  <button
                    className={withdrawMode === 'exit' ? 'pool-token-tab-active' : ''}
                    onClick={() => setWithdrawMode('exit')}
                    type="button"
                  >
                    <strong>Exit csDIEM</strong>
                    <span>Convert, then withdraw DIEM</span>
                  </button>
                </div>

                {!isConnected ? (
                  <div className="pool-connect">Connect a wallet to withdraw DIEM.</div>
                ) : (
                  <>
                    <div className="pool-input-row pool-input-row-large">
                      <div className="pool-input-meta">
                        <span>Withdraw amount</span>
                        <span>Balance: {withdrawBalanceLabel} {withdrawToken}</span>
                      </div>
                      <div className="pool-input-line">
                        <input
                          className="pool-input"
                          inputMode="decimal"
                          onChange={(event) =>
                            withdrawUsesCsdiem
                              ? setRedeemAmount(event.target.value)
                              : setWithdrawAmount(event.target.value)
                          }
                          placeholder="0.0"
                          value={withdrawInputAmount}
                        />
                        <button
                          className="pool-small-button"
                          onClick={() =>
                            withdrawUsesCsdiem
                              ? setRedeemAmount(formatUnits(maxRedeem, CSDIEM_DECIMALS))
                              : setWithdrawAmount(formatUnits(sdiemBalance, 18))
                          }
                          type="button"
                        >
                          MAX
                        </button>
                        <span className="pool-token">{withdrawToken}</span>
                      </div>
                    </div>

                    <div className="pool-preview pool-preview-quiet">
                      <div className="pool-preview-row">
                        <span>You receive</span>
                        <strong>{withdrawUsesCsdiem ? `${formatToken(redeemPreview)} sDIEM` : 'DIEM after cooldown'}</strong>
                      </div>
                      <div className="pool-preview-row">
                        <span>Next step</span>
                        <strong>
                          {withdrawMode === 'exit'
                            ? 'Then request DIEM withdrawal'
                            : 'Complete after 24h'}
                        </strong>
                      </div>
                      {withdrawalAmount > 0n && (
                        <div className="pool-preview-row">
                          <span>Queued withdrawal</span>
                          <strong>
                            {formatToken(withdrawalAmount)} DIEM · {withdrawalStatus}
                          </strong>
                        </div>
                      )}
                    </div>

                    <button
                      className="pool-action"
                      disabled={isBusy || (!!withdrawDisableReason && withdrawDisableReason !== 'Switch to Base')}
                      onClick={handleWithdrawAction}
                      type="button"
                    >
                      {!isBase && isConnected
                        ? 'Switch to Base'
                        : withdrawDisableReason ||
                          (withdrawMode === 'exit'
                            ? 'Start exit: convert csDIEM'
                            : 'Request withdrawal')}
                    </button>

                    {withdrawalAmount > 0n && (
                      <button
                        className="pool-secondary-action pool-secondary-action-full"
                        disabled={isBusy || !isConnected}
                        onClick={canCompleteWithdraw ? handleCompleteWithdraw : handleCancelWithdraw}
                        type="button"
                      >
                        {canCompleteWithdraw ? 'Claim available DIEM' : 'Cancel queued withdrawal'}
                      </button>
                    )}
                  </>
                )}
              </div>
            ) : (
              <div className="pool-form pool-form-main">
                <div className="pool-panel-header pool-inline-header">
                  <div>
                    <h2 className="pool-panel-title">Convert</h2>
                    <p className="pool-panel-copy">Move between liquid sDIEM and auto-compounding csDIEM without leaving the vault.</p>
                  </div>
                </div>

                <div className="pool-token-tabs">
                  <button
                    className={convertMode === 'wrap' ? 'pool-token-tab-active' : ''}
                    onClick={() => setConvertMode('wrap')}
                    type="button"
                  >
                    <strong>sDIEM to csDIEM</strong>
                    <span>Compound future USDC into the csDIEM share price</span>
                  </button>
                  <button
                    className={convertMode === 'unwrap' ? 'pool-token-tab-active' : ''}
                    onClick={() => setConvertMode('unwrap')}
                    type="button"
                  >
                    <strong>csDIEM to sDIEM</strong>
                    <span>Return to liquid sDIEM before claiming or withdrawing</span>
                  </button>
                </div>

                {!isConnected ? (
                  <div className="pool-connect">Connect a wallet to convert DIEM receipts.</div>
                ) : (
                  <>
                    <div className="pool-input-row pool-input-row-large">
                      <div className="pool-input-meta">
                        <span>Convert amount</span>
                        <span>Balance: {convertBalanceLabel} {convertToken}</span>
                      </div>
                      <div className="pool-input-line">
                        <input
                          className="pool-input"
                          inputMode="decimal"
                          onChange={(event) =>
                            convertUsesCsdiem
                              ? setRedeemAmount(event.target.value)
                              : setDepositAmount(event.target.value)
                          }
                          placeholder="0.0"
                          value={convertInputAmount}
                        />
                        <button
                          className="pool-small-button"
                          onClick={() =>
                            convertUsesCsdiem
                              ? setRedeemAmount(formatUnits(maxRedeem, CSDIEM_DECIMALS))
                              : setDepositAmount(formatUnits(sdiemBalance, 18))
                          }
                          type="button"
                        >
                          MAX
                        </button>
                        <span className="pool-token">{convertToken}</span>
                      </div>
                    </div>

                    <div className="pool-preview pool-preview-quiet">
                      <div className="pool-preview-row">
                        <span>You receive</span>
                        <strong>
                          {convertMode === 'wrap'
                            ? `${formatToken(convertPreview, CSDIEM_DECIMALS)} csDIEM`
                            : `${formatToken(redeemPreview)} sDIEM`}
                        </strong>
                      </div>
                      <div className="pool-preview-row">
                        <span>Rewards</span>
                        <strong>{convertMode === 'wrap' ? 'Auto-compound in csDIEM' : 'Claim USDC manually from sDIEM'}</strong>
                      </div>
                      <div className="pool-preview-row">
                        <span>Current APY</span>
                        <strong>{currentApyLabel}</strong>
                      </div>
                    </div>

                    <button
                      className="pool-action"
                      disabled={isBusy || (!!convertDisableReason && convertDisableReason !== 'Switch to Base') || (isBase && convertNeedsApproval && parsedDeposit <= 0n)}
                      onClick={handleConvertAction}
                      type="button"
                    >
                      {!isBase && isConnected
                        ? 'Switch to Base'
                        : convertNeedsApproval
                          ? 'Approve sDIEM'
                          : convertDisableReason ||
                            (convertMode === 'wrap' ? 'Convert to csDIEM' : 'Convert to sDIEM')}
                    </button>
                  </>
                )}
              </div>
            )}

            {txHash && (
              <div className="pool-tx pool-tx-main">
                {receipt.isLoading
                  ? 'Transaction submitted. Waiting for confirmation...'
                  : receipt.isSuccess
                    ? 'Transaction confirmed. Balances refreshed.'
                    : `Transaction: ${shortAddress(txHash as Address)}`}
              </div>
            )}
            {writeError && <div className="pool-tx pool-tx-main">Wallet error: {writeError.message}</div>}
          </div>

          <aside className="pool-panel pool-position-panel">
            <div className="pool-panel-header">
              <div>
                <h2 className="pool-panel-title">Position</h2>
                <p className="pool-panel-copy">{connectedLabel}</p>
              </div>
            </div>

            {!isConnected ? (
              <div className="pool-empty-state pool-empty-state-large">
                Connect a wallet to see supplied DIEM, claimable rewards, and withdrawal status.
              </div>
            ) : (
              <>
                {withdrawalAmount > 0n && (
                  <div className="pool-pending-card">
                    <div className="pool-pending-main">
                      <span>Pending withdrawal</span>
                      <strong>{formatToken(withdrawalAmount)} DIEM</strong>
                      <small>{withdrawalSummaryStatus}</small>
                      {remainingAfterNextClaim > 0n && nextClaimableDiem > 0n && (
                        <small>{formatToken(remainingAfterNextClaim)} DIEM stays queued after this claim</small>
                      )}
                    </div>
                    <button
                      className="pool-secondary-action"
                      disabled={isBusy}
                      onClick={canCompleteWithdraw ? handleCompleteWithdraw : handleCancelWithdraw}
                      type="button"
                    >
                      {canCompleteWithdraw ? 'Claim' : 'Cancel'}
                    </button>
                  </div>
                )}

                <div className="pool-position-summary">
                  <div className="pool-position-row">
                    <span>sDIEM balance</span>
                    <strong>{formatToken(sdiemBalance)} sDIEM</strong>
                  </div>
                  <div className="pool-position-row">
                    <span>csDIEM balance</span>
                    <strong>{formatToken(csBalance, CSDIEM_DECIMALS)} csDIEM</strong>
                  </div>
                  <div className="pool-position-row pool-position-row-action">
                    <div>
                      <span>Claimable USDC</span>
                      <strong>{formatUsd(pendingUsdc)}</strong>
                    </div>
                    <button
                      className="pool-secondary-action"
                      disabled={isBusy || pendingUsdc <= 0n}
                      onClick={handleClaim}
                      type="button"
                    >
                      Claim
                    </button>
                  </div>
                </div>
              </>
            )}
          </aside>
        </section>

        <section className="pool-vault-totals" aria-label="Vault totals">
          <div className="pool-vault-totals-header">
            <span>Vault totals</span>
            <small>Protocol-wide</small>
          </div>
          <div className="pool-vault-totals-grid">
            <div>
              <span>Total staked</span>
              <strong>{formatToken(totalStaked)} DIEM</strong>
            </div>
            <div>
              <span>sDIEM supply</span>
              <strong>{formatToken(circulatingSdiemSupply)} sDIEM</strong>
            </div>
            <div>
              <span>csDIEM supply</span>
              <strong>{formatToken(csTotalSupply, CSDIEM_DECIMALS)} csDIEM</strong>
            </div>
            <div>
              <span>USDC distributed</span>
              <strong>{formatUsd(totalUsdcDistributed)}</strong>
            </div>
          </div>
        </section>

        <section className="pool-powered-by" aria-label="Powered by">
          <span>Powered by</span>
          <div className="pool-powered-links">
            <a href={CHEAPTOKENS_BUY_URL} rel="noreferrer" target="_blank">
              <strong>CheapTokens.ai</strong>
              <small>Discounted inference credits</small>
            </a>
            <a href={VENICE_URL} rel="noreferrer" target="_blank">
              <strong>Venice.ai</strong>
              <small>Private AI infrastructure</small>
            </a>
            <a href={DIEMPOOL_URL} rel="noreferrer" target="_blank">
              <strong>DIEMpool.com</strong>
              <small>Staking interface partner</small>
            </a>
          </div>
        </section>

        <footer className="pool-links-footer">
          <a href="/docs">Docs</a>
          <a href={GITHUB_URL} rel="noreferrer" target="_blank">GitHub</a>
          <a href={CONTRACTS_SECTION_URL}>Contracts (BaseScan)</a>
        </footer>
      </div>
      </div>
    </>
  );
}
