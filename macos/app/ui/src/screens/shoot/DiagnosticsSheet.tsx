import { Sheet } from "../../components/Sheet";
import { DiagnosticsBody } from "../connect/Diagnostics";

/** The status pill expands into the diagnostics checklist. */
export function DiagnosticsSheet({ wired, onClose }: { wired: boolean; onClose: () => void }) {
  return (
    <Sheet title={wired ? "Cable diagnostic" : "Wireless diagnostic"} onClose={onClose} width={560} height="min(640px, calc(100vh - 48px))">
      <DiagnosticsBody wired={wired} />
    </Sheet>
  );
}
