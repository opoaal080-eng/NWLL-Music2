"""Narrow, idempotent patch for the supplied full-version search worker."""
from __future__ import annotations

import ast

MARKER = '# NIGHTWELL_SEARCH_RECALL_FULL_VERSION_V1'

_OLD_OWNER = """        if owner is not None:
            previous=_OWNERS.get(owner)
            if previous and previous!=key and previous in _RECORDS:
                old=_RECORDS[previous];old['owners'].discard(owner)
                if not old['owners'] and old['pending']:old['cancel'].set()
            _OWNERS[owner]=key;_OWNERS.move_to_end(owner)
            while len(_OWNERS)>256:_OWNERS.popitem(last=False)
"""
_NEW_OWNER = """        if owner is not None:
            # One account may search spelling variants or transfer three songs
            # concurrently. A new query must not cancel its other pending jobs.
            registration=(owner,key)
            _OWNERS[registration]=None;_OWNERS.move_to_end(registration)
            while len(_OWNERS)>256:
                (old_owner,old_key),_=_OWNERS.popitem(last=False)
                old=_RECORDS.get(old_key)
                if old is not None:old['owners'].discard(old_owner)
"""
_OLD_EVICT = """        while len(_RECORDS)>MAX_QUERIES:
            _,old=_RECORDS.popitem(last=False);old['cancel'].set()
"""
_NEW_EVICT = """        while len(_RECORDS)>MAX_QUERIES:
            old_key,old=_RECORDS.popitem(last=False);old['cancel'].set()
            for registration in list(_OWNERS):
                if registration[1]==old_key:_OWNERS.pop(registration,None)
"""

_HELPER = r'''
def _clean_title(value):
    # Featuring credits are metadata, while live/remix labels still identify
    # different recordings and must survive title normalization.
    label=r'(?:feat\.?|ft\.?|featuring|при\s+уч(?:астии|аст)?\.?)'
    value=str(value or '')
    value=re.sub(r'(?i)\s*[\(\[【]\s*'+label+r'\s+[^\)\]】]+[\)\]】]', ' ', value)
    value=re.sub(r'(?i)(?<=\S)\s+'+label+r'\s+[^\(\[【]*(?=$|[\(\[【])', ' ', value)
    return ' '.join(value.split())


'''


def patch(contents: str) -> str:
    """Patch known function fragments; reject incompatible files before writing."""
    newline = '\r\n' if '\r\n' in contents else '\n'
    bom = contents.startswith('\ufeff')
    text = contents.lstrip('\ufeff').replace('\r\n', '\n')
    ast.parse(text)
    if MARKER in text:
        if all(part in text for part in (_NEW_OWNER, _NEW_EVICT, 'def _clean_title(value):')):
            return contents
        raise ValueError('Incomplete full_version_search.py search-recall patch')
    replacements = [
        (_OLD_OWNER, _NEW_OWNER),
        (_OLD_EVICT, _NEW_EVICT),
        ('def song_key(item):\n', _HELPER + 'def song_key(item):\n'),
        ("_tokens(item.get('title')) if t not in artist", "_tokens(_clean_title(item.get('title'))) if t not in artist"),
        ("_tokens(reference.get('title')) if t not in ref_artist", "_tokens(_clean_title(reference.get('title'))) if t not in ref_artist"),
        ("_tokens(candidate.get('title')) if t not in ref_artist", "_tokens(_clean_title(candidate.get('title'))) if t not in ref_artist"),
    ]
    for old, new in replacements:
        if text.count(old) != 1:
            raise ValueError('Unsupported full_version_search.py; expected worker or matching logic differs')
        text = text.replace(old, new, 1)
    text += '\n' + MARKER + '\n'
    ast.parse(text)
    return ('\ufeff' if bom else '') + text.replace('\n', newline)
