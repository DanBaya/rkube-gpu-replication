#!/usr/bin/env python3
import csv, os, statistics as st, sys
REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CSV = os.path.join(REPO,"results","raw","cpu.csv"); OUT = os.path.join(REPO,"analysis")
L = {"A":"A solo","B":"B capped neighbours","C":"C burstable neighbours"}
rows=[]
for r in csv.DictReader(open(CSV)):
    if int(r["trial"])==1: continue
    rows.append({"cond":r["condition"],"ratio":float(r["delivery_ratio"]),
        "throttled":int(r["nr_throttled"]),"bogo":float(r["bogo_ops_per_sec"])})
def agg(c,k):
    v=[r[k] for r in rows if r["cond"]==c]
    return {"n":len(v),"mean":st.mean(v),"sd":st.stdev(v) if len(v)>1 else 0.0,
            "min":min(v),"max":max(v)} if v else None
conds=[c for c in "ABC" if any(r["cond"]==c for r in rows)]
o=["## Delivery ratio and throughput, warmup discarded\n",
   "| Condition | n | Ratio mean | SD | Min | Max | nr_throttled | Bogo ops/s | SD |","|---|---|---|---|---|---|---|---|---|"]
for c in conds:
    r,t,b=agg(c,"ratio"),agg(c,"throttled"),agg(c,"bogo")
    o.append(f"| {L[c]} | {r['n']} | {r['mean']:.4f} | {r['sd']:.4f} | {r['min']:.4f} | {r['max']:.4f} | {t['mean']:.1f} | {b['mean']:.0f} | {b['sd']:.0f} |")
ra,ba=agg("A","ratio")["mean"],agg("A","bogo")["mean"]
o+=["\n## Delivered time against delivered work, normalised to A\n",
    "| Condition | Ratio rel. A | Throughput rel. A | Work per delivered usec |","|---|---|---|---|"]
for c in conds:
    rr=agg(c,"ratio")["mean"]/ra; bb=agg(c,"bogo")["mean"]/ba
    o.append(f"| {L[c]} | {rr:.3f} | {bb:.3f} | {bb/rr:.3f} |")
o.append("\n## Shortfall against reservation\n")
for c in conds:
    m=agg(c,"ratio")["mean"]
    o.append(f"- {L[c]}: received {m*12:.2f} of 12 reserved CPUs, shortfall {(1-m)*100:.1f} percent")
out="\n".join(o); print(out)
os.makedirs(OUT,exist_ok=True); open(os.path.join(OUT,"summary.md"),"w").write(out+"\n")
try:
    import matplotlib; matplotlib.use("Agg"); import matplotlib.pyplot as plt
    m=[agg(c,"ratio")["mean"] for c in conds]; s=[agg(c,"ratio")["sd"] for c in conds]
    f,ax=plt.subplots(figsize=(7,4.5))
    ax.bar([L[c] for c in conds],m,yerr=s,capsize=6,color=["#4a7c59","#c9a227","#a63d40"])
    ax.axhline(1.0,ls="--",lw=1,c="black"); ax.set_ylim(0,1.15)
    ax.set_ylabel("Delivery ratio (delivered / reserved)")
    ax.set_title("CPU delivered against 12 CPU reservation, error bars 1 SD")
    for i,v in enumerate(m): ax.text(i,v+0.02,f"{v:.3f}",ha="center")
    f.tight_layout(); f.savefig(os.path.join(OUT,"figure1_delivery_ratio.png"),dpi=150)
    print("\nwrote analysis/figure1_delivery_ratio.png")
except ImportError: print("\nmatplotlib missing, figure skipped",file=sys.stderr)
