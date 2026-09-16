#!/usr/bin/env python3
"""Bounded, read-only evidence for ONE directory. No repository code or network runs."""
import hashlib, json, os, re, selectors, stat, subprocess, sys, time
from pathlib import Path

VERSION = 1
MAX_OUTPUT = 30000
SKIP = {'.git', 'node_modules', 'vendor', 'dist', 'build', 'target', '.next', '.venv', 'venv', '.ssh', '.aws', '.codex', '.claude'}
SOURCE = {'.ts', '.tsx', '.js', '.jsx', '.py', '.swift', '.rs', '.go', '.md', '.json', '.toml', '.yaml', '.yml'}
SENSITIVE = re.compile(r'(^|[._/-])(env|secret[s]?|credential[s]?|token[s]?|password[s]?|private[-_]?key|keychain|id_rsa|id_ed25519)([._/-]|$)', re.I)

def safe_name(name):
    p = Path(name)
    return not p.is_absolute() and '..' not in p.parts and not any(x in SKIP for x in p.parts) and not SENSITIVE.search(name) and p.suffix.lower() not in {'.pem', '.key', '.p12', '.pfx', '.mobileprovision', '.sqlite', '.db', '.jsonl'}

def clean(text):
    text = re.sub(r'-----BEGIN [^-]*PRIVATE KEY-----[\s\S]*?(?:-----END [^-]*PRIVATE KEY-----|$)', '[redacted private key]', text)
    text = re.sub(r'(?:sk-[A-Za-z0-9_-]{12,}|gh[pousr]_[A-Za-z0-9_]{12,}|github_pat_[A-Za-z0-9_]+|AKIA[A-Z0-9]{16}|eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+)', '[redacted credential]', text)
    text = re.sub(r'(?i)(bearer\s+)[A-Za-z0-9._~+/-]+', r'\1[redacted]', text)
    text = re.sub(r'(?i)(https?://)[^\s/@]+(?::[^\s/@]*)?@', r'\1[redacted]@', text)
    text = re.sub(r'(?im)^.*(?:api[_-]?key|access[_-]?token|auth[_-]?token|client[_-]?secret|password|credential|private[_-]?key)\s*["\x27]?\s*[:=].*$', '[redacted credential assignment]', text)
    return text.replace('\x00', '')

def inspect(directory):
    start = time.monotonic(); deadline = start + 12
    root = Path(directory).expanduser().absolute()
    result = {'version': VERSION, 'directory': str(root), 'observedAt': int(time.time()*1000), 'git': None, 'entries': [], 'documents': [], 'changedFiles': [], 'errors': [], 'limitations': ['Evidence only; no classification or shipped-state inference.', 'Immediate entries, at most 12 documents and 8 changed source excerpts; each excerpt is truncated.', 'Secret filenames excluded and recognizable credentials redacted; arbitrary secrets embedded in ordinary prose cannot be identified reliably.']}
    if not root.is_dir() or root.is_symlink():
        result['errors'].append('Directory missing, unreadable, or a symbolic link')
        return finish(result)
    root = root.resolve()
    def error(s):
        if len(result['errors']) < 15: result['errors'].append(s)
    def git(*args):
        remaining = deadline-time.monotonic()
        if remaining <= 0: error('Directory time budget exhausted'); return None
        env = {k:v for k,v in os.environ.items() if not k.startswith('GIT_')}
        env.update(GIT_OPTIONAL_LOCKS='0', GIT_TERMINAL_PROMPT='0', GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL=os.devnull, GIT_NO_REPLACE_OBJECTS='1', LC_ALL='C')
        command = ['git', '-c', 'core.fsmonitor=false', '-c', 'core.untrackedCache=false', '-c', 'core.hooksPath=/dev/null', '-C', str(root), *args]
        try:
            with subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=env) as proc:
                chunks = bytearray(); limited = False; until = time.monotonic()+min(3, remaining)
                with selectors.DefaultSelector() as sel:
                    sel.register(proc.stdout, selectors.EVENT_READ)
                    while sel.get_map():
                        if time.monotonic() >= until: limited=True; break
                        for key,_ in sel.select(min(.1, max(0, until-time.monotonic()))):
                            data = os.read(key.fd, min(8192, 20001-len(chunks)))
                            if not data: sel.unregister(key.fileobj); break
                            chunks.extend(data)
                            if len(chunks)>20000: limited=True; break
                        if limited: break
                if limited:
                    proc.kill(); proc.wait(); error('Git '+args[0]+': output/time limit reached'); return None
                proc.wait(timeout=max(.05, until-time.monotonic()))
                return bytes(chunks).decode('utf8','replace') if proc.returncode == 0 else None
        except (OSError, subprocess.TimeoutExpired):
            error('Git '+args[0]+': unavailable or timed out'); return None
    def read(name, limit=2200):
        if time.monotonic()>deadline or not safe_name(name): return None
        path=root/name
        try:
            # Descriptor-relative traversal closes symlink-swap races in ancestors too.
            directory_fd=os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
            try:
                parts=Path(name).parts
                for part in parts[:-1]:
                    next_fd=os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=directory_fd)
                    os.close(directory_fd); directory_fd=next_fd
                fd=os.open(parts[-1], os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW, dir_fd=directory_fd)
            finally:
                os.close(directory_fd)
            with os.fdopen(fd,'rb') as f:
                st=os.fstat(f.fileno())
                if not stat.S_ISREG(st.st_mode): return None
                raw=f.read(limit+1)
            if b'\x00' in raw: return None
            return {'path':name, 'modifiedAt':int(st.st_mtime*1000), 'size':st.st_size, 'excerpt':clean(raw[:limit].decode('utf8','replace')), 'truncated':len(raw)>limit}
        except OSError: return None
    try:
        # scandir avoids materializing arbitrarily large directories before bounding them.
        with os.scandir(root) as entries:
            for i,e in enumerate(entries):
                if i>=300: error('Immediate directory listing limited to 300 entries'); break
                if not safe_name(e.name) or e.is_symlink(): continue
                try:
                    st=e.stat(follow_symlinks=False)
                    result['entries'].append({'name':e.name, 'kind':'directory' if stat.S_ISDIR(st.st_mode) else 'file', 'modifiedAt':int(st.st_mtime*1000)})
                except OSError: error('An entry disappeared or was unreadable')
        result['entries'].sort(key=lambda x:x['name'])
    except OSError: error('Directory listing unavailable')
    for name in ['README.md','readme.md','README.rst','README','package.json','Cargo.toml','pyproject.toml','go.mod','Package.swift','convex/convex.config.ts','src/convex.config.ts','docs/VISION.md']:
        doc=read(name)
        if doc: result['documents'].append(doc)
    top=git('rev-parse','--show-toplevel')
    if top:
        # A non-repo child must not accidentally inherit all its parent's work.
        result['git']={'repositoryRoot':top.strip(), 'branch':clean(git('branch','--show-current') or '').strip(), 'head':(git('rev-parse','HEAD') or '').strip(), 'recentCommits':[], 'status':[], 'diffStats':{}}
        log=git('log','-8','--format=%H%x09%ct%x09%s','--','.')
        if log:
            for line in log.splitlines():
                parts=line.split('\t',2)
                if len(parts)==3: result['git']['recentCommits'].append({'commit':parts[0], 'at':int(parts[1])*1000 if parts[1].isdigit() else 0, 'subject':clean(parts[2])[:400]})
        status=git('status','--porcelain=v1','-z','--untracked-files=normal','--','.')
        changed=[]
        if status is not None:
            parts=iter(status.split('\x00'))
            for item in parts:
                if len(item)<4: continue
                code=item[:2]; name=item[3:]
                if 'R' in code or 'C' in code: next(parts,None)
                # porcelain paths are relative to repository root, even from a subdirectory.
                absolute=Path(top.strip())/name
                try: relative=str(absolute.relative_to(root))
                except ValueError: continue
                if not safe_name(relative): continue
                result['git']['status'].append({'status':code,'path':relative})
                if Path(relative).suffix.lower() in SOURCE and len(changed)<8: changed.append(relative)
        for label,args in [('unstaged',()),('staged',('--cached',))]:
            diff=git('diff',*args,'--no-ext-diff','--no-textconv','--numstat','--','.')
            if diff is not None:
                rows=[]
                for line in diff.splitlines():
                    parts=line.split('\t',2)
                    if len(parts)==3 and safe_name(parts[2]): rows.append({'added':parts[0],'deleted':parts[1],'path':parts[2]})
                result['git']['diffStats'][label]=rows[:100]
        for name in changed:
            doc=read(name,1400)
            if doc: result['changedFiles'].append(doc)
    return finish(result)

def finish(result):
    git=result.pop('git',None)
    items=([{'id':'git','type':'git',**git}] if git else [])
    items += [{'id':'document:'+d['path'],'type':'document',**d} for d in result.pop('documents')]
    items += [{'id':'changed:'+d['path'],'type':'changed-file',**d} for d in result.pop('changedFiles')]
    entries=result.pop('entries')
    items.append({'id':'entries','type':'directory-entries','entries':entries})
    result['items']=items
    # Whole evidence items are omitted before encoding; never truncate serialized JSON.
    while len(json.dumps(result,ensure_ascii=False).encode())>MAX_OUTPUT-200:
        if entries: entries.pop()
        elif git and (git.get('status') or git.get('diffStats')):
            if git.get('status'): git['status'].pop()
            else: git['diffStats'].pop(next(iter(git['diffStats'])))
            items[0].update(git)
        elif len(items)>1: items.pop(-2)
        else: break
        if 'Output budget omitted evidence' not in result['errors']: result['errors'].append('Output budget omitted evidence')
    stable={k:v for k,v in result.items() if k not in {'observedAt','fingerprint'}}
    result['fingerprint']=hashlib.sha256(json.dumps(stable,sort_keys=True).encode()).hexdigest()
    return result

if __name__ == '__main__':
    if len(sys.argv)!=2: raise SystemExit('usage: inspect-directory.py DIRECTORY')
    print(json.dumps(inspect(sys.argv[1]), ensure_ascii=False))
