#!/usr/bin/env python3
"""Audit the Xymon upstreaming trackers (#29 Terabithia patches, #106 devel commits)
against the Rule block both issues carry.

    ./audit-trackers.py [--repo DIR] [--tera DIR] [--offline A.md B.md]

Exit 0 when every invariant holds, 1 otherwise.  Checks are grouped as:
  structural  - one line in isolation
  relational  - claims one line makes about another   <- where the real defects live
  measured    - the tracker against the code (needs --repo, and --tera for #29)

Filter notes, learned the hard way; changing them causes false positives:
  * pointer lines (PTR) are prose, not items
  * a hash on a line is only a TWIN CLAIM with identity wording, and never when the
    surrounding text negates it ("too low to call a twin", "excludes", "ambiguous")
  * a group ends at the first blank line after its members, not at the next heading
  * "twin tracked on #106" is a cross-reference, not a deferral of the verdict
"""
import argparse, json, re, subprocess, sys, os
from collections import defaultdict, Counter

VERDICT = re.compile(r'\*\*(drop\b[^*]*|take as is|take, not as written[^*]*|undecided|delegated → [^*]*)\*\*')
PTR = ('- `86` `102`', '- `6` `19` —', '- `123` — **owned', '- `145` — **owned')
CLAIM = [r'=\s*(?:the\s+)?(?:devel\s+)?`%s`', r'`%s`[^.]{0,40}\btraced 20', r'on `devel` as `%s`',
         r'contained in devel `%s`', r'slice of (?:devel )?`%s`',
         r'\bdevel `%s`', r'\btwin `%s`',      # the bare forms - 72 lines use them
         r'devel `[0-9a-f]{7,10}` \+ `%s`',     # a patch that spans two commits
         r'\(\+ [^`]{0,24}`%s`\)']
NEG = ('too low to call', 'ambiguous', 'not traced', 'no devel twin', 'excludes', 'not measurable',
       'rides ', 'not covered by', 'moot', 'inferior', 'do not port that', "don't port",
       'no overlap', 'disproven', 'no shared files', '0 hunks each', 'ships with')   # explicit disproofs are not claims
NOISE = {'Changes', 'debian/changelog', 'configure', 'configure.server', 'configure.client', 'tests/testsuite'}
fails = []
def bad(kind, msg): fails.append((kind, msg))

def items(text):
    out, head = [], ''
    for i, l in enumerate(text.split('\n'), 1):
        if l.startswith('**') and '—' in l: head = l
        if not l.startswith('- ') or any(l.startswith(p) for p in PTR): continue
        m = VERDICT.search(l)
        if not m: continue
        out.append(dict(i=i, l=l, v=m.group(1), head=head,
                        box='x' if l.startswith('- [x]') else ' ' if l.startswith('- [ ]') else '-',
                        icon='🟢' if '🟢' in l else '🟡' if '🟡' in l else '',
                        prs=[int(x) for x in re.findall(r'#(\d+)', l)]))
    return out

def tbt_id(l):
    m = re.match(r'^- (?:\[[ x]\] )?[🟢🟡]? ?`(\d+)[` ]', l)
    return m.group(1) if m else None

def claims(l):
    """devel hashes this #29 line asserts as its counterpart"""
    out = set()
    for h in set(re.findall(r'`([0-9a-f]{7,10})`', l)):
        at = l.find('`%s`' % h)
        if any(x in l[max(0, at-70):at+70] for x in NEG): continue
        if any(re.search(p % h, l) for p in CLAIM): out.add(h)
    return out

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--repo'); ap.add_argument('--tera'); ap.add_argument('--offline', nargs=2)
    ap.add_argument('--slug', default='xymon-monitoring/xymon')
    a = ap.parse_args()
    if a.offline:
        A, B = (open(f, encoding='utf-8').read() for f in a.offline)
    else:
        get = lambda n: subprocess.run(['gh', 'issue', 'view', str(n), '--repo', a.slug,
                                        '--json', 'body', '--jq', '.body'],
                                       capture_output=True, text=True, check=True).stdout
        A, B = get(29), get(106)
    I29, I106 = items(A), items(B)
    print("#29: %d items   #106: %d items" % (len(I29), len(I106)))

    # The Rule block ends WITH its last clause, whose opening words are K. Slicing
    # to A.index(K) stopped just short of it, so that clause was never compared.
    K = "**#29's Audit checklist**"
    def rule_block(t):
        a = t.index('### Rule')
        return t[a:t.index('\n', t.index(K, a))]
    if rule_block(A) != rule_block(B):
        bad('structural', 'the Rule block differs between the two issues')

    # ---- structural -------------------------------------------------------
    for src, II in (('29', I29), ('106', I106)):
        for it in II:
            L, v, box, icon = it['l'], it['v'], it['box'], it['icon']
            if len(VERDICT.findall(L)) != 1 and '**split:**' not in L:
                bad('structural', '#%s L%d: %d verdicts' % (src, it['i'], len(VERDICT.findall(L))))
            # A PR settles a line by carrying its change or by removing the need
            # for it, so `drop - superseded` takes [x] and names its superseder.
            # Every other drop is our own judgement, with no PR to point at.
            if box != '-' and v.startswith('drop'):
                if 'superseded' not in v:
                    bad('structural', '#%s L%d: drop carries a checkbox - only '
                                      '`drop - superseded` does, naming the PR that '
                                      'superseded it' % (src, it['i']))
                elif not re.search(r'#\d{2,3}\b', L):
                    bad('structural', '#%s L%d: `drop - superseded` with [x] names no '
                                      'PR - say what superseded it' % (src, it['i']))
                elif icon == '🟢':
                    bad('structural', '#%s L%d: superseded drop marked 🟢 - the icon '
                                      'reports where this line\'s change is, and a '
                                      'superseded change never reaches `main`'
                        % (src, it['i']))
            if box == ' ' and icon == '🟢':
                bad('structural', '#%s L%d: [ ] with 🟢 - green says nothing is owed' % (src, it['i']))
            if box == ' ' and re.search(r'carried by \*\*(PR )?#\d+', L):
                bad('structural', '#%s L%d: prose names a carrier beside [ ]' % (src, it['i']))
            if v.startswith('delegated') and (box != '-' or icon) and '**split:**' not in L:
                bad('structural', '#%s L%d: delegated line carries a box or icon' % (src, it['i']))
            if v.startswith('delegated') and src == '29':
                bad('structural', '#29 L%d: delegation is one-way (#106 -> #29)' % it['i'])

    # ---- relational -------------------------------------------------------
    h2tbt, tbt = defaultdict(set), {}
    for it in I29:
        t = tbt_id(it['l'])
        if not t: continue
        tbt[t] = it
        for h in claims(it['l']): h2tbt[h].add(t)
    ids = set(tbt)
    for it in I106:
        # ids come in runs: "TBT `4`/`6`", "delegated -> #29 `56`/`279`/`179`" - take them all
        named = set()
        for m in re.finditer(r'(?:#29|TBT)\s*((?:`\d+`\s*/?\s*)+)', it['l']):
            named |= set(re.findall(r'\d+', m.group(1)))
        # 1. ownership terminates
        if it['v'].startswith('delegated'):
            for t in named & ids:
                if re.search(r'#106[^.]{0,30}carries the checkbox|Ref only', tbt[t]['l']) and \
                   not tbt[t]['v'].startswith('drop'):
                    bad('relational', 'LOOP: #106 L%d delegates to TBT %s, which hands its verdict back'
                        % (it['i'], t))
            for t in named - ids:
                bad('relational', '#106 L%d: delegation target TBT %s has no #29 line' % (it['i'], t))
        # 2. a pointer is total   4. a counterpart names you back
        for h in set(re.findall(r'`([0-9a-f]{7,10})`', it['l'])):
            cl = {t for t in h2tbt.get(h, set()) if not tbt[t]['v'].startswith('drop')}
            miss = cl - named
            if miss and it['v'].startswith('delegated'):
                bad('relational', '#106 L%d: marker omits TBT %s, which also claims `%s`'
                    % (it['i'], sorted(miss, key=int), h))
            elif miss:
                bad('relational', '#106 L%d: `%s` is claimed by TBT %s, not named here'
                    % (it['i'], h, sorted(miss, key=int)))

    # ---- measured ---------------------------------------------------------
    if a.repo:
        R = a.repo
        git = lambda *c: subprocess.run(['git', '-C', R, *c], capture_output=True).stdout.decode('utf-8', 'replace')
        anc = lambda h, r: subprocess.run(['git', '-C', R, 'merge-base', '--is-ancestor', h, r],
                                          capture_output=True).returncode == 0
        seen = defaultdict(set)
        for t in (A, B):
            for h in set(re.findall(r'`([0-9a-f]{7,10})`', t)):
                if subprocess.run(['git', '-C', R, 'rev-parse', '-q', '--verify', h + '^{commit}'],
                                  capture_output=True).returncode:
                    bad('measured', 'citation `%s` resolves to no commit' % h); continue
                if not (anc(h, 'origin/main') or anc(h, 'origin/devel')):
                    bad('measured', 'citation `%s` is not reachable from main or devel (PR-branch sha?)' % h)
                seen[git('rev-parse', h + '^{commit}').strip()].add(h)
        for full, abbrevs in seen.items():
            if len(abbrevs) > 1:
                bad('measured', 'one commit cited under %s' % sorted(abbrevs))
        prs = {}
        try:
            prs = {p['number']: p for p in json.loads(subprocess.run(
                ['gh', 'pr', 'list', '--repo', a.slug, '--state', 'all', '--limit', '600',
                 '--json', 'number,state,isDraft'], capture_output=True, text=True).stdout or '[]')}
        except Exception: pass
        # ---- an open PR already carries this, and the line does not say so -----
        # The tracker's job is to stop work being redone. A patch whose lines are
        # already in an open PR, on a line that names no PR, is exactly that risk -
        # and it is invisible to every text check, because the line is self-consistent.
        #
        # This measures TEXT, so it finds replays and misses rewrites. #414 covers
        # TBT `1`'s feature completely at 11% line overlap - different design, same
        # outcome - and nothing here would fire on it. A silent run means no patch
        # was found duplicated line-for-line; it does not mean no PR does the work.
        if a.tera and prs:
            import tempfile
            cache = os.path.join(tempfile.gettempdir(), 'xymon-prdiff')
            os.makedirs(cache, exist_ok=True)
            norm = lambda x: re.sub(r'\s+', '', x)
            sig = lambda x: len(re.sub(r'[^A-Za-z0-9_]', '', x)) >= 8
            openpr = [n for n, v in prs.items() if v.get('state') == 'OPEN']
            pra = {}
            for n in openpr:
                f = os.path.join(cache, '%d.diff' % n)
                if not os.path.exists(f):
                    d = subprocess.run(['gh', 'pr', 'diff', str(n), '--repo', a.slug],
                                       capture_output=True, text=True).stdout
                    open(f, 'w').write(d)
                adds, files = set(), set()
                for l in open(f, errors='replace'):
                    if l.startswith('diff --git'): files.add(os.path.basename(l.split(' b/')[-1].strip()))
                    elif l.startswith('+') and not l.startswith('+++') and sig(l[1:]): adds.add(norm(l[1:]))
                if adds: pra[n] = (adds, files)
            for it in I29:
                if it['v'].startswith('drop') or it['box'] == 'x': continue
                m = re.search(r'`(xymon[\w_.+-]*\.patch[\w.]*)`', it['l'])
                if not m: continue
                pf = os.path.join(a.tera, m.group(1))
                if not os.path.exists(pf): continue
                adds, files = set(), set()
                for x in open(pf, errors='replace'):
                    if x.startswith('+++'): files.add(os.path.basename(x.split()[1].split('\t')[0]))
                    elif x.startswith('+') and sig(x[1:]): adds.add(norm(x[1:].rstrip('\n')))
                if len(adds) < 4: continue          # too small for a ratio to mean anything
                # a trunk variant that names its stable pair has already deferred
                # the decision; the PR carrying the pair is not a missed carrier here
                if re.search(r'variant of `\d+`', it['l']): continue
                named = {int(x) for x in re.findall(r'#(\d{2,3})\b', it['l'])}
                for n, (pa, pf2) in pra.items():
                    if n in named or not (files & pf2): continue
                    cov = 100 * len(adds & pa) // len(adds)
                    if cov >= 60:
                        bad('measured', '#29 L%d: open PR #%d already carries %d%% of this '
                                        'patch and the line does not name it' % (it['i'], n, cov))

        for src, II in (('29', I29), ('106', I106)):
            for it in II:
                scope = it['l'] + ' ' + it['head']
                # a partial claim is still a claim that some of it is in `main`
                if it['icon'] in ('🟢', '🟡') or 'drop — already in `main`' in it['v']:
                    ok = any(prs.get(int(p), {}).get('state') == 'MERGED' for p in re.findall(r'#(\d+)', scope)) \
                         or any(anc(h, 'origin/main') for h in re.findall(r'`([0-9a-f]{7,10})`', scope)) \
                         or re.search(r'`[A-Za-z0-9_./*-]+\.(?:c|h|sh|cfg|rules|in|DIST|[1-8])'
                                      r'(?::[\d,\s-]+)?`', scope)
                    if not ok:
                        bad('measured', '#%s L%d: in-main claim with no main-side evidence' % (src, it['i']))
                for p in re.findall(r'#(\d+)', it['l']):
                    if prs.get(int(p), {}).get('state') == 'CLOSED' and it['box'] != '-':
                        bad('measured', '#%s L%d: names #%s, closed unmerged - it carries nothing'
                            % (src, it['i'], p))

    # ---- a supersede is not settled until its superseder lands ------------
    # While the PR is open the drop is conditional: abandon the PR and the change
    # is wanted again. So the line waits in a priority bucket with `needs <PR>`,
    # and moves to Settled only once the PR merges. Both directions go stale on
    # their own - a merge elsewhere is exactly what nobody comes back to update.
    for src, t in (('29', A), ('106', B)):
        lines = t.split('\n')
        def bucket_of(i):
            for k in range(i, -1, -1):
                if re.match(r'^#{2,3} ', lines[k]) and not lines[k].startswith('####'):
                    return lines[k].strip('# ')
            return ''
        for it in items(t):
            if 'superseded' not in it['v'] or it['box'] != 'x': continue
            sup = [int(x) for x in re.findall(r'#(\d{2,3})\b', it['l']) if int(x) in prs]
            if not sup: continue
            merged = any(prs[p].get('state') == 'MERGED' for p in sup)
            settled = bucket_of(it['i'] - 1).startswith('Bucket 4')
            if merged and not settled:
                bad('measured', '#%s L%d: superseded by a merged PR %s but not in Settled'
                    % (src, it['i'], [p for p in sup if prs[p].get('state') == 'MERGED']))
            if not merged and settled:
                bad('measured', '#%s L%d: in Settled, but its superseder %s has not '
                                'merged - the drop is still conditional' % (src, it['i'], sup))
            if not merged and not re.search(r'\*\*needs [^*]*#\d', it['l']):
                bad('measured', '#%s L%d: superseder still open - say `needs #<pr>` so the '
                                'line is revisited if it is abandoned' % (src, it['i']))

    # ---- the Audit checklist holds plain progress entries only -------------
    # "a plain progress list, where [x] just means done" - so nothing there may
    # carry a TBT id or a verdict. Without this, a line misfiled into the list is
    # structurally legal and every other check stays silent: that is exactly how
    # nine Bucket 5 items once came to sit at the end of it.
    K2 = '## Audit checklist'
    if K2 in A:
        for i, l in enumerate(A[A.index(K2):].split('\n'), A[:A.index(K2)].count('\n') + 1):
            if not l.startswith('- '): continue
            why = ('a TBT id' if tbt_id(l) else 'a verdict' if VERDICT.search(l) else None)
            if why:
                bad('structural', '#29 L%d: the Audit checklist carries %s - it is a plain '
                                  'progress list; the item belongs in a bucket' % (i, why))

    # ---- headings that have grown into prose ------------------------------
    # a heading carries what is true of every member; findings hoisted into it over
    # time turn it into an essay. Flag outliers rather than a fixed length, so the
    # threshold follows however terse the trackers happen to be.
    heads = [(src, i, l) for src, t in (('29', A), ('106', B))
             for i, l in enumerate(t.split('\n'), 1)
             if re.search(r'\*group of \d+ (?:commits?|patches)', l)]
    if len(heads) >= 5:
        lens = sorted(len(l.rstrip()) for _, _, l in heads)
        median = lens[len(lens) // 2]
        # Floor from what a legitimately dense heading costs: identity + the shared
        # decision + a shared gap runs to ~500 chars with nothing duplicated. Below
        # that the ratio alone would ratchet - every heading trimmed lowers the median
        # and pulls in the next one.
        limit = max(2 * median, 520)
        for src, i, l in heads:
            if len(l.rstrip()) > limit:
                bad('structural', '#%s L%d: heading is %d chars (median %d, limit %d) - '
                                  'hoisted findings belong on the line that owns them, and '
                                  'anything readable from a PR or patch is derived state'
                                  % (src, i, len(l.rstrip()), median, limit))

    # ---- verdict 3 must name where, on the line itself --------------------
    # a PR belongs to the line, not the heading: coverage is per-line state and is
    # read with the verdict. A member that inherits its PR from the heading cannot
    # be ported from its own line, and a group-level claim is usually a joint one -
    # true of the group, exact for no member - which hides that members differ.
    for src, t in (('29', A), ('106', B)):
        for i, l in enumerate(t.split('\n'), 1):
            if not l.startswith('- [') or 'a different version exists elsewhere' not in l:
                continue
            # verdict 3 enumerates three wheres - the other tracker, `main`, an open
            # PR - so accept the id of any of them: a PR number, a commit hash, or an
            # explicit `main` (which Cross-reference lets you cite by section).
            if (re.search(r'#\d{2,3}\b', l) or re.search(r'`[0-9a-f]{8,9}`', l)
                    or '`main`' in l):
                continue
            bad('structural', '#%s L%d: verdict 3 names nowhere - the PR or commit '
                              'holding the better version must be on this line, not '
                              'only on its heading' % (src, i))

    # ---- exactly two levels: bucket, then phase ---------------------------
    # a third level is where joint claims hide - it reads as belonging to the
    # parent's members too, and gives a member somewhere to keep its verdict other
    # than its own line. Two ways to break it: a heading inside another's member
    # run, and a heading with no members of its own (a roster said twice).
    # A phase heading has one of a closed set of shapes. Defining it by what it
    # looks like - not by "is followed by a member" - is what lets the check see a
    # heading that has no members, which is the violation we are looking for. It
    # also keeps narrative prose ("**151** apply cleanly forward, ...") out: a
    # paragraph that merely opens in bold matches none of these.
    HEAD = re.compile(r'\*\*(?:Phase |\u2192 )'          # **Phase 2b - ... / **-> `devel-bfq`
                      r'|\*group of \d+ '                 # *group of N patches/commits*
                      r'|\(\d+\):?\*\*'                    # **xymond core (24)** / **... (0):**
                      r'|^\*\*[^*]+\*\*\s*$'              # a line that is entirely bold
                      r'|:\*\*\s*$')                      # **... chain (2):**
    def is_head(L, i):
        return bool(HEAD.search(L[i-1]))

    def empty_ok(l):
        return '(0)' in l          # an explicitly empty phase is a park, not a duplicate

    for src, t in (('29', A), ('106', B)):
        L = t.split('\n')
        head, seen = None, 0
        for i, l in enumerate(L, 1):
            if l.startswith('#'):
                if head and not seen and not empty_ok(L[head-1]):
                    bad('structural', '#%s L%d: phase has no members of its own - a heading '
                                      'that only introduces another heading is a roster said '
                                      'twice; merge them' % (src, head))
                head, seen = None, 0
            elif l.startswith('- '):
                # a delegated member carries no checkbox: `- `hash` - **delegated -> #29**`
                if head: seen += 1
            elif l.startswith('**') and is_head(L, i):
                if head and seen:
                    bad('structural', '#%s L%d: heading nested inside the members of L%d - '
                                      'nothing may sit under a phase; promote it to its own '
                                      'phase instead' % (src, i, head))
                elif head and not seen and not empty_ok(L[head-1]):
                    bad('structural', '#%s L%d: phase has no members of its own - a heading '
                                      'that only introduces another heading is a roster said '
                                      'twice; merge them' % (src, head))
                head, seen = i, 0
            elif not l.strip():
                if head and seen:
                    head, seen = None, 0


    # ---- citation form, and one `needs` mark per line ---------------------
    # An artifact is cited by its permanent id; a place in code by file and symbol,
    # where the line number may accompany but never replace it. A bare file:line
    # cannot be told from a stale one by a later reader. And every prerequisite
    # belongs inside a single `needs` mark, so "what blocks this" is one lookup.
    LOC = re.compile(r'`([A-Za-z0-9_./-]*\.(?:c|h|cfg|spec|sh|DIST|rules|in))((?::\d+[-\d]*)+)')
    SYM = re.compile(r'`([A-Za-z_][A-Za-z0-9_]*)\(\)`|`([A-Za-z_][A-Za-z0-9_]{3,})`')
    for src, t in (('29', A), ('106', B)):
        for i, l in enumerate(t.split('\n'), 1):
            for m in LOC.finditer(l):
                ctx = l[max(0, m.start() - 150):m.end() + 90]
                syms = [a or b for a, b in SYM.findall(ctx)]
                if not [x for x in syms if not x.endswith(('.c', '.h')) and x not in ('main', 'devel')]:
                    bad('structural', '#%s L%d: bare `%s%s` - name the symbol it sits in; '
                                      'a line number may accompany that, never replace it'
                                      % (src, i, m.group(1), m.group(2)))
            if l.startswith('- ') and len(re.findall(r'\*\*needs [^*]+\*\*', l)) > 1:
                bad('structural', '#%s L%d: more than one `needs` mark - name every '
                                  'prerequisite inside one of them' % (src, i))

    # ---- an item delegated from more than one commit --------------------
    # Legitimate when a patch really is split across commits - #29 `3` is
    # `266644346` plus the client default `3730d2c12`, and its line says so. The
    # test is whether the #29 line names every commit that delegates to it: if it
    # does not, one of those delegations is a duplicate reference to the item.
    tbt = {t: it for it in I29 for t in [tbt_id(it['l'])] if t}
    src_of = {}
    for it in I106:
        m = re.search(r'\*\*delegated → #29 ([^*]+)\*\*', it['l'])
        if not m: continue
        for h in re.findall(r'`([0-9a-f]{7,10})`', it['l'].split('**delegated')[0]):
            for t in re.findall(r'`(\d+)`', m.group(1)):
                src_of.setdefault(t, []).append((h, it['i']))
    for t, srcs in sorted(src_of.items()):
        if len(srcs) < 2 or t not in tbt: continue
        c = claims(tbt[t]['l'])
        for h, i in srcs:
            if h not in c:
                bad('relational', '#106 L%d delegates `%s`, but #29 L%d never names `%s` - '
                                  'an item delegated from several commits must name each'
                                  % (i, t, tbt[t]['i'], h))

    # ---- a heading names no PR --------------------------------------------
    # PR numbers move, merge, close and get superseded, and a heading is the one
    # place nobody re-reads when they do. The fact belongs on the lines it is true
    # of, or in the section's prose - both of which are read and revised as text.
    for src, t in (('29', A), ('106', B)):
        L = t.split('\n')
        try: end = next(i for i, l in enumerate(L) if l.startswith("**#29's Audit checklist**"))
        except StopIteration: end = -1
        for i, l in enumerate(L):
            if i <= end or l.startswith('- '): continue
            if not (re.match(r'^#{2,4} ', l) or (l.startswith('**') and is_head(L, i + 1))): continue
            prs = [p for p in re.findall(r'#(\d{2,3})\b', l) if p not in ('29', '106')]
            if prs:
                bad('structural', '#%s L%d: heading names PR %s - a heading carries the '
                                  'subject; put the PR on the lines it is true of, or in '
                                  'the section prose' % (src, i + 1, ' '.join('#'+p for p in sorted(set(prs)))))
            # the same for commit ids: a heading listing the very commits its members
            # are is the roster said twice - and it is the heading that goes stale when
            # a member moves, since nothing recounts it.
            mem, k, started = [], i + 1, False
            while k < len(L):
                if L[k].startswith('- '): mem.append(L[k]); started = True
                elif started or L[k].startswith(('#', '**')): break
                k += 1
            if mem:
                mh = set()
                for m in mem: mh |= set(re.findall(r'`([0-9a-f]{7,10})`', m))
                dup = set(re.findall(r'`([0-9a-f]{7,10})`', l)) & mh
                if dup:
                    bad('structural', '#%s L%d: heading repeats %s, which its own members '
                                      'carry - the heading names the subject, the lines name '
                                      'the commits' % (src, i + 1, ' '.join('`%s`' % x for x in sorted(dup))))

    # ---- one line, one mention of an id ------------------------------------
    # Distinct roles can each name a PR once - carrier, `needs`, a conflict - but
    # past two the line is restating rather than saying something new, and long
    # lines are where it hides. The shared-risk list is one mention of a list.
    for src, t in (("29", A), ("106", B)):
        for it in items(t):
            body = re.sub(r"\(#\d{2,3}(?: #\d{2,3})+\)", "", it["l"])
            for p, n in Counter(re.findall(r"#(\d{2,3})\b", body)).items():
                if p in ("29", "106") or n < 3: continue
                bad("structural", "#%s L%d: names #%s %d times - say it once per role, "
                                  "then use a pronoun" % (src, it["i"], p, n))

    # ---- a named prerequisite carries the mark -----------------------------
    # Sequencing says prose "may stay as explanation", but never as the substitute:
    # a dependency is read from `needs <id>` alone, so one written only in prose is
    # invisible to "what can start now". The guard is what makes the prose safe -
    # an indefinite object ("needs a receiver") is a property, not a prerequisite,
    # and the verdict's own "needs improvement" is a verdict, not an edge.
    DEP = re.compile(r'\b(needs?|requires?|depends? on|port(?:ed)? after|sequence after)\s+'
                     r'(?!an?\s)(?:the\s+)?[^.\u00b7;]{0,60}?(`\d{1,4}`|#\d{2,3}\b|`[0-9a-f]{7,10}`)',
                     re.I)
    for src, t in (('29', A), ('106', B)):
        for it in items(t[t.index('### '):]):
            l = it['l']
            if re.search(r'\*\*needs ', l): continue
            m = DEP.search(re.sub(r'_\(cond:[^)]*\)_', '', VERDICT.sub('', l)))
            if m:
                bad('structural', '#%s L%d: "%s" names a prerequisite in prose with no '
                                  '`needs` mark - prose explains an edge, it never '
                                  'carries one' % (src, it['i'], m.group(0)[:44]))

    # ---- date what you establish ------------------------------------------
    # A measurement records when it was made and against what, or it can only be
    # re-done. The base is usually already on the line - it names the commit it
    # measured against - so what goes missing is the date. "re-read" is excluded:
    # on these trackers it names a feature (hosts.cfg re-read), not a reading.
    # no trailing \b after the alternation: `%` and the space that follows it are
    # both non-word, so a boundary never exists there and `81%` would never match
    MEAS = re.compile(r'\b(?:measured|traced|verified|scanned|contained in)\b|\d+%', re.I)
    DATED = re.compile(r'20\d\d-\d\d-\d\d|date unknown')
    for src, t in (('29', A), ('106', B)):
        for it in items(t[t.index('### '):]):
            if MEAS.search(it['l']) and not DATED.search(it['l']):
                bad('structural', '#%s L%d: "%s" is a measurement with no date - an '
                                  'undated claim can only be re-done, not refreshed'
                    % (src, it['i'], MEAS.search(it['l']).group(0)))

    # ---- blocked is read, never written -----------------------------------
    # Derived state names the three marks the Rule block rejected by name. A
    # heading may still carry a shared blocker - what stands in the way is a fact
    # about the group - but the blocked *state* is read from `needs` plus the
    # state of its target, so writing it down is what goes stale.
    for src, t in (('29', A), ('106', B)):
        head = t.index("**#29's Audit checklist**")
        for i, l in enumerate(t[t.index('\n', head):].split('\n'), t[:t.index('\n', head)].count('\n') + 2):
            m = re.search(r'\bBLOCKED\b|⏳|🔴', l)
            if m:
                bad('structural', '#%s L%d: writes "%s" - a blocked mark was rejected; '
                                  'state what stands in the way, and let blocked be read '
                                  'from `needs`' % (src, i, m.group(0)))

    # ---- the mark's own words, repeated in the prose ----------------------
    # *No repetition*, test 1: if the verdict is `drop - superseded`, the prose
    # says by what, never "superseded" again. The commonest form is prose that
    # re-derives a mark from the rules ("the box stays empty: [ ] is the default
    # for an undecided line") - a reading, not a fact about the change.
    ECHO = ('superseded', 'not as written', 'take as is', 'undecided', 'delegated',
            'already in `main`')
    for src, t in (('29', A), ('106', B)):
        for it in items(t[t.index('### '):]):
            m = VERDICT.search(it['l'])
            if not m: continue
            rest = it['l'][m.end():]
            for w in ECHO:
                if w in m.group(0) and re.search(r'\b' + re.escape(w), rest):
                    bad('structural', '#%s L%d: prose repeats "%s", which the verdict '
                                      'already says - prose adds which part, which symbol '
                                      'or why, or says nothing' % (src, it['i'], w))
                    break

    # ---- [x] names the PR that carries it ---------------------------------
    # The box asserts carriage, and a carrier a reader cannot follow is not one.
    for src, II in (('29', I29), ('106', I106)):
        for it in II:
            if it['box'] != 'x': continue
            if not [p for p in re.findall(r'#(\d{2,3})\b', it['l']) if p not in ('29', '106')]:
                bad('structural', '#%s L%d: [x] names no PR - the tick says one carries '
                                  'it, so say which' % (src, it['i']))

    # ---- group counts (a blank line closes the group) ---------------------
    for src, t in (('29', A), ('106', B)):
        L = t.split('\n')
        for i, l in enumerate(L):
            m = re.search(r'\*group of (\d+) (?:commits?|patches)', l)
            if not m: continue
            c, started = 0, False
            for s in L[i+1:]:
                if s.startswith('- '): c, started = c + 1, True
                elif started: break
                elif s.startswith('**'): break
            if c != int(m.group(1)):
                bad('structural', '#%s L%d: heading says %s members, found %d' % (src, i+1, m.group(1), c))

    # ---- every stated count must match what it heads ----------------------
    # Three shapes state one: "*group of N patches*", a bold "**subject (N)**",
    # and a section heading that opens with a number. All are read by people as
    # promises about the list below them, and all go stale silently.
    for src, t in (('29', A), ('106', B)):
        L = t.split('\n')
        for i, l in enumerate(L):
            section = l.startswith('####')
            if section:
                m = re.match(r'#+ (\d+) ', l)
            elif l.startswith('**'):
                m = re.search(r'\((\d+)\)\*\*|\((\d+)\):\*\*', l)
            else:
                continue
            if not m: continue
            want = int(next(g for g in m.groups() if g))
            c, started = 0, False
            for x in L[i+1:]:
                # a section runs to the next `#` heading and spans the blank lines
                # between its groups; a group is closed by its first blank line
                if x.startswith('#'): break
                if x.startswith('- '): c, started = c + 1, True
                elif not section and (started or x.startswith('**')): break
            if c != want:
                bad('structural', '#%s L%d: heading states %d, the section holds %d - %s'
                                  % (src, i + 1, want, c, l[:56]))

    # ---- the record's history, in prose -----------------------------------
    # A finding stays; how the entry got here does not. This is a detector, not a
    # slot definition - the phrases are the ones these two trackers actually grew,
    # each naming a superseded state of the list rather than a fact about the code.
    HIST = ('an earlier form', 'earlier run', 'the old run', 'counts superseded',
            're-measurement above', 'as measured then', 'membership re-derived',
            'restructured', 'moved from bucket', 're-triaged', 'corrects an earlier',
            'was previously', 'is retracted', 'no line was added', 'previously claimed',
            'used to define', 'superseded by the')
    for src, t in (('29', A), ('106', B)):
        L = t.split('\n')
        try: end = next(i for i, l in enumerate(L) if l.startswith("**#29's Audit checklist**"))
        except StopIteration: end = -1          # the clause quotes these phrases itself
        for i, l in enumerate(L[end+1:], end + 2):
            low = l.lower()
            for h in HIST:
                if h in low:
                    bad('structural', '#%s L%d: "%s" describes the record, not the '
                                      'artifact - keep the finding, drop how the entry '
                                      'got here' % (src, i, h))
                    break

    for kind in ('structural', 'relational', 'measured'):
        n = [m for k, m in fails if k == kind]
        print("  %-11s %s" % (kind, 'PASS' if not n else 'FAIL (%d)' % len(n)))
        for m in n: print("     " + m)
    return 1 if fails else 0

if __name__ == '__main__':
    sys.exit(main())
