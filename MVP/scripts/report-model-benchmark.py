#!/usr/bin/env python3
"""Summarize only recorded live runs; synthetic self-tests are never model rankings."""
import argparse
import csv
import json
from pathlib import Path
from statistics import median

TASKS = ('cn_practical', 'en_practical', 'context_42', 'vision_B')


def validate_rows(rows, models):
    if len(models) != len(set(models)) or not models:
        raise ValueError('Candidate model list must be nonempty and unique')
    if len(rows) > 39:
        raise ValueError('Request cap exceeded')
    ids, keys = set(), set()
    for row in rows:
        index = row.get('index')
        model, fixture, repetition = row.get('model'), row.get('fixture'), row.get('repetition')
        if not isinstance(index, int) or isinstance(index, bool) or not 1 <= index <= 39 or index in ids:
            raise ValueError('Invalid or duplicate request index')
        ids.add(index)
        if model not in models or fixture not in TASKS + ('vision_probe_A',):
            raise ValueError('Unexpected model or fixture')
        if isinstance(repetition, bool) or (fixture == 'vision_probe_A' and repetition != -1) or (fixture in TASKS and repetition not in (0, 1, 2)):
            raise ValueError('Invalid repetition')
        key = model, fixture, repetition
        if key in keys:
            raise ValueError('Duplicate model/fixture/repetition')
        keys.add(key)
        if row.get('outcome') not in ('success', 'failure'):
            raise ValueError('Invalid outcome')


def metric(row, milestone):
    for item in row.get('observations', []):
        if item.get('milestone') == milestone:
            value = item.get('elapsedNanoseconds')
            return value / 1_000_000 if isinstance(value, (float, int)) and not isinstance(value, bool) and value >= 0 else None
    return None


def complete(row):
    stages = [x.get('milestone') for x in row.get('observations', [])]
    return row.get('outcome') == 'success' and 'completed' in stages and 'returned' in stages and 'failed' not in stages and bool((row.get('answer') or '').strip())


def summarize(rows, models, ratings=None):
    validate_rows(rows, models)
    # Keep failures and missing samples in denominators. Median is conditional on success,
    # visibly alongside attempted/expected counts; never invent a tail percentile for n=3.
    cells = []
    for model in models:
        for fixture in TASKS:
            selected = [r for r in rows if r['model'] == model and r['fixture'] == fixture and r.get('repetition', -1) >= 0]
            succeeded = [r for r in selected if complete(r)]
            returned = [metric(r, 'returned') for r in succeeded]
            returned = [x for x in returned if x is not None]
            ttft = [metric(r, 'firstTextDelta') for r in succeeded]
            ttft = [x for x in ttft if x is not None]
            missing = len({0, 1, 2} - {r['repetition'] for r in selected})
            cells.append(dict(model=model, fixture=fixture, attempted=len(selected), expected=3,
                              succeeded=len(succeeded), failed=len(selected)-len(succeeded), missing=missing,
                              median_return_ms=median(returned) if returned else None,
                              min_return_ms=min(returned) if returned else None, max_return_ms=max(returned) if returned else None,
                              ttft_n=len(ttft), median_ttft_ms=median(ttft) if ttft else None))
    eligible = []
    for model in models:
        warm = [r for r in rows if r['model'] == model and r.get('repetition', -1) >= 0]
        probes = [r for r in rows if r['model'] == model and r['fixture'] == 'vision_probe_A']
        model_cells = [c for c in cells if c['model'] == model]
        enough = all(c['attempted'] == 3 and c['missing'] == 0 and c['succeeded'] == 3 and c['median_return_ms'] is not None for c in model_cells)
        basic = all(bool(r.get('checks')) and all(r['checks'].values()) for r in probes + warm)
        reviewed = bool(ratings) and all(ratings.get(str(r['index'])) is True for r in probes + warm)
        if enough and len(probes) == 1 and complete(probes[0]) and basic and reviewed:
            eligible.append(dict(model=model, equal_task_median_return_ms=median(c['median_return_ms'] for c in model_cells)))
    eligible.sort(key=lambda x: x['equal_task_median_return_ms'])
    return dict(scope='Mac client transport pilot only; excludes phone, STT, UI and TTS', cells=cells,
                recommendation=eligible[0]['model'] if eligible else None,
                eligible=eligible, quality_review_required=not bool(ratings),
                limitation='n=3 per task/model; no reliable p95 or universal best model; fresh-session probes separate from reused-session samples')


def self_test():
    def row(i, model, fixture, repetition, elapsed=1000):
        return dict(index=i, model=model, fixture=fixture, repetition=repetition, outcome='success', answer='public fixture', checks={'facts': True}, observations=[dict(milestone='completed', elapsedNanoseconds=elapsed), dict(milestone='returned', elapsedNanoseconds=elapsed)])
    rows=[]
    for m, speed in [('fast', 1000), ('slow', 2000)]:
        rows.append(row(len(rows)+1,m,'vision_probe_A',-1,speed))
        for t in TASKS:
            for n in range(3): rows.append(row(len(rows)+1,m,t,n,speed))
    assert summarize(rows,['fast','slow'])['recommendation'] is None, 'No ranking before quality review'
    assert metric(rows[0],'firstTextDelta') is None, 'No invented TTFT'
    ratings={str(r['index']):True for r in rows}
    assert summarize(rows,['fast','slow'],ratings)['recommendation']=='fast'
    rows[1]['outcome']='failure'
    summary=summarize(rows,['fast','slow'],ratings)
    assert summary['recommendation']=='slow', 'Faster failed candidate must not win'
    assert summary['cells'][0]['failed']==1 and summary['cells'][0]['attempted']==3
    rows.pop(2)
    assert summarize(rows,['fast','slow'],ratings)['cells'][0]['missing']==1
    fake=row(999,'fast','cn_practical',0)
    fake['observations'].append(dict(milestone='failed',elapsedNanoseconds=2000))
    assert not complete(fake), 'completed plus later failure is not success'
    def rejects(change):
        bad=json.loads(json.dumps(rows)); change(bad)
        try: summarize(bad,['fast','slow'],ratings)
        except ValueError: return
        raise AssertionError('Invalid benchmark evidence was accepted')
    rejects(lambda x: x.append(dict(x[0], index=39)))
    rejects(lambda x: x[0].update(model='unknown'))
    rejects(lambda x: x[0].update(fixture='unknown'))
    rejects(lambda x: x[0].update(repetition=0))
    rejects(lambda x: x.extend([dict(x[0],index=39)]*40))
    duplicates=[row(i+1,'only',t,0) for i,t in enumerate(TASKS*3)]
    try: summarize(duplicates,['only'],{str(r['index']):True for r in duplicates})
    except ValueError: pass
    else: raise AssertionError('Three repetition=0 rows must not stand for reps 0/1/2')
    print('PASS: report gates for missing TTFT, failures, distinct repetitions, missing samples, invalid rows/caps, quality review and small-sample scope. Synthetic data, not model performance.')


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('run_dir',type=Path,nargs='?'); parser.add_argument('--ratings',type=Path); parser.add_argument('--self-test',action='store_true')
    args=parser.parse_args()
    if args.self_test: self_test(); return
    if not args.run_dir: parser.error('A real run directory is required')
    manifest=json.loads((args.run_dir/'manifest.json').read_text()); rows=json.loads((args.run_dir/'results.json').read_text())
    ratings=json.loads(args.ratings.read_text()) if args.ratings else None
    result=summarize(rows,[m['slug'] for m in manifest['models']],ratings)
    (args.run_dir/'summary.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
    with (args.run_dir/'timing-cells.csv').open('w',newline='') as f:
        writer=csv.DictWriter(f,fieldnames=list(result['cells'][0]));writer.writeheader();writer.writerows(result['cells'])
    # Model-hidden review, not a claim of cryptographically blinded grading. Sequence IDs
    # remain joinable to the run record. Review all probes too: word-presence checks do not
    # distinguish a correct answer from e.g. "not a blue circle, not 7".
    with (args.run_dir/'model-hidden-answer-review.csv').open('w',newline='') as f:
        writer=csv.writer(f);writer.writerow(['answer_id','fixture','public_answer','rubric'])
        for r in rows:
            writer.writerow([r['index'],r['fixture'],r.get('answer') or '', 'correct facts (not merely expected words); expected language; concise; useful; no invented location, tools, ingredients or visual details'])
    print(json.dumps(result,ensure_ascii=False,indent=2))


if __name__=='__main__': main()
