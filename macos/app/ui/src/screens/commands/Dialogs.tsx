import { useState } from "react";
import type { Modal } from "../../state/types";
import { Sheet, SheetActions } from "../../components/Sheet";
import { TextField } from "../../components/controls";

type ConfirmModal = Extract<Modal, { kind: "confirm" }>;
type RenameModal = Extract<Modal, { kind: "rename" }>;

export function ConfirmSheet({ modal, onClose }: { modal: ConfirmModal; onClose: () => void }) {
  return (
    <Sheet
      title={modal.title}
      onClose={onClose}
      width={440}
      footer={
        <SheetActions
          onCancel={onClose}
          cancelTitle={modal.cancelTitle ?? "Cancel"}
          primaryTitle={modal.confirmTitle}
          destructive={modal.destructive}
          onPrimary={() => {
            onClose();
            modal.onConfirm();
          }}
        />
      }
    >
      <p className="t-callout" style={{ margin: 0 }}>{modal.message}</p>
    </Sheet>
  );
}

export function RenameSheet({ modal, onClose }: { modal: RenameModal; onClose: () => void }) {
  const [value, setValue] = useState(modal.value);
  const save = () => {
    if (!value.trim()) return;
    onClose();
    modal.onSave(value.trim());
  };
  return (
    <Sheet title={modal.title} onClose={onClose} width={420} footer={<SheetActions onCancel={onClose} primaryTitle="Save" onPrimary={save} primaryDisabled={!value.trim()} />}>
      <TextField value={value} onChange={setValue} autoFocus label="Name" onSubmit={save} />
    </Sheet>
  );
}
