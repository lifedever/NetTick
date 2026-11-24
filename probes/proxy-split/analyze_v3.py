"""走代理识别探针 · 分析第三版
App 一侧用系统统计接口（flows.json，字节精确、有开始结束事件），
代理软件发往外网的连接用内核连接表采样（sockets.json / sockets_fast.json）。
算法只用这两份；truth.json（Surge 记录）只用来对账和量「漏采了多少」。

    python3 -I analyze_v3.py [sockets_fast.json]
"""
import bisect
import collections
import json
import math
import os
import re
import sys

D = os.path.expanduser('~/Library/Logs/NetTick/probe/')
SOCK_FILE = sys.argv[1] if len(sys.argv) > 1 else 'sockets.json'
flows = [f for f in json.load(open(D + 'flows.json')) if 'pid' in f]
env = json.load(open(D + 'env.json'))
truth = json.load(open(D + 'truth.json'))
socks = json.load(open(D + SOCK_FILE))
lines = []
def say(*a):
    s = ' '.join(str(x) for x in a); lines.append(s); print(s)
def mb(b):
    for u, d in (('GB', 1e9), ('MB', 1e6), ('KB', 1e3)):
        if abs(b) >= d:
            return f'{b / d:.2f} {u}'
    return f'{b:.0f} B'
def hostport(s):
    if not s or s.startswith('*'):
        return '*', 0
    if s.startswith('['):
        h, p = s[1:].rsplit(']:', 1)
    else:
        h, p = s.rsplit(':', 1)
    return h, int(p) if p.isdigit() else 0
def is_loop(h):
    return h.startswith('127.') or h == '::1'
def at(series, t):
    rx = tx = 0
    for ts, r, x in series:
        if ts <= t:
            rx, tx = r, x
        else:
            break
    return rx, tx

# ---------- 代理软件（通用规则） ----------
sp = env.get('systemProxies', {})
proxy_ports = {int(sp[k + 'Port']) for k in ('HTTP', 'HTTPS', 'SOCKS')
               if sp.get(k + 'Enable') == '1' and sp.get(k + 'Proxy') in ('127.0.0.1', 'localhost', '::1')}
vpn_ids = re.findall(r'\(Connected\).*?\[VPN:([^\]]+)\]', env.get('vpnServices', ''))
proxy_pids = set()
for f in flows:
    f['lh'], f['lp'] = hostport(f.get('local', '')); f['rh'], f['rp'] = hostport(f.get('remote', ''))
    f.setdefault('start', f['firstSeen'])
    if is_loop(f['lh']) and f['lp'] in proxy_ports:
        proxy_pids.add(f['pid'])
    bid = (f.get('proc') or {}).get('bundleID', '')
    if bid and any(bid.startswith(v) for v in vpn_ids):
        proxy_pids.add(f['pid'])
for x in socks:
    x['lh'], x['lp'] = hostport(x['local']); x['rh'], x['rp'] = hostport(x['remote'])
    x['tcp'] = x['proto'].startswith('tcp')
    if x['tcp'] and x['state'] == 'LISTEN' and is_loop(x['lh']) and x['lp'] in proxy_ports:
        proxy_pids.add(x['pid'])
    x['start'] = x['first'] - (0.5 if (x['rx0'] + x['tx0']) > 0 else 0)

P0 = min(x['first'] for x in socks); P1 = max(x['last'] for x in socks)
OUT = [x for x in socks if x['pid'] in proxy_pids and x['rh'] != '*' and not is_loop(x['rh'])
       and not x['rh'].startswith('198.18.') and not x['lh'].startswith('198.18.')]
OUT_TCP = sorted((x for x in OUT if x['tcp']), key=lambda x: x['start'])
OUT_S = [x['start'] for x in OUT_TCP]
SHARED_UDP = [x for x in socks if x['pid'] in proxy_pids and not x['tcp'] and x['rh'] == '*']

A = []
for f in flows:
    if f['pid'] in proxy_pids:
        continue
    k = 'tun' if f.get('ifName', '').startswith('utun') else ('sys' if is_loop(f['rh']) and f['rp'] in proxy_ports else None)
    if k and P0 + 3 <= f['start'] <= P1 - 6:
        f['kind'] = k
        s = f.get('series') or []
        f['bytes'] = f['rx'] + f['tx']
        A.append(f)

# ---------- 答案 ----------
tidx = collections.defaultdict(list)
for r in truth:
    if 'pid' in r and 'sourcePort' in r:
        tidx[(r['pid'], r['sourcePort'])].append(r)
for a in A:
    c = tidx.get((a['pid'], a['lp']), [])
    if c:
        r = min(c, key=lambda r: abs(r.get('startDate', 0) - a['start']))
        if abs(r.get('startDate', 0) - a['start']) < 30:
            ra = r.get('remoteAddress') or ''
            pol = r.get('policyName') or ''
            a['truth'] = 'proxy' if '(Proxy)' in ra else ('direct' if pol in ('DIRECT', '🌐 直连') else 'other')
            a['tip'] = ra.replace(' (Proxy)', '')
            a['thost'] = r.get('remoteHost', '')
EV = [a for a in A if a.get('truth') in ('direct', 'proxy')]
say(f'连接表：{SOCK_FILE}，采样 {P1 - P0:.0f} 秒；代理软件出站 TCP {len(OUT_TCP)} 条、共用 UDP {len(SHARED_UDP)} 条')
say(f'评估对象：采样期间新建、进了代理软件的 App 连接 {len(A)} 条，对上答案 {len(EV)} 条（{mb(sum(a["bytes"] for a in EV))}）')

# ---------- 1. 漏采：答案里的出站，连接表里有没有 ----------
def captured(a):
    want_ip = a['tip']
    lo = bisect.bisect_left(OUT_S, a['start'] - 2); hi = bisect.bisect_right(OUT_S, a['start'] + 5)
    return any(o['rh'] == want_ip for o in OUT_TCP[lo:hi])
say('\n== 1. 连接表抓到对应出站的比例（只看 TCP；走代理的节点连接可能被复用，抓不到不一定是漏采） ==')
for lab in ('direct', 'proxy'):
    sel = [a for a in EV if a['truth'] == lab and a.get('provider') == 'TCP']
    tb = sum(a['bytes'] for a in sel) or 1
    cb = sum(a['bytes'] for a in sel if captured(a))
    say(f'  {lab:<6} {len(sel):>4} 条：按字节抓到 {cb / tb * 100:5.1f}%（{mb(cb)} / {mb(tb)}）')

# ---------- 2. 配对 ----------
used = set(); pair = {}
for a in sorted((a for a in A if a.get('provider') == 'TCP'), key=lambda a: a['start']):
    lo = bisect.bisect_left(OUT_S, a['start'] - 1.5); hi = bisect.bisect_right(OUT_S, a['start'] + 4.5)
    best = None
    for o in OUT_TCP[lo:hi]:
        if id(o) in used:
            continue
        arx, atx = at(a.get('series') or [], o['last'])
        # 走节点的连接多出握手和加密开销（实测十几 KB）：容差 = 固定 32 KB + 比例
        bs = abs(o['rx'] - arx) / (max(o['rx'], arx) + 32768) + abs(o['tx'] - atx) / (max(o['tx'], atx) + 32768)
        if bs > 0.6:
            continue
        sc = bs + (0 if (a['kind'] == 'tun' and o['rp'] == a['rp']) else 0.3) + abs(o['start'] - a['start']) * 0.05
        if best is None or sc < best[0]:
            best = (sc, o)
    if best:
        used.add(id(best[1])); pair[a['id']] = best[1]

# ---------- 3. 认节点（不看答案） ----------
ep = collections.defaultdict(lambda: {'dest': set(), 'mis': 0, 'votes': 0, 'socks': 0, 'bytes': 0})
for o in OUT_TCP:
    e = ep[(o['rh'], o['rp'])]
    e['socks'] += 1; e['bytes'] += (o['rx'] - o['rx0']) + (o['tx'] - o['tx0'])
    near = [a for a in A if a['kind'] == 'tun' and -4.5 <= o['start'] - a['start'] <= 1.5]
    if near:
        e['votes'] += 1
        e['mis'] += o['rp'] not in {a['rp'] for a in near}
for a in A:
    o = pair.get(a['id'])
    if o and a['kind'] == 'tun':
        ep[(o['rh'], o['rp'])]['dest'].add(a['rh'])
nodes = {k for k, e in ep.items() if len(e['dest']) >= 6 or (e['votes'] >= 5 and e['mis'] >= 0.8 * e['votes'])}
truth_nodes = {a['tip'] for a in EV if a['truth'] == 'proxy'}
say('\n== 3. 认出的节点 ==')
for k in sorted(nodes, key=lambda k: -ep[k]['bytes']):
    e = ep[k]
    say(f'  {k[0]}:{k[1]:<6} 出站 {e["socks"]:>3} 条 {mb(e["bytes"]):>10}，配上的不同目的地 {len(e["dest"])}，端口不一致 {e["mis"]}/{e["votes"]}'
        + ('  ← 答案里的节点' if k[0] in truth_nodes else '  ✗ 答案里不是节点'))
missed_nodes = truth_nodes - {k[0] for k in nodes}
say(f'  答案里的节点没认出来的：{sorted(missed_nodes) or "无"}')

# ---------- 4. 同时段增长：节点连接 vs 直连连接 ----------
STEP = 2.0
def growth(series, factor_rx=1.0):
    g = collections.defaultdict(float); prev = None
    for ts, r, x in series:
        if prev is not None:
            g[int(ts // STEP)] += max(0, r - prev[0]) * factor_rx + max(0, x - prev[1])
        prev = (r, x)
    return g
N = collections.defaultdict(float); Dg = collections.defaultdict(float)
for o in OUT_TCP:
    tgt = N if (o['rh'], o['rp']) in nodes else Dg
    for b, v in growth(o['series']).items():
        tgt[b] += v
for x in SHARED_UDP:
    for b, v in growth(x['series'], 0.5).items():   # 连接表里 UDP 收字节是 2 倍
        Dg[b] += v
def cover(a, G):
    g = growth(a.get('series') or [])
    tot = sum(g.values())
    if tot <= 0:
        return 0.0, 0.0
    c = sum(min(v, G.get(b - 1, 0) + G.get(b, 0) + G.get(b + 1, 0)) for b, v in g.items())
    return c / tot, tot

def label(a, default):
    o = pair.get(a['id'])
    if o is not None:
        return ('proxy' if (o['rh'], o['rp']) in nodes else 'direct'), 'pair'
    pc, _ = cover(a, N); dc, _ = cover(a, Dg)
    if pc >= 0.5 and pc > dc:
        return 'proxy', 'cover'
    if dc >= 0.5:
        return 'direct', 'cover'
    return default, 'default'

def evaluate(default, title, sel):
    cm = collections.defaultdict(lambda: [0, 0]); how = collections.Counter()
    for a in sel:
        p, h = label(a, default)
        cm[(a['truth'], p)][0] += 1; cm[(a['truth'], p)][1] += a['bytes']; how[h] += a['bytes']
    tb = sum(v[1] for v in cm.values()) or 1
    ok = cm[('direct', 'direct')][1] + cm[('proxy', 'proxy')][1]
    tn = sum(v[0] for v in cm.values()) or 1
    okn = cm[('direct', 'direct')][0] + cm[('proxy', 'proxy')][0]
    say(f'  {title:<24} 按字节 {ok / tb * 100:5.1f}%（{mb(ok)} / {mb(tb)}）  按条数 {okn / tn * 100:5.1f}%   '
        f'判定依据：配对 {how["pair"] / tb * 100:.0f}% / 同时段增长 {how["cover"] / tb * 100:.0f}% / 兜底 {how["default"] / tb * 100:.0f}%')
    return cm

for default in ('direct', 'proxy'):
    say(f'\n== 4. 准确率（对不上时兜底判「{"直连" if default == "direct" else "走代理"}」） ==')
    evaluate(default, '全部', EV)
    evaluate(default, 'TCP', [a for a in EV if a.get('provider') == 'TCP'])
    evaluate(default, 'UDP', [a for a in EV if a.get('provider') == 'UDP'])
    evaluate(default, '虚拟网卡模式', [a for a in EV if a['kind'] == 'tun'])
    evaluate(default, '系统代理模式', [a for a in EV if a['kind'] == 'sys'])

best_default = 'direct'
say('\n== 5. 判错的大头（兜底判直连） ==')
wrong = sorted((a for a in EV if label(a, best_default)[0] != a['truth']), key=lambda a: -a['bytes'])
for a in wrong[:10]:
    p, h = label(a, best_default)
    say(f"  {a['processName'][:24]:<24} {a.get('provider')} {a['kind']} {mb(a['bytes']):>10} 答案 {a['truth']:<6} 依据 {h:<7} {a.get('thost', '')[:40]}")

say('\n== 6. 每个 App 走代理的比例（答案 / 算法，兜底判直连） ==')
def app_key(f):
    p = (f.get('proc') or {}).get('app') or ''
    return os.path.basename(p).replace('.app', '') if p else f.get('processName')
per = collections.defaultdict(lambda: [0, 0, 0])
for a in EV:
    k = app_key(a); per[k][0] += a['bytes']
    per[k][1] += a['bytes'] if a['truth'] == 'proxy' else 0
    per[k][2] += a['bytes'] if label(a, best_default)[0] == 'proxy' else 0
for k, (tb, tp, pp) in sorted(per.items(), key=lambda x: -x[1][0])[:12]:
    if tb >= 1e5:
        say(f'  {k[:30]:<30} {mb(tb):>10}   答案 {tp / tb * 100:5.1f}%   算法 {pp / tb * 100:5.1f}%')
open(D + 'report_v3_' + SOCK_FILE.replace('.json', '') + '.txt', 'w').write('\n'.join(lines) + '\n')
