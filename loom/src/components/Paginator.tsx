import { Button } from "@/components/ui/button";
import { ChevronLeft, ChevronRight } from "lucide-react";

interface Props {
  hasNext: boolean;
  hasPrev: boolean;
  onNext: () => void;
  onPrev: () => void;
}

export function Paginator({ hasNext, hasPrev, onNext, onPrev }: Props) {
  return (
    <div className="flex items-center justify-end gap-2 pt-3">
      <Button variant="outline" size="sm" onClick={onPrev} disabled={!hasPrev}>
        <ChevronLeft size={13} /> Prev
      </Button>
      <Button variant="outline" size="sm" onClick={onNext} disabled={!hasNext}>
        Next <ChevronRight size={13} />
      </Button>
    </div>
  );
}
