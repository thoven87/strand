import { cn } from "@/lib/utils";
import { ChevronDown } from "lucide-react";
import { type SelectHTMLAttributes, forwardRef } from "react";

interface SelectProps extends SelectHTMLAttributes<HTMLSelectElement> {
  /** Extra wrapper classes (controls layout / width). */
  wrapperClassName?: string;
}

/**
 * Styled select that matches the Button/Badge visual language.
 * Wrap options as normal children:
 *
 * ```tsx
 * <Select value={val} onChange={…}>
 *   <option value="">All queues</option>
 *   {queues.map(q => <option key={q} value={q}>{q}</option>)}
 * </Select>
 * ```
 */
export const Select = forwardRef<HTMLSelectElement, SelectProps>(
  ({ className, wrapperClassName, children, ...props }, ref) => (
    <div className={cn("relative inline-flex items-center", wrapperClassName)}>
      <select
        ref={ref}
        className={cn(
          // layout
          "h-7 w-full appearance-none rounded border border-border pl-2.5 pr-7",
          // colours
          "bg-secondary/30 text-foreground",
          // typography
          "text-xs font-medium",
          // interaction
          "cursor-pointer transition-colors",
          "hover:bg-secondary/50",
          "focus:outline-none focus:ring-1 focus:ring-ring",
          // options inherit dark background on most browsers that support it
          "[&>option]:bg-[color:var(--color-secondary)]",
          "[&>option]:text-foreground",
          className,
        )}
        {...props}
      >
        {children}
      </select>
      {/* Custom chevron — sits over the right edge, pointer-events-none */}
      <ChevronDown
        size={13}
        className="pointer-events-none absolute right-2 text-muted-foreground"
      />
    </div>
  ),
);
Select.displayName = "Select";
