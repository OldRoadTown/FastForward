#!/usr/bin/env python3
"""Estimate longest mapped combinational paths in a Yosys JSON netlist.

The delay model intentionally matches the project-level estimates:
AND/OR=25/27.5/30ps, XOR=35ps, MUX=50/55/60ps, NOT/BUF=0ps.
This is a comparison proxy; sign-off still requires the fixed STA flow.
"""

import argparse
import json
from functools import lru_cache


DELAYS = {
    "low": {"$_AND_": 25.0, "$_OR_": 25.0, "$_XOR_": 35.0,
            "$_MUX_": 50.0, "$_NOT_": 0.0, "$_BUF_": 0.0},
    "nom": {"$_AND_": 27.5, "$_OR_": 27.5, "$_XOR_": 35.0,
            "$_MUX_": 55.0, "$_NOT_": 0.0, "$_BUF_": 0.0},
    "high": {"$_AND_": 30.0, "$_OR_": 30.0, "$_XOR_": 35.0,
             "$_MUX_": 60.0, "$_NOT_": 0.0, "$_BUF_": 0.0},
}


def is_seq(cell_type):
    return (cell_type.startswith("$_DFF") or cell_type.startswith("$_SDFF")
            or cell_type.startswith("$_DLATCH") or cell_type in {"$dff", "$adff"})


def bit_names(module):
    names = {}
    for name, net in module.get("netnames", {}).items():
        for index, bit in enumerate(net.get("bits", [])):
            if not isinstance(bit, int):
                continue
            label = name if len(net.get("bits", [])) == 1 else f"{name}[{index}]"
            old = names.get(bit)
            if old is None or (name.count("$") < old.count("$")
                               and len(label) <= len(old) + 24):
                names[bit] = label
    return names


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("json_netlist")
    parser.add_argument("--top", default="ff")
    parser.add_argument("--summary", action="store_true")
    args = parser.parse_args()

    with open(args.json_netlist, "r", encoding="utf-8") as handle:
        design = json.load(handle)
    module = design["modules"][args.top]
    cells = module.get("cells", {})
    names = bit_names(module)

    comb_driver = {}
    start_desc = {}
    endpoints = []

    for port_name, port in module.get("ports", {}).items():
        for index, bit in enumerate(port.get("bits", [])):
            if not isinstance(bit, int):
                continue
            label = f"port:{port_name}[{index}]"
            if port.get("direction") in {"input", "inout"}:
                start_desc.setdefault(bit, label)
            if port.get("direction") in {"output", "inout"}:
                endpoints.append((bit, label))

    for cell_name, cell in cells.items():
        cell_type = cell.get("type", "")
        directions = cell.get("port_directions", {})
        connections = cell.get("connections", {})
        if is_seq(cell_type):
            for port_name, bits in connections.items():
                direction = directions.get(port_name)
                for index, bit in enumerate(bits):
                    if not isinstance(bit, int):
                        continue
                    if direction == "output":
                        start_desc.setdefault(
                            bit, f"{cell_type}:{names.get(bit, cell_name)}")
                    elif direction == "input" and port_name in {"D", "E", "EN"}:
                        endpoints.append(
                            (bit, f"reg:{names.get(bit, cell_name)}:{port_name}[{index}]"))
            continue
        if cell_type == "FE" or cell_type.startswith("$scope"):
            for port_name, bits in connections.items():
                direction = directions.get(port_name)
                if port_name.lower() in {"clk", "rst_n", "reset"}:
                    continue
                for index, bit in enumerate(bits):
                    if not isinstance(bit, int):
                        continue
                    label = f"{cell_type}:{cell_name}:{port_name}[{index}]"
                    if direction == "output":
                        start_desc.setdefault(bit, label)
                    elif direction == "input":
                        endpoints.append((bit, label))
            continue
        if cell_type not in DELAYS["nom"]:
            continue
        input_bits = []
        output_bits = []
        for port_name, bits in connections.items():
            if directions.get(port_name) == "input":
                input_bits.extend(bit for bit in bits if isinstance(bit, int))
            elif directions.get(port_name) == "output":
                output_bits.extend(bit for bit in bits if isinstance(bit, int))
        for bit in output_bits:
            comb_driver[bit] = (cell_name, cell_type, tuple(input_bits))

    def solve(corner):
        active = set()

        @lru_cache(maxsize=None)
        def arrival(bit):
            if bit in start_desc or bit not in comb_driver:
                return 0.0, start_desc.get(bit, names.get(bit, f"bit:{bit}")), (), 0
            if bit in active:
                return 0.0, f"loop:{bit}", (), 0
            active.add(bit)
            cell_name, cell_type, inputs = comb_driver[bit]
            best = (0.0, "constant", (), 0)
            for input_bit in inputs:
                candidate = arrival(input_bit)
                if candidate[0] > best[0] or best[1] == "constant":
                    best = candidate
            active.remove(bit)
            delay = DELAYS[corner][cell_type]
            trace = best[2] + ((cell_name, cell_type, names.get(bit, f"bit:{bit}")),)
            return best[0] + delay, best[1], trace, best[3] + 1

        ranked = []
        for bit, endpoint in endpoints:
            delay, source, trace, depth = arrival(bit)
            counts = {}
            for _, cell_type, _ in trace:
                counts[cell_type] = counts.get(cell_type, 0) + 1
            ranked.append({"delay_ps": delay, "source": source,
                           "endpoint": endpoint, "gate_counts": counts,
                           "gate_depth": depth, "trace": trace})
        ranked.sort(key=lambda item: item["delay_ps"], reverse=True)
        return ranked

    paths = {corner: solve(corner) for corner in DELAYS}
    result = {
        "global": {corner: ranked[0] for corner, ranked in paths.items()},
        "thresholds": {
            corner: {
                "over_355_count": sum(p["delay_ps"] > 355.0 for p in ranked),
                "over_400_count": sum(p["delay_ps"] > 400.0 for p in ranked),
            }
            for corner, ranked in paths.items()
        },
        "top_nom": paths["nom"][:20],
    }
    if args.summary:
        result = {
            "global": {
                corner: {key: value for key, value in path.items()
                         if key != "trace"}
                for corner, path in result["global"].items()
            },
            "thresholds": result["thresholds"],
        }
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
