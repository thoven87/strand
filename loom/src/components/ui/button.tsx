import { cn } from "@/lib/utils";
import { type ButtonHTMLAttributes, forwardRef } from "react";

interface ButtonProps extends ButtonHTMLAttributes<HTMLButtonElement> {
  variant?: "default" | "outline" | "ghost" | "destructive";
  size?: "sm" | "md" | "lg" | "icon";
}

export const Button = forwardRef<HTMLButtonElement, ButtonProps>(
  ({ className, variant = "default", size = "md", ...props }, ref) => {
    const base =
      "inline-flex items-center justify-center gap-1.5 whitespace-nowrap rounded-md text-sm font-medium transition-colors focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring disabled:pointer-events-none disabled:opacity-40";
    const variants = {
      default: "bg-primary text-primary-foreground hover:bg-primary/90",
      outline:
        "border border-border bg-transparent hover:bg-secondary/60 hover:text-foreground text-muted-foreground",
      ghost:
        "hover:bg-secondary/60 hover:text-foreground text-muted-foreground",
      destructive:
        "bg-destructive/80 text-destructive-foreground hover:bg-destructive",
    };
    const sizes = {
      sm: "h-7 px-2.5 text-xs",
      md: "h-9 px-4 py-2",
      lg: "h-10 px-8",
      icon: "h-8 w-8",
    };
    return (
      <button
        ref={ref}
        className={cn(base, variants[variant], sizes[size], className)}
        {...props}
      />
    );
  },
);
Button.displayName = "Button";
