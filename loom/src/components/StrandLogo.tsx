import { cn } from "@/lib/utils";

interface StrandLogoProps {
  /** Size in pixels for the icon mark. Default 24. */
  size?: number;
  /** Show the "Strand" wordmark next to the icon. Default true. */
  showWordmark?: boolean;
  className?: string;
}

export function StrandLogo({
  size = 40,
  showWordmark = true,
  className,
}: StrandLogoProps) {
  return (
    <div className={cn("flex items-center gap-2", className)}>
      <StrandMark size={size} />
      {showWordmark && (
        <span
          className="font-semibold tracking-tight text-foreground"
          style={{ fontSize: size * 0.75 }}
        >
          Strand
        </span>
      )}
    </div>
  );
}

/** The icon mark — a stylized strand/thread flowing through nodes. */
export function StrandMark({
  size = 40,
  className,
}: {
  size?: number;
  className?: string;
}) {
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 40 40"
      fill="none"
      xmlns="http://www.w3.org/2000/svg"
      className={className}
    >
      {/* Outer ring */}
      <circle
        cx="20"
        cy="20"
        r="17"
        stroke="currentColor"
        strokeWidth="1.5"
        opacity="0.2"
      />

      {/* Three nodes */}
      <circle cx="12" cy="10" r="3" fill="currentColor" />
      <circle cx="28" cy="20" r="3" fill="currentColor" />
      <circle cx="12" cy="30" r="3" fill="currentColor" />

      {/* Upper S-curve: top node → middle node */}
      <path
        d="M 12 13 C 12 17 18 17 20 19 C 22 21 28 20 28 17"
        stroke="currentColor"
        strokeWidth="2"
        strokeLinecap="round"
        fill="none"
      />

      {/* Lower S-curve: middle node → bottom node */}
      <path
        d="M 28 23 C 28 27 22 27 20 29 C 18 31 12 30 12 27"
        stroke="currentColor"
        strokeWidth="2"
        strokeLinecap="round"
        fill="none"
      />

      {/* Short connector stubs */}
      <line
        x1="12"
        y1="13"
        x2="12"
        y2="14"
        stroke="currentColor"
        strokeWidth="2"
        strokeLinecap="round"
        opacity="0.6"
      />
      <line
        x1="28"
        y1="17"
        x2="28"
        y2="23"
        stroke="currentColor"
        strokeWidth="2"
        strokeLinecap="round"
        opacity="0.6"
      />
      <line
        x1="12"
        y1="27"
        x2="12"
        y2="26"
        stroke="currentColor"
        strokeWidth="2"
        strokeLinecap="round"
        opacity="0.6"
      />
    </svg>
  );
}
