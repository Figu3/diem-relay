"use client";

interface ActionButtonProps {
  needsApproval: boolean;
  onApprove: () => void;
  onAction: () => void;
  actionLabel: string;
  approveLabel?: string;
  disabled?: boolean;
  loading?: boolean;
}

export function ActionButton({
  needsApproval,
  onApprove,
  onAction,
  actionLabel,
  approveLabel = "Approve DIEM",
  disabled,
  loading,
}: ActionButtonProps) {
  const label = needsApproval ? approveLabel : actionLabel;
  const handler = needsApproval ? onApprove : onAction;

  return (
    <button
      onClick={handler}
      disabled={disabled || loading}
      className="w-full rounded-xl bg-gold py-3 text-sm font-semibold text-black transition hover:bg-gold-hover disabled:cursor-not-allowed disabled:opacity-40"
    >
      {loading ? "Processing..." : label}
    </button>
  );
}
