"""走代理识别探针 · 分析
读 collect.swift 产出的 flows.json / env.json，用「通用」算法给每条 App 连接判走代理还是直连；
truth.json（Surge 的记录）只在最后对账时用。

    python3 -I analyze.py            # 报告打到 stdout，同时写 ~/Library/Logs/NetTick/probe/report.txt
"""
import collections
import json
import os
import re
import statistics
import sys

D = os.path.expanduser('~/Library/Logs/NetTick/probe/')
flows_all = json.load(open(D + 'flows.json'))
flows = [f for f in flows_all if 'pid' in f]   # 极少数连接还没收到描述就结束了
env = json.load(open(D + 'env.json'))
truth = json.load(open(D + 'truth.json'))
T0 = env.get('startedAt') or min(f['firstSeen'] for f in flows)
T1 = env.get('endedAt') or max(f.get('removedAt') or f['firstSeen'] for f in flows)

out_lines = []
def say(*a):
    s = ' '.join(str(x) for x in a)
    out_lines.append(s)
    print(s)

def mb(b):
    for u, d in (('GB', 1e9), ('MB', 1e6), ('KB', 1e3)):
        if abs(b) >= d:
            return f'{b / d:.2f} {u}'
    return f'{b:.0f} B'

def hostport(s):
    if not s:
        return '', 0
    if s.startswith('['):
        h, p = s[1:].rsplit(']:', 1)
    else:
        h, p = s.rsplit(':', 1)
    return h, int(p)

def is_loop(h):
    return h.startswith('127.') or h == '::1'

# ---------- 窗口内的字节数：老连接以第一次看到时为基线 ----------
for f in flows:
    s = f.get('series') or []
    f.setdefault('start', f['firstSeen'])
    old = f['start'] < T0 - 1
    br, bt = (s[0][1], s[0][2]) if (old and s) else (0, 0)
    f['drx'], f['dtx'] = max(0, f['rx'] - br), max(0, f['tx'] - bt)
    f['dbytes'] = f['drx'] + f['dtx']
    f['lh'], f['lp'] = hostport(f.get('local', ''))
    f['rh'], f['rp'] = hostport(f.get('remote', ''))
    f['if'] = f.get('ifName', '')
    f['bid'] = (f.get('proc') or {}).get('bundleID', '')
    f['appPath'] = (f.get('proc') or {}).get('app') or (f.get('proc') or {}).get('path', '')

# ---------- 1. 认代理软件（通用：系统代理端口 + 已连接的 VPN 服务） ----------
sp = env.get('systemProxies', {})
proxy_ports = set()
for k in ('HTTP', 'HTTPS', 'SOCKS'):
    if sp.get(k + 'Enable') == '1' and sp.get(k + 'Proxy') in ('127.0.0.1', 'localhost', '::1'):
        proxy_ports.add(int(sp[k + 'Port']))
vpn_ids = re.findall(r'\(Connected\).*?\[VPN:([^\]]+)\]', env.get('vpnServices', ''))
proxy_pids = {}
for f in flows:
    if is_loop(f['lh']) and f['lp'] in proxy_ports:
        proxy_pids[f['pid']] = f"监听系统代理端口 {f['lp']}"
    if f['bid'] and any(f['bid'].startswith(v) for v in vpn_ids):
        proxy_pids.setdefault(f['pid'], f"属于已连接的 VPN 服务 {f['bid']}")
say(f'连接 {len(flows_all)} 条，没收到描述的 {len(flows_all) - len(flows)} 条（跳过）')
say('== 1. 认出的代理软件 ==')
say(f'系统代理端口：{sorted(proxy_ports)}；已连接的 VPN 服务：{vpn_ids}')
names = {f['pid']: f.get('processName') for f in flows}
for pid, why in proxy_pids.items():
    say(f'  pid {pid} {names.get(pid)}：{why}')

# ---------- 2. 分类 ----------
def kind(f):
    if f['pid'] in proxy_pids:
        if is_loop(f['rh']) or f['if'] == 'lo0':
            return 'proxy-in'
        if f['if'].startswith('utun'):
            return 'proxy-tun'
        return 'out'
    if f['if'].startswith('utun'):
        return 'tun'
    if is_loop(f['rh']):
        return 'sys' if f['rp'] in proxy_ports else 'local'
    return 'bypass'

for f in flows:
    f['kind'] = kind(f)
by_kind = collections.defaultdict(lambda: [0, 0])
for f in flows:
    by_kind[f['kind']][0] += 1
    by_kind[f['kind']][1] += f['dbytes']
say('\n== 2. 连接分类（采集窗口内的字节） ==')
label = {'tun': 'App → 虚拟网卡', 'sys': 'App → 系统代理端口', 'bypass': 'App 直接出网（绕过代理）',
         'out': '代理软件 → 外网', 'proxy-in': '代理软件接收端（回环）', 'proxy-tun': '代理软件在虚拟网卡上',
         'local': '本机回环（非代理）'}
for k, (n, b) in sorted(by_kind.items(), key=lambda x: -x[1][1]):
    say(f'  {label.get(k, k):<22} {n:>5} 条  {mb(b)}')

A = [f for f in flows if f['kind'] in ('tun', 'sys')]
O = sorted((f for f in flows if f['kind'] == 'out'), key=lambda f: f['start'])
O_starts = [o['start'] for o in O]
import bisect
def outs_near(t, lo=-1.0, hi=8.0):
    return O[bisect.bisect_left(O_starts, t + lo):bisect.bisect_right(O_starts, t + hi)]

# ---------- 3. 对上答案（Surge 记录：pid + App 端口） ----------
def truth_label(r):
    ra = r.get('remoteAddress') or ''
    pol = r.get('policyName') or ''
    if '(Proxy)' in ra:
        return 'proxy'
    if 'REJECT' in pol.upper() or r.get('rejected'):
        return 'reject'
    if pol in ('DIRECT', '🌐 直连'):
        return 'direct'
    return 'unknown'

tidx = collections.defaultdict(list)
for r in truth:
    if 'pid' in r and 'sourcePort' in r:
        tidx[(r['pid'], r['sourcePort'])].append(r)
joined = 0
for a in A:
    cands = tidx.get((a['pid'], a['lp']), [])
    if cands:
        r = min(cands, key=lambda r: abs(r.get('startDate', 0) - a['start']))
        if abs(r.get('startDate', 0) - a['start']) < 30:
            a['truth'] = truth_label(r)
            a['truthRemote'] = (r.get('remoteAddress') or '').replace(' (Proxy)', '')
            a['truthHost'] = r.get('remoteHost', '')
            joined += 1
jb = sum(a['dbytes'] for a in A if 'truth' in a)
say(f'\n== 3. 对答案 ==\n进代理软件的 App 连接 {len(A)} 条，对上 Surge 记录 {joined} 条；'
    f'按字节覆盖 {mb(jb)} / {mb(sum(a["dbytes"] for a in A))}')
tl = collections.Counter(a.get('truth') for a in A if 'truth' in a)
say(f'答案分布（条数）：{dict(tl)}')
node_ips_truth = collections.Counter()
for a in A:
    if a.get('truth') == 'proxy':
        node_ips_truth[a['truthRemote']] += a['dbytes']
say('答案里的代理节点：' + '，'.join(f'{ip} {mb(b)}' for ip, b in node_ips_truth.most_common(6)))

# ---------- 4. 代理软件的出站：取内核连接表（所有用户都看得到，TCP 字节精确） ----------
socks = json.load(open(D + 'sockets.json'))
P0 = min(x['first'] for x in socks)
P1 = max(x['last'] for x in socks)
for x in socks:
    x['lh'], x['lp'] = hostport(x['local']) if not x['local'].startswith('*') else ('*', 0)
    x['rh'], x['rp'] = hostport(x['remote']) if x['remote'] not in ('*:*',) and not x['remote'].startswith('*') else ('*', 0)
    x['tcp'] = x['proto'].startswith('tcp')
# 代理软件：除了上面的规则，连接表里监听系统代理端口的进程也算
for x in socks:
    if x['tcp'] and x['state'] == 'LISTEN' and is_loop(x['lh']) and x['lp'] in proxy_ports:
        proxy_pids.setdefault(x['pid'], f"连接表里监听 {x['lp']}")
OUT = [x for x in socks if x['pid'] in proxy_pids and x['rh'] != '*' and not is_loop(x['rh']) and not x['rh'].startswith('198.18.')]
SHARED_UDP = [x for x in socks if x['pid'] in proxy_pids and not x['tcp'] and x['rh'] == '*']
for x in OUT:
    x['start'] = x['first'] - (1.0 if (x['rx0'] + x['tx0']) > 0 else 0)   # 两次采样之间建立的，取中点
OUT_TCP = sorted((x for x in OUT if x['tcp']), key=lambda x: x['start'])
OUT_TCP_S = [x['start'] for x in OUT_TCP]
import bisect
say(f'\n== 4. 内核连接表：采样 {P1 - P0:.0f} 秒，连接 {len(socks)} 条；代理软件出站 TCP {len(OUT_TCP)} 条，共用 UDP {len(SHARED_UDP)} 条 ==')
users = collections.Counter()
for x in socks:
    users[x['name']] += max(0, x['rx'] - x['rx0']) * (1 if x['tcp'] else 0.5) + max(0, x['tx'] - x['tx0'])
flow_pids = {f['pid'] for f in flows}
hidden = [(n, b) for n, b in users.most_common() if not any(x['name'] == n and x['pid'] in flow_pids for x in socks)]
say('  系统统计接口看不到、连接表里有流量的进程（前 8）：' + '，'.join(f'{n} {mb(b)}' for n, b in hidden[:8] if b > 0))

def at(series, t):
    """series [[t, rx, tx], ...] 在 t 时刻（含）之前最后一次的计数"""
    rx = tx = 0
    for ts, r, x in series:
        if ts <= t:
            rx, tx = r, x
        else:
            break
    return rx, tx

# 只评估采样期间新建的 App 连接（老连接没有出站的建立时间可比）
A_eval = [a for a in A if P0 + 3 <= a['start'] <= P1 - 6]
say(f'  参与评估的 App 连接：{len(A_eval)} 条（采样期间新建），其中对上答案 {sum(1 for a in A_eval if "truth" in a)} 条')

# ---------- 5. TCP 配对 ----------
used = set()
pairs = {}
for a in sorted((a for a in A_eval if a.get('provider') == 'TCP'), key=lambda f: f['start']):
    lo = bisect.bisect_left(OUT_TCP_S, a['start'] - 1.5)
    hi = bisect.bisect_right(OUT_TCP_S, a['start'] + 4.5)
    best = None
    for o in OUT_TCP[lo:hi]:
        if id(o) in used:
            continue
        arx, atx = at(a.get('series') or [], o['last'])
        if arx + atx == 0 and o['rx'] + o['tx'] > 0:
            continue
        r1 = (o['rx'] + 200) / (arx + 200); r2 = (o['tx'] + 200) / (atx + 200)
        bytes_score = abs(__import__('math').log(r1)) + abs(__import__('math').log(r2))
        if bytes_score > 1.5:
            continue
        port_bonus = 0 if (a['kind'] == 'tun' and o['rp'] == a['rp']) else 0.3
        score = bytes_score + port_bonus + abs(o['start'] - a['start']) * 0.05
        if best is None or score < best[0]:
            best = (score, o)
    if best:
        used.add(id(best[1]))
        pairs[a['id']] = best[1]

# 认节点：同一出站地址接了很多不同目的地，或端口和 App 原本要连的不一样
ep = collections.defaultdict(lambda: {'dest': set(), 'n': 0, 'mis': 0})
for a in A_eval:
    o = pairs.get(a['id'])
    if not o:
        continue
    e = ep[(o['rh'], o['rp'])]
    e['n'] += 1
    if a['kind'] == 'tun':
        e['dest'].add(a['rh'])
        e['mis'] += o['rp'] != a['rp']
def is_node(key):
    e = ep[key]
    return len(e['dest']) >= 3 or (e['mis'] >= 1 and e['mis'] >= 0.5 * max(1, len(e['dest'])))
nodes = {k for k in ep if is_node(k)}
say('\n== 5. 认出的节点（出站地址） ==')
for k in sorted(nodes, key=lambda k: -ep[k]['n'])[:8]:
    tag = '← 答案里的节点' if k[0] in node_ips_truth else ''
    say(f'  {k[0]}:{k[1]:<6} 配上 {ep[k]["n"]} 条，不同目的地 {len(ep[k]["dest"])} 个，端口不一致 {ep[k]["mis"]} 次 {tag}')

# ---------- 6. UDP：代理软件共用的那条 UDP 跟着涨 → 直连 ----------
def deltas(series, t0, t1, step=4.0):
    out = []
    t = t0
    prev = at(series, t0)
    while t < t1:
        cur = at(series, t + step)
        out.append((t, max(0, cur[1] - prev[1])))
        prev = cur; t += step
    return out
shared_tx = collections.defaultdict(float)
for x in SHARED_UDP:
    for t, d in deltas(x['series'], P0, P1):
        shared_tx[t] += d
udp_label = {}
for a in A_eval:
    if a.get('provider') != 'UDP':
        continue
    ser = a.get('series') or []
    if not ser:
        continue
    tot = cov = 0.0
    for t, d in deltas(ser, P0, P1):
        tot += d
        cov += min(d, shared_tx.get(t, 0))
    if tot > 0:
        udp_label[a['id']] = 'direct' if cov / tot >= 0.7 else 'proxy'

# ---------- 7. 判定 + 对账 ----------
def label(a):
    if a.get('provider') == 'UDP':
        return udp_label.get(a['id'], 'proxy')
    o = pairs.get(a['id'])
    if not o:
        return 'proxy'          # 没有一一对应的出站：多路复用、走节点的 UDP 通道等
    return 'proxy' if (o['rh'], o['rp']) in nodes else 'direct'

def evaluate(title, sel):
    cm = collections.defaultdict(lambda: [0, 0])
    for a in sel:
        t = a.get('truth')
        if t not in ('direct', 'proxy'):
            continue
        cm[(t, label(a))][0] += 1
        cm[(t, label(a))][1] += a['dbytes']
    tb = sum(v[1] for v in cm.values()) or 1
    okb = cm[('direct', 'direct')][1] + cm[('proxy', 'proxy')][1]
    tn = sum(v[0] for v in cm.values()) or 1
    okn = cm[('direct', 'direct')][0] + cm[('proxy', 'proxy')][0]
    say(f'\n== {title} ==')
    say(f'  按字节准确率 {okb / tb * 100:.1f}%（{mb(okb)} / {mb(tb)}），按条数 {okn / tn * 100:.1f}%（{okn}/{tn}）')
    for (t, p), (n, b) in sorted(cm.items()):
        say(f'    答案 {t:<6} → 判成 {p:<6} {n:>5} 条  {mb(b)}')

evaluate('7a. 全部（TCP + UDP）', A_eval)
evaluate('7b. 只看 TCP', [a for a in A_eval if a.get('provider') == 'TCP'])
evaluate('7c. 只看 UDP', [a for a in A_eval if a.get('provider') == 'UDP'])
evaluate('7d. 只看虚拟网卡模式', [a for a in A_eval if a['kind'] == 'tun'])
evaluate('7e. 只看系统代理模式', [a for a in A_eval if a['kind'] == 'sys'])

# 判错的大头
wrong = sorted((a for a in A_eval if a.get('truth') in ('direct', 'proxy') and label(a) != a['truth']), key=lambda a: -a['dbytes'])
say('\n== 8. 判错的大头（前 10） ==')
for a in wrong[:10]:
    o = pairs.get(a['id'])
    say(f"  {a['processName']:<22} {a.get('provider')} {a['kind']} {mb(a['dbytes']):>10} 答案 {a['truth']:<6} 目标 {a.get('truthHost', '')[:34]:<34} "
        f"出站 {o['rh'] + ':' + str(o['rp']) if o else '（没配上）'}")

# ---------- 9. 每个 App ----------
def app_key(f):
    p = f['appPath']
    return os.path.basename(p).replace('.app', '') if p else f.get('processName')
per = collections.defaultdict(lambda: {'tp': 0, 'tb': 0, 'pp': 0})
for a in A_eval:
    if a.get('truth') not in ('direct', 'proxy'):
        continue
    k = app_key(a)
    per[k]['tb'] += a['dbytes']
    per[k]['tp'] += a['dbytes'] if a['truth'] == 'proxy' else 0
    per[k]['pp'] += a['dbytes'] if label(a) == 'proxy' else 0
say('\n== 9. 每个 App 走代理的比例（答案 / 算法） ==')
for k, v in sorted(per.items(), key=lambda x: -x[1]['tb'])[:12]:
    if v['tb'] < 1e5:
        continue
    say(f'  {k:<30} {mb(v["tb"]):>10}   答案 {v["tp"] / v["tb"] * 100:5.1f}%   算法 {v["pp"] / v["tb"] * 100:5.1f}%')

open(D + 'report.txt', 'w').write('\n'.join(out_lines) + '\n')
