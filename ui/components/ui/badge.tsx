import { cn } from "@/lib/utils";

type BadgeVariant = "green" | "blue" | "orange" | "red" | "gray";

interface BadgeProps {
  variant?: BadgeVariant;
  className?: string;
  children: React.ReactNode;
}

const variantMap: Record<BadgeVariant, string> = {
  green:  "badge-green",
  blue:   "badge-blue",
  orange: "badge-orange",
  red:    "badge-red",
  gray:   "badge-gray",
};

export function Badge({ variant = "gray", className, children }: BadgeProps) {
  return (
    <span className={cn("badge", variantMap[variant], className)}>
      {children}
    </span>
  );
}
