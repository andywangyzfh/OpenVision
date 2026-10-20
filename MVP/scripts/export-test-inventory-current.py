#!/usr/bin/env python3
"""Export the two explicitly scoped 2026-10-19 runs; never sum overlapping methods."""
import argparse
import csv
import json
from pathlib import Path
import re
import tarfile

p = argparse.ArgumentParser(description=__doc__)
p.add_argument("--evidence", required=True, type=Path)
p.add_argument("--output", required=True, type=Path)
a = p.parse_args()
baseline = "c5c375b8d4893c2d66db60a4c88231186f7cdac9"
supplement = "02e40d2629ff98586f138dbcd02ca0c1b869fe4b"
equivalence = json.loads((a.evidence / "tests-only-equivalence.json").read_text())
assert equivalence["full_suite_sha"] == baseline
assert equivalence["supplement_sha"] == supplement
assert equivalence["changed_paths"] == ["MVP/PlatformTests/AccountCoordinatorTests.swift"]
methods = {}
for sha, archive in [(baseline, "source-c5c375b.tar"), (supplement, "source-02e40d2.tar")]:
    with tarfile.open(a.evidence / archive) as t:
        for entry in t.getmembers():
            if not entry.isfile() or not entry.name.endswith("Tests.swift"):
                continue
            for number, line in enumerate(t.extractfile(entry).read().decode().splitlines(), 1):
                match = re.search(r"func (test\w+)\(", line)
                if match:
                    methods[sha, match[1]] = (entry.name, number)
rows = []


def add(kind, suite, name, mode, source, source_line, log, line, sha, granularity):
    rows.append(dict(record_id=f"CURRENT-{len(rows)+1:03}", kind=kind, suite=suite,
                     case_name=name, granularity=granularity, result="PASS", execution_mode=mode,
                     source_file=source, source_line=source_line, evidence_file=log,
                     evidence_line=line, tested_source=sha, live_account="NOT RUN", physical_glasses="NOT RUN"))


logs = [("test-core-final-c5c375b.log", baseline), ("test-sub-final-c5c375b.log", baseline),
        ("test-ios-final-c5c375b.log", baseline), ("test-platform-02e40d2.log", supplement)]
seen = set()
for log, sha in logs:
    for number, line in enumerate((a.evidence / log).read_text().splitlines(), 1):
        match = re.search(r"Test Case '-\[([^ ]+) (test\w+)\]' passed", line)
        if not match:
            continue
        suite, name = match.groups()
        # The later complete platform run replaces the 42 overlapping baseline records.
        if log == "test-ios-final-c5c375b.log" and "MVPFlowTests" not in suite:
            continue
        assert (suite, name) not in seen
        seen.add((suite, name))
        source, source_line = methods[sha, name]
        mode = "真实代码；离线合成输入"
        if "AccountCoordinatorTests" in suite:
            mode = "实际AccountService/Store；浏览器、token/JWKS网络及账号元数据为隔离替身"
        elif "KeychainStoreTests" in suite:
            mode = "真实iOS Keychain；空宿主、随机service、合成凭据"
        elif "PhotoServiceTests" in suite or "SpeechServiceTests" in suite:
            mode = "实际控制层；硬件、音频、识别、播报及时间为替身"
        elif "MVPFlowTests" in suite:
            mode = ("正式App与实际Keychain/AppSupport随机namespace；无真实账号"
                    if "KeychainPreflight" in name else
                    "实际App UI；普通/失败/fixture路径按方法区分；无真实认证或模型")
        add("XCTest", suite, name, mode, source, source_line, log, number, sha, "单个XCTest方法")

specs = [("CoreChecks", "core-checks.txt", 120, "MVP/Core/Checks/main.swift"),
         ("SubscriptionChecks", "subscription-checks.txt", 43, "MVP/Subscription/Sources/SubscriptionChecks/main.swift"),
         ("FlowChecks", "flow-checks.txt", 59, "MVP/FlowChecks/FlowChecks.swift"),
         ("NetworkChecks", "network-checks.txt", 28, "MVP/NetworkChecks/NetworkChecks.swift"),
         ("AccountChecks", "account-checks.txt", 39, "MVP/AccountChecks/AccountChecks.swift"),
         ("CallbackChecks", "callback-checks.txt", 61, "MVP/CallbackChecks/CallbackChecks.swift")]
for suite, log, count, source in specs:
    lines = (a.evidence / log).read_text().splitlines()
    aggregate = next(i for i, line in enumerate(lines) if line.startswith(f"PASS: {count} "))
    cases = [(i+1, line[6:]) for i, line in enumerate(lines[:aggregate]) if line.startswith("PASS: ")]
    named = suite in {"FlowChecks", "NetworkChecks", "AccountChecks"}
    mode = {"FlowChecks": "实际VM；账号/硬件/模型为替身", "NetworkChecks": "实际Client/URLSession；所有请求拦截",
            "AccountChecks": "实际Store；内存持久化及刷新/撤销替身", "CallbackChecks": "实际本机HTTP listener；合成code"}.get(suite, "离线合成输入")
    if named:
        assert len(cases) == count, (suite, len(cases))
        for line, name in cases:
            add("portable", suite, name, mode, source, "", log, line, baseline, "具名场景")
    else:
        add("portable", suite, f"{count} assertions (aggregate evidence only)", mode,
            source, "", log, aggregate+1, baseline, "套件汇总；不是逐断言记录")
assert len(seen) == 84 and len(rows) == 213, (len(seen), len(rows))
a.output.parent.mkdir(parents=True, exist_ok=True)
with a.output.open("w", newline="", encoding="utf-8-sig") as f:
    w = csv.DictWriter(f, fieldnames=list(rows[0]), lineterminator="\n")
    w.writeheader(); w.writerows(rows)
print("Exported 84 unique XCTest methods, 126 named scenarios, 3 aggregate suites; two scoped SHAs.")
