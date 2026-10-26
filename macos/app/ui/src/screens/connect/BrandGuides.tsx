import { VENDOR_NAMES, WIRELESS_VENDORS, type CameraVendor } from "../../api";
import { Screen, useStack } from "../routes";
import { EmptyState, SectionCard } from "../../components/common";
import { Icon } from "../../components/Icon";
import { BRAND_GUIDES, guideFor, type GuideStep } from "./guideData";

export function BrandGuides() {
  const { push } = useStack();
  return (
    <Screen title="Setup guides" readable>
      <div className="stack">
        <div className="form-group" style={{ background: "var(--surface-2)", borderRadius: 14, padding: 4 }}>
          {BRAND_GUIDES.map((g) => (
            <button key={g.vendor} className="list-row interactive" onClick={() => push({ kind: "brandGuide", vendor: g.vendor })}>
              <div className="col fill" style={{ gap: 2 }}>
                <div className="row">
                  <span className="t-headline">{VENDOR_NAMES[g.vendor]}</span>
                  <span className="spacer" />
                  {g.vendor !== "ricoh" && g.vendor !== "gopro" && g.vendor !== "osc" ? <Icon name="cable.connector" size={13} className="ink-2" title="USB" /> : null}
                  {WIRELESS_VENDORS.includes(g.vendor) ? <Icon name="wifi" size={13} className="ink-2" title="Wi-Fi" /> : null}
                </div>
                <span className="t-hud ink-1" style={{ display: "-webkit-box", WebkitLineClamp: 2, WebkitBoxOrient: "vertical", overflow: "hidden" }}>{g.summary}</span>
              </div>
              <Icon name="chevron.right" size={13} className="ink-2" />
            </button>
          ))}
        </div>
        <span className="t-hud ink-2">Any other PTP camera imports over USB: Open Tether watches for new files and downloads them, without remote capture.</span>
      </div>
    </Screen>
  );
}

function Steps({ title, icon, steps }: { title: string; icon: string; steps: GuideStep[] }) {
  return (
    <SectionCard title={title} icon={icon}>
      {steps.map((s, i) => (
        <div key={i} className="row-top">
          <span className="guide-step-icon"><Icon name={s.symbol} size={18} /></span>
          <span className="t-callout ink-0">{i + 1}. {s.text}</span>
        </div>
      ))}
    </SectionCard>
  );
}

export function BrandGuideDetail({ vendor }: { vendor: CameraVendor }) {
  const g = guideFor(vendor);
  return (
    <Screen title={VENDOR_NAMES[vendor]} readable>
      {g ? (
        <div className="stack">
          <span className="t-callout">{g.summary}</span>
          {g.wired.length ? <Steps title="USB-C" icon="cable.connector" steps={g.wired} /> : null}
          {g.wireless.length ? <Steps title="Wi-Fi" icon="wifi" steps={g.wireless} /> : null}
          {g.notes.length ? (
            <SectionCard title="Good to know" icon="lightbulb">
              {g.notes.map((n) => <span key={n} className="t-callout">• {n}</span>)}
            </SectionCard>
          ) : null}
        </div>
      ) : (
        <EmptyState icon="book" title="No guide yet" message="This brand connects as a generic PTP camera over USB." />
      )}
    </Screen>
  );
}
