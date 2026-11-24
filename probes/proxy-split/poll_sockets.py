"""走代理识别探针 · 内核连接表采样
每 2 秒读一次 `netstat -anv`（不需要特权，能看到所有用户的连接、进程号和每条连接的字节数），
按 gencnt（每个 socket 唯一）合并，写 ~/Library/Logs/NetTick/probe/sockets.json。
正式实现时改成直接读 sysctl net.inet.{tcp,udp}.pcblist_n，不起子进程。

    python3 -I poll_sockets.py <结束时间 Unix 秒> [间隔秒，默认 2] [输出文件名，默认 sockets.json]
"""
import json
import os
import subprocess
import sys
import time

D = os.path.expanduser('~/Library/Logs/NetTick/probe/')
deadline = float(sys.argv[1])
interval = float(sys.argv[2]) if len(sys.argv) > 2 else 2.0
out_name = sys.argv[3] if len(sys.argv) > 3 else 'sockets.json'
socks = {}

def addr(s):
    # netstat 的 a.b.c.d.port / ipv6.port / *.port
    if s.startswith('*.') or s == '*.*':
        return s.replace('.', ':', 1) if s != '*.*' else '*:*'
    h, _, p = s.rpartition('.')
    return f'{h}:{p}'

def poll():
    now = time.time()
    for proto in ('tcp', 'udp'):
        out = subprocess.run(['/usr/sbin/netstat', '-anv', '-p', proto], capture_output=True, text=True).stdout
        for line in out.splitlines():
            t = line.split()
            if not t or not t[0].startswith(proto) or len(t) < 18:
                continue
            has_state = proto == 'tcp'
            i = 6 if has_state else 5
            try:
                rx, tx = int(t[i]), int(t[i + 1])
            except ValueError:
                continue
            tail = t[-8:]
            procpid = ' '.join(t[i + 4:-8])
            name, _, pid = procpid.rpartition(':')
            # gencnt 每个 socket 唯一，但代理软件网络扩展建的 socket 全是 0（实测 72/82 条），这时退回用两端地址
            gen = tail[2]
            key = f'{proto}:{gen}' if gen.strip('0') else f'{t[0]}:{t[3]}->{t[4]}'
            s = socks.get(key)
            if s is None:
                s = socks[key] = {'proto': t[0], 'local': addr(t[3]), 'remote': addr(t[4]),
                                  'state': t[5] if has_state else '', 'pid': int(pid) if pid.isdigit() else -1,
                                  'name': name, 'first': now, 'rx0': rx, 'tx0': tx, 'series': []}
            s['last'] = now
            if has_state:
                s['state'] = t[5]
            if not s['series'] or s['series'][-1][1:] != [rx, tx]:
                if len(s['series']) < 2000:
                    s['series'].append([now, rx, tx])
            s['rx'], s['tx'] = rx, tx

def save():
    tmp = D + out_name + '.tmp'
    json.dump(list(socks.values()), open(tmp, 'w'))
    os.replace(tmp, D + out_name)

t_save = time.time()
while time.time() < deadline:
    t = time.time()
    poll()
    if time.time() - t_save > 30:
        save(); t_save = time.time()
    time.sleep(max(0, interval - (time.time() - t)))
save()
print('sockets', len(socks))
