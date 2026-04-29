"use client";

import { useState, type ReactNode } from "react";

interface TooltipProps {
  content: ReactNode;
  children: ReactNode;
}

/**
 * Minimal hover/focus tooltip — pure CSS positioning, no floating-ui dep.
 * Works on touch via onClick toggle (mobile users tap the trigger).
 */
export function Tooltip({ content, children }: TooltipProps) {
  const [open, setOpen] = useState(false);

  return (
    <span
      className="relative inline-flex items-center"
      onMouseEnter={() => setOpen(true)}
      onMouseLeave={() => setOpen(false)}
      onFocus={() => setOpen(true)}
      onBlur={() => setOpen(false)}
    >
      <button
        type="button"
        onClick={(e) => {
          e.preventDefault();
          setOpen((v) => !v);
        }}
        className="cursor-help text-[#888] transition hover:text-gray-200"
        aria-label="More info"
      >
        {children}
      </button>
      {open && (
        <span
          role="tooltip"
          className="absolute bottom-full left-1/2 z-10 mb-2 w-56 -translate-x-1/2 rounded-lg border border-border bg-card-inner px-3 py-2 text-left text-[11px] leading-snug text-gray-300 shadow-lg"
        >
          {content}
        </span>
      )}
    </span>
  );
}
