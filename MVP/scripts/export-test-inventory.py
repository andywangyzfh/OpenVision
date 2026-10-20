#!/usr/bin/env python3
"""Export executed test records, without inventing per-assertion evidence from totals."""
import argparse
import csv
from pathlib import Path
import re

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--evidence", required=True, type=Path)
parser.add_argument("--source", required=True)
parser.add_argument("--output", required=True, type=Path)
args = parser.parse_args()
root = Path(__file__).resolve().parents[2]
methods = {}
for path in (root / "MVP").rglob("*Tests.swift"):
    for number, line in enumerate(path.read_text().splitlines(), 1):
        match = re.search(r"func (test\w+)\(", line)
        if match:
            methods[match[1]] = (str(path.relative_to(root)), number)
rows = []


def add(kind, suite, name, granularity, mode, source, source_line, log, line):
    rows.append(dict(record_id=f"EXEC-{len(rows)+1:03}", kind=kind, suite=suite,
                     case_name=name, granularity=granularity, result="PASS",
                     execution_mode=mode, source_file=source, source_line=source_line,
                     evidence_file=log, evidence_line=line, tested_source=args.source,
                     live_account="NOT RUN", physical_glasses="NOT RUN"))


logs = ["local-b49c1db-core-xctest.txt", "local-b49c1db-subscription-xctest.txt",
        "local-b49c1db-ios-tests.txt"]
for log in logs:
    for number, line in enumerate((args.evidence / log).read_text().splitlines(), 1):
        match = re.search(r"Test Case '-\[([^ ]+) (test\w+)\]' passed", line)
        if not match:
            continue
        suite, name = match.groups()
        source, source_line = methods[name]
        mode = "真实代码，离线合成输入"
        if "PhotoServiceTests" in suite:
            mode = "真实控制层及UIKit，DAT硬件效果为替身；未初始化guard为真实代码"
        elif "SpeechServiceTests" in suite:
            mode = "真实控制层，STT/TTS/音频与时钟为替身"
        elif "KeychainStoreTests" in suite:
            mode = "真实系统Keychain，独立空宿主，随机service与合成凭据"
        elif "MVPFlowTests" in suite:
            mode = ("真实App及SDK启动，账号恢复关闭，无真实认证/推理"
                    if name == "testProductionStartupWithoutRestoringAnyAccount"
                    else "真实App界面，fixture账号/模型/硬件；无真实认证/推理")
        add("XCTest", suite, name, "单个XCTest方法", mode, source, source_line, log, number)

log = "local-b49c1db-portable.txt"
lines = (args.evidence / log).read_text().splitlines()
markers = [(120, "bilingual core", "CoreChecks", "MVP/Core/Checks/main.swift"),
           (43, "subscription contract", "SubscriptionChecks", "MVP/Subscription/Sources/SubscriptionChecks/main.swift"),
           (53, "production ConversationViewModel", "FlowChecks", "MVP/FlowChecks/FlowChecks.swift"),
           (28, "production ChatGPTPlanClient", "NetworkChecks", "MVP/NetworkChecks/NetworkChecks.swift"),
           (13, "production ChatGPTSessionStore", "AccountChecks", "MVP/AccountChecks/AccountChecks.swift"),
           (61, "production callback/listener", "CallbackChecks", "MVP/CallbackChecks/CallbackChecks.swift")]
previous = -1
for count, fragment, suite, source in markers:
    end = next(i for i, line in enumerate(lines) if line.startswith(f"PASS: {count} {fragment}"))
    cases = [(i + 1, line[6:]) for i, line in enumerate(lines[previous+1:end], previous+1)
             if line.startswith("PASS: ")]
    mode = {"FlowChecks": "真实VM，硬件/账号/模型为替身",
            "NetworkChecks": "真实URLSession/Client，全请求被URLProtocol拦截",
            "AccountChecks": "真实Store actor，内存存储/刷新/撤销为替身",
            "CallbackChecks": "真实127.0.0.1 HTTP listener，合成code，无系统OAuth浏览器"}.get(suite, "离线合成输入，无真实认证/推理")
    if suite in ("FlowChecks", "NetworkChecks", "AccountChecks"):
        if len(cases) != count:
            raise ValueError(f"{suite}: expected {count} named scenarios, found {len(cases)}")
        for line_number, name in cases:
            add("portable", suite, name, "具名场景", mode, source, "", log, line_number)
    else:
        # The saved runner prints only the aggregate. Never present individual assertions as traced.
        add("portable", suite, f"{count} assertions (aggregate evidence only)",
            "套件汇总；不是逐断言记录", mode, source, "", log, end + 1)
    previous = end

if len([row for row in rows if row["kind"] == "XCTest"]) != 61:
    raise ValueError("Expected 61 executed XCTest methods in this evidence set")
if len(rows) != 158:
    raise ValueError(f"Expected 155 named records plus 3 aggregates, found {len(rows)}")
args.output.parent.mkdir(parents=True, exist_ok=True)
with args.output.open("w", newline="", encoding="utf-8-sig") as stream:
    writer = csv.DictWriter(stream, fieldnames=list(rows[0]))
    writer.writeheader()
    writer.writerows(rows)
print(f"Exported {len(rows)} records: 61 XCTest, 94 named portable scenarios, 3 aggregate suites.")
