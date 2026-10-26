import { useState } from "react";
import { api, VENDOR_NAMES, WIRELESS_VENDORS, type CameraVendor } from "../../api";
import { useApp } from "../../state/store";
import { Sheet, SheetActions } from "../../components/Sheet";
import { FormRow, FormSection, Select, TextField } from "../../components/controls";

const defaultPort = (v: CameraVendor | null) => (v === "ricoh" || v === "osc" ? 80 : v === "gopro" ? 8080 : 15740);
const defaultHost = (v: CameraVendor | null) => (v === "ricoh" ? "192.168.0.1" : v === "gopro" ? "10.5.5.9" : v === "osc" ? "192.168.1.1" : null);

export function ManualIPSheet({ onClose }: { onClose: () => void }) {
  const [host, setHost] = useState("");
  const [port, setPort] = useState("15740");
  const [vendor, setVendor] = useState<CameraVendor | null>(null);
  const add = async () => {
    try {
      await api.discoveryAddManual({ host: host.trim(), port: Number(port) || defaultPort(vendor), vendor });
      onClose();
    } catch (e) {
      useApp.getState().fail(e);
    }
  };
  return (
    <Sheet title="Enter IP address" onClose={onClose} width={480} footer={<SheetActions onCancel={onClose} primaryTitle="Add" onPrimary={add} primaryDisabled={!host.trim()} />}>
      <FormSection title="Camera address">
        <FormRow label="Host"><div className="form-control"><TextField mono value={host} onChange={setHost} placeholder="192.168.1.2" autoFocus onSubmit={() => host.trim() && add()} label="Host or IP address" /></div></FormRow>
        <FormRow label="Port"><div className="form-control"><TextField mono value={port} onChange={(v) => setPort(v.replace(/\D/g, ""))} label="Port" /></div></FormRow>
      </FormSection>
      <FormSection title="Brand" footer="Ricoh GR: 192.168.0.1 · GoPro: 10.5.5.9 port 8080 · Theta: 192.168.1.1 · Insta360: 192.168.42.1. Everything else is PTP/IP on 15740.">
        <FormRow label="Brand">
          <div className="form-control">
            <Select<string>
              label="Brand"
              value={vendor ?? "detect"}
              options={[{ value: "detect", label: "Detect from the camera" }, ...WIRELESS_VENDORS.map((v) => ({ value: v, label: VENDOR_NAMES[v] }))]}
              onChange={(v) => {
                const next = v === "detect" ? null : (v as CameraVendor);
                setVendor(next);
                setPort(String(defaultPort(next)));
                const h = defaultHost(next);
                if (!host && h) setHost(h);
              }}
            />
          </div>
        </FormRow>
      </FormSection>
    </Sheet>
  );
}
