"""
Reads the event log written by the SetupProbe script
(MQL5/Files/SetupProbe_<symbol>.csv) and reports, per setup, what a <= 10 minute
scalp would have made after costs.

    python mt5/analyze_probe.py SetupProbe_BTCUSDm.csv
    python mt5/analyze_probe.py SetupProbe_BTCUSD.csv --commission 7.0
    python mt5/analyze_probe.py SetupProbe_BTCUSDm.csv --min-ratio 4 --hours 7-10,13-16

Every exit setting and filter is chosen on the in-sample part (IS) and then shown
on the out-of-sample part (OOS). Only the OOS column says anything about the
future. Judge nothing with fewer than ~300 OOS events.

--commission  per 1 lot, round trip, in account currency. Overrides what the
              script was run with (for Zero/Raw accounts).
--min-ratio   keep only events where fast ATR >= this x the round-trip cost
              (spread + commission): the cost gate.
--hours       keep only these entry hours, server time, e.g. "7-10,13-16".
--combo       exit setting for the breakdowns, e.g. sl1.00_tp2.00. Default: the
              best in-sample setting of each setup.
"""
import argparse
import re

import pandas as pd

HORIZONS = (1, 3, 5, 10)


def parse_hours(spec: str) -> set[int]:
    hours: set[int] = set()
    for part in spec.split(","):
        a, _, b = part.partition("-")
        hours.update(range(int(a), int(b or a) + 1))
    return hours


def stats(net: pd.Series, gross: pd.Series) -> pd.Series:
    pos, neg = net[net > 0].sum(), -net[net <= 0].sum()
    return pd.Series({
        "n": len(net),
        "win%": 100 * (net > 0).mean() if len(net) else float("nan"),
        "net$": net.mean(),
        "gross$": gross.mean(),
        "PF": pos / neg if neg > 0 else float("inf"),
        "total$": net.sum(),
    })


def combo_table(df: pd.DataFrame, combos: list[str]) -> pd.DataFrame:
    rows = {}
    for c in combos:
        parts = []
        for sample in ("IS", "OOS"):
            d = df[df["sample"] == sample]
            parts.append(stats(d[f"usd_{c}"], d[f"gusd_{c}"]).add_prefix(f"{sample} "))
        rows[c] = pd.concat(parts)
    table = pd.DataFrame(rows).T.sort_values("IS net$", ascending=False)
    return table.astype({"IS n": int, "OOS n": int})


def breakdown(df: pd.DataFrame, key: str, combo: str) -> pd.DataFrame:
    out = []
    for sample in ("IS", "OOS"):
        d = df[df["sample"] == sample]
        g = d.groupby(key, observed=True)
        t = pd.DataFrame({
            f"{sample} n": g.size(),
            f"{sample} win%": g[f"usd_{combo}"].apply(lambda s: 100 * (s > 0).mean()),
            f"{sample} net$": g[f"usd_{combo}"].mean(),
            f"{sample} gross$": g[f"gusd_{combo}"].mean(),
        })
        out.append(t)
    return pd.concat(out, axis=1)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("csv")
    ap.add_argument("--commission", type=float, default=None)
    ap.add_argument("--min-ratio", type=float, default=0.0)
    ap.add_argument("--hours", default="")
    ap.add_argument("--combo", default="")
    args = ap.parse_args()

    df = pd.read_csv(args.csv)
    if df.empty:
        print("No events.")
        return
    df["time"] = pd.to_datetime(df["time"], format="%Y.%m.%d %H:%M:%S")
    combos = [m.group(1) for c in df.columns if (m := re.fullmatch(r"net_(.+)", c))]
    comm = df["comm_usd"] if args.commission is None else args.commission * df["lots"]
    for c in combos:
        df[f"usd_{c}"] = df[f"net_{c}"] * df["usd_per_px"] - comm
        df[f"gusd_{c}"] = df[f"gross_{c}"] * df["usd_per_px"]
        df[f"r_{c}"] = df[f"usd_{c}"] / (df[f"sl_{c}"] * df["usd_per_px"])
    df["cost_px"] = df["spread"] + comm / df["usd_per_px"]
    df["atr_cost"] = df["atr"] / df["cost_px"]
    for h in HORIZONS:
        df[f"usd_{h}m"] = df[f"pnl_{h}"] * df["usd_per_px"] - comm

    filters = []
    if args.min_ratio > 0:
        df = df[df["atr_cost"] >= args.min_ratio]
        filters.append(f"ATR/cost >= {args.min_ratio}")
    if args.hours:
        df = df[df["hour"].isin(parse_hours(args.hours))]
        filters.append(f"hours {args.hours}")

    pd.set_option("display.width", 200)
    pd.set_option("display.max_columns", 30)
    pd.set_option("display.float_format", "{:.3f}".format)

    cut = df.loc[df["sample"] == "OOS", "time"].min()
    print(f"\n=== {args.csv}: {len(df)} events, {df.time.min()} to {df.time.max()}, OOS from {cut} ===")
    print(f"lots {df.lots.iloc[0]}, commission per trade {comm.mean():.3f}"
          f"{', filters: ' + ', '.join(filters) if filters else ''}")
    print("net$ = per trade after spread and commission; gross$ = mid to mid, before costs.")
    print(f"avg spread {df.spread.mean():.3f} | avg round-trip cost {df.cost_px.mean():.3f} | "
          f"avg fast ATR {df.atr.mean():.3f} | avg ATR/cost {df.atr_cost.mean():.1f} (price units)")

    ctrl = df[df.setup == "control"]
    for setup, d in df.groupby("setup"):
        n_oos = (d["sample"] == "OOS").sum()
        print(f"\n\n######## {setup}: {len(d)} events, {n_oos} out of sample"
              f"{'   !! fewer than 300 OOS events: not enough to judge' if n_oos < 300 else ''}")

        print("\n-- time exit only (no stop, no target), net $/trade --")
        print(d.groupby("sample")[[f"usd_{h}m" for h in HORIZONS]].mean()
              .reindex(["IS", "OOS"]).rename(columns=lambda c: c.replace("usd_", "exit ")))
        print("\n-- excursions within 10 min, in round-trip costs (IS) --")
        is_ = d[d["sample"] == "IS"]
        print(f"best move: median {(is_.mfe_10 / is_.cost_px).median():.1f}, "
              f"worst move: median {(is_.mae_10 / is_.cost_px).median():.1f}")

        table = combo_table(d, combos)
        print("\n-- every exit setting, sorted by IS net$ --")
        print(table[["IS n", "IS win%", "IS net$", "IS gross$", "IS PF",
                     "OOS n", "OOS win%", "OOS net$", "OOS gross$", "OOS PF", "OOS total$"]])

        combo = args.combo or table.index[0]
        if setup != "control" and not ctrl.empty:
            cg = ctrl[ctrl["sample"] == "IS"][f"gusd_{combo}"].mean()
            sg = is_[f"gusd_{combo}"].mean()
            print(f"\nEdge over no signal (IS, gross, {combo}): setup {sg:.3f} vs control {cg:.3f} "
                  f"= {sg - cg:+.3f} $/trade")

        print(f"\n-- breakdowns with {combo} "
              f"({'chosen' if args.combo else 'best in sample'}) --")
        d = d.copy()
        print("\nby side"); print(breakdown(d, "side", combo))
        print("\nby trend alignment (1 = with the EMA trend)"); print(breakdown(d, "aligned", combo))
        print("\nby hour (server time)"); print(breakdown(d, "hour", combo))
        try:
            d["ratio_q"] = pd.qcut(d["atr_cost"], 5, duplicates="drop")
            print("\nby ATR/cost quintile"); print(breakdown(d, "ratio_q", combo))
        except ValueError:
            pass


if __name__ == "__main__":
    main()
