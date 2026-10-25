#!/usr/bin/env python3
"""Writes src/bsltable.nim: where Oni.exe keeps the strings of the BSL commands
and variables it registers (name, description, argument list), as addresses
only. Catwalk reads the strings from the player's own Oni.exe (bsldefs.nim).

    tools/bsl_table.py "<Oni>/Oni.exe" > src/bsltable.nim

Needs objdump (binutils). It disassembles the exe and follows the registration
code linearly, tracking registers and stack slots, for:
  - direct calls: 0x477b40 (void command: ecx name, edx description, pushed
    argument list and callback), 0x477b20 (command with a return type),
    0x478950, and the variable registrars 0x477e30 / fe0 / ec0 / f50
    (int / string / float / bool) and 0x477d90 (type pushed);
  - tables passed in ecx: 0x4777d0 (commands: name, description, arguments,
    callback), 0x477850 / 0x477940 / 0x477a30 (int / float / bool variables:
    name, description, pointer);
  - tables built on the stack and walked in a loop (the AI's): commands as
    name, alias, alias, description, arguments, callback; variables as name,
    type, description, pointer.
Function starts are the targets of calls.
"""
import re, sys, subprocess

exe = open(sys.argv[1], 'rb').read()
asm = subprocess.run(['objdump', '-d', '-M', 'intel', '--no-show-raw-insn', sys.argv[1]],
                     capture_output=True, text=True, check=True).stdout.splitlines()
funcs = set(int(x, 16) for x in re.findall(r'call   0x([0-9a-f]+)', '\n'.join(asm)))

def sec(va):
    if 0x529000 <= va < 0x52cd68: return va - 0x529000 + 0x129000
    if 0x52d000 <= va < 0x55d000: return va - 0x52d000 + 0x12d000
    return None

def cstr(va):
    if not isinstance(va, int): return None
    o = sec(va)
    if o is None: return None
    e = exe.find(b'\0', o)
    if e - o > 2000: return None
    try: s = exe[o:e].decode('latin-1')
    except: return None
    if any(ord(c) < 9 for c in s): return None
    return s

def dword(va):
    o = sec(va)
    if o is None: return None
    return int.from_bytes(exe[o:o+4], 'little')

istext = lambda v: isinstance(v, int) and 0x401000 <= v < 0x529000
ident = re.compile(r'^[A-Za-z_][A-Za-z0-9_]*$')

VOIDCMD, RETCMD = 0x477b40, 0x477b20
VARS = {0x477e30: 'int', 0x477fe0: 'string', 0x477ec0: 'float', 0x477f50: 'bool'}
VARTABLES = {0x477850: 'int', 0x477940: 'float', 0x477a30: 'bool'}
CMDTABLE4 = 0x4777d0
TYPES = {0: 'int', 1: 'string', 2: 'float', 3: 'bool'}

cmds, vars_ = {}, {}
# Bytes each function pops on return (ret N): callers don't clean up after those.
retpop = {}
_f = None
for ln in asm:
    m = re.match(r'^\s+([0-9a-f]+):\s+(\S+)\s*(.*)$', ln)
    if not m: continue
    a = int(m.group(1), 16)
    if a in funcs: _f = a
    if m.group(2) == 'ret' and _f is not None and _f not in retpop:
        retpop[_f] = int(m.group(3), 16) if m.group(3).strip().startswith('0x') else 0
def addcmd(name, desc, params, ret, src):
    if not cstr(name) or not ident.match(cstr(name)): return
    n = cstr(name)
    if n in cmds: return
    cmds[n] = dict(desc=cstr(desc) or '', params=cstr(params) or '', ret=ret, at=src,
                   va=[name, desc if cstr(desc) is not None else 0, params if cstr(params) is not None else 0])
def addvar(name, desc, typ, src):
    n = cstr(name)
    if n is None or not ident.match(n): return
    if n in vars_: return
    vars_[n] = dict(desc=cstr(desc) or '', type=typ, at=src, va=[name, desc if cstr(desc) is not None else 0])

REGS = ['eax', 'ebx', 'ecx', 'edx', 'esi', 'edi', 'ebp']
line_re = re.compile(r'^\s+([0-9a-f]+):\s+(\S+)\s*(.*)$')
mem_re = re.compile(r'DWORD PTR \[(esp|ebp)([+-]0x[0-9a-f]+)?\]')

class S:
    def reset(s):
        s.r = {k: None for k in REGS}; s.esp = 0; s.mem = {}
st = S(); st.reset()
cur = None

def val(op):
    op = op.strip()
    if op in st.r: return st.r[op]
    if re.fullmatch(r'0x[0-9a-f]+', op): return int(op, 16)
    m = mem_re.fullmatch(op)
    if m: return st.mem.get(addr(m))
    m = re.fullmatch(r'DWORD PTR ds:(0x[0-9a-f]+)', op)
    if m: return ('ds', int(m.group(1), 16))
    return None

def addr(m):
    base = st.esp if m.group(1) == 'esp' else st.r['ebp']
    if not isinstance(base, tuple): return None
    return base[1] + (int(m.group(2), 16) if m.group(2) else 0)

def table_from(ptr):
    """Reads dwords from a stack address ('stk', off) or a static address."""
    if isinstance(ptr, tuple) and ptr[0] == 'stk':
        return lambda i: st.mem.get(ptr[1] + 4 * i)
    if isinstance(ptr, int): return lambda i: dword(ptr + 4 * i)
    return None

def flush_stack_tables():
    # 4-dword stack variable tables: name, type, desc, pointer.
    for off in sorted(k for k in st.mem if k is not None):
        g = [st.mem.get(off + 4 * i) for i in range(4)]
        if (cstr(g[0]) and ident.match(cstr(g[0])) and g[1] in TYPES and cstr(g[2]) is not None
                and isinstance(g[3], int) and 0x52d000 <= g[3] < 0x700000):
            addvar(g[0], g[2], TYPES[g[1]], hex(cur) + ' table')
    # 6-dword stack command tables: name, alias, alias, desc, params, callback.
    mem = st.mem
    for off in sorted(k for k in mem if k is not None):
        g = [mem.get(off + 4 * i) for i in range(6)]
        if (cstr(g[0]) and ident.match(cstr(g[0])) and cstr(g[3]) is not None
                and (cstr(g[4]) is not None or g[4] == 0) and istext(g[5])):
            addcmd(g[0], g[3], g[4], None, hex(cur))
            for al in (g[1], g[2]):
                if cstr(al) and ident.match(cstr(al)):
                    addcmd(al, g[3], g[4], None, hex(cur) + ' alias of ' + cstr(g[0]))

for ln in asm:
    m = line_re.match(ln)
    if not m: continue
    a = int(m.group(1), 16); op = m.group(2); args = m.group(3).split('#')[0].strip()
    if a in funcs:
        if cur is not None: flush_stack_tables()
        st.reset(); st.esp = ('stk', 0); st.r['ebp'] = None; cur = a
    if not isinstance(st.esp, tuple): st.esp = ('stk', 0)
    parts = [p.strip() for p in re.split(r',(?![^\[]*\])', args)] if args else []
    if op == 'push':
        st.esp = ('stk', st.esp[1] - 4); st.mem[st.esp[1]] = val(parts[0])
    elif op == 'pop':
        if parts[0] in st.r: st.r[parts[0]] = st.mem.get(st.esp[1])
        st.esp = ('stk', st.esp[1] + 4)
    elif op == 'mov' and len(parts) == 2:
        d, s_ = parts
        if d in st.r:
            st.r[d] = st.esp if s_ == 'esp' else val(s_)
        else:
            mm = mem_re.fullmatch(d)
            if mm and addr(mm) is not None: st.mem[addr(mm)] = val(s_)
    elif op == 'lea' and len(parts) == 2 and parts[0] in st.r:
        mm = re.fullmatch(r'\[(esp|ebp)([+-]0x[0-9a-f]+)?\]', parts[1])
        if mm:
            base = st.esp if mm.group(1) == 'esp' else st.r['ebp']
            st.r[parts[0]] = ('stk', base[1] + (int(mm.group(2), 16) if mm.group(2) else 0)) if isinstance(base, tuple) else None
        else:
            st.r[parts[0]] = None
    elif op in ('sub', 'add') and parts and parts[0] == 'esp' and re.fullmatch(r'0x[0-9a-f]+', parts[1]):
        n = int(parts[1], 16); st.esp = ('stk', st.esp[1] + (n if op == 'add' else -n))
    elif op == 'xor' and len(parts) == 2 and parts[0] == parts[1] and parts[0] in st.r:
        st.r[parts[0]] = 0
    elif op == 'call':
        try: t = int(parts[0], 16)
        except: t = None
        sp = st.esp[1]
        arg = lambda i: st.mem.get(sp + 4 * i)
        if t == VOIDCMD:
            addcmd(st.r['ecx'], st.r['edx'], arg(0), None, hex(a))
        elif t == RETCMD:
            addcmd(st.r['ecx'], st.r['edx'], arg(0), TYPES.get(arg(1), str(arg(1))), hex(a))
        elif t == 0x478950:
            addcmd(st.r['ecx'], st.r['edx'], arg(0), None if arg(1) == 4 else TYPES.get(arg(1)), hex(a))
        elif t in VARS:
            addvar(st.r['ecx'], st.r['edx'], VARS[t], hex(a))
        elif t == 0x477d90:
            addvar(st.r['ecx'], st.r['edx'], TYPES.get(arg(1), '?'), hex(a))
        elif t in VARTABLES or t == CMDTABLE4:
            tb = table_from(st.r['ecx'])
            if tb:
                i = 0
                while tb(i):
                    if t == CMDTABLE4:
                        addcmd(tb(i), tb(i + 1), tb(i + 2), None, hex(a)); i += 4
                    else:
                        addvar(tb(i), tb(i + 1), VARTABLES[t], hex(a)); i += 3
                    if i > 4000: break
            else:
                print('unresolved table at', hex(a), file=sys.stderr)
        for k in ('eax', 'ecx', 'edx'): st.r[k] = None
        if t in retpop: st.esp = ('stk', st.esp[1] + retpop[t])
    elif parts and parts[0] in st.r and op not in ('cmp', 'test', 'push'):
        st.r[parts[0]] = None
flush_stack_tables()

import hashlib
TYPENUM = {'int': 0, 'string': 1, 'float': 2, 'bool': 3}
print('## Generated by tools/bsl_table.py from Oni.exe (%d bytes, md5 %s). Addresses of the'
      % (len(exe), hashlib.md5(exe).hexdigest()))
print('## strings of the BSL commands and variables the game registers; no text of the game.')
print('## Commands: name, description, argument list (0 = none: the game checks no arguments),')
print('## return type (-1 = none; else as variables). Variables: name, description, type')
print('## (0 int, 1 string, 2 float, 3 bool).')
print()
print('const')
print('  OniExeSize* = %d' % len(exe))
print('  BslCommandAt*: array[%d, array[4, int32]] = [' % len(cmds))
rows = []
for n in sorted(cmds, key=str.lower):
    c = cmds[n]
    ret = -1 if c['ret'] in (None, '?') else TYPENUM.get(c['ret'], -1)
    rows.append('[0x%x\'i32, 0x%x, 0x%x, %d]' % (c['va'][0], c['va'][1], c['va'][2], ret))
for i in range(0, len(rows), 3):
    print('    ' + ', '.join(rows[i:i + 3]) + (',' if i + 3 < len(rows) else ']'))
print('  BslVariableAt*: array[%d, array[3, int32]] = [' % len(vars_))
rows = []
for n in sorted(vars_, key=str.lower):
    v = vars_[n]
    rows.append('[0x%x\'i32, 0x%x, %d]' % (v['va'][0], v['va'][1], TYPENUM.get(v['type'], 1)))
for i in range(0, len(rows), 4):
    print('    ' + ', '.join(rows[i:i + 4]) + (',' if i + 4 < len(rows) else ']'))
print('%d commands, %d variables' % (len(cmds), len(vars_)), file=sys.stderr)
