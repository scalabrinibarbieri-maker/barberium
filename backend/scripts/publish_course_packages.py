#!/usr/bin/env python3
"""Publicador conservador de pacotes curso-lunivo-*.zip em Cloudflare R2.

Inclui etapas informativas (info) com imagens HTTPS opcionais. Nao altera
catalogo ou unidades publicadas sem revisao e verificacao previas.
"""
from __future__ import annotations
import argparse
import ipaddress
import json
import os
import re
import sys
import zipfile
from pathlib import Path
from typing import Any
from urllib.parse import urlsplit

BUCKET = 'lunivo-audios'
CATALOG_KEY = 'courses/v1/catalog.json'
PART_FILE = 'catalog-part.json'
MAX_CATALOG_BYTES = 64 * 1024
MAX_UNIT_BYTES = 512 * 1024
MAX_ZIP_BYTES = 5 * 1024 * 1024
UNIT_ID = re.compile(r'^[a-z]{2}-(?:a1|a2|b1|b2|c1|c2)-u[0-9]{2,4}$')
LESSON_ID = re.compile(r'^[a-z]{2}-(?:a1|a2|b1|b2|c1|c2)-[0-9]{2,4}$')
EX_ID = re.compile(r'^q[0-9]{2,6}$')
PACK_FILE = re.compile(r'^curso-lunivo-[a-zA-Z0-9._-]+\.zip$')
BUILTIN_LESSON_IDS = {'it-a1-01', 'it-a1-02', 'it-a1-03'}
BUILTIN_EXERCISE_IDS = {f'q{i:02d}' for i in range(1, 19)}

class PublicationError(ValueError):
    pass

def fail(reason: str) -> None:
    raise PublicationError(reason)

def read_json(blob: bytes, limit: int) -> Any:
    if not blob or len(blob) > limit: fail('JSON fora do limite.')
    try: return json.loads(blob.decode('utf-8'))
    except (UnicodeDecodeError, ValueError): fail('JSON inválido.')

def serialized(obj: Any, limit: int) -> bytes:
    data = (json.dumps(obj, ensure_ascii=False, separators=(',', ':')) + '\n').encode('utf-8')
    if len(data) > limit: fail('JSON final ultrapassa o limite de tamanho.')
    return data

def string(v: Any, n: int) -> bool:
    return isinstance(v, str) and bool(v.strip()) and len(v) <= n and all(ord(c) >= 32 for c in v)

def integer(v: Any, low: int, high: int) -> bool:
    return type(v) is int and low <= v <= high

def public_https_image(value: Any) -> bool:
    if not isinstance(value, str) or not 1 <= len(value) <= 700 or not value.startswith('https://'):return False
    try:
        parsed = urlsplit(value)
        host = (parsed.hostname or '').lower()
        if parsed.scheme != 'https' or parsed.username or parsed.password or parsed.fragment or parsed.port is not None:return False
        if not host or '.' not in host or host.endswith(('.local', '.internal', '.localhost')):return False
        try:
            ipaddress.ip_address(host)
            return False
        except ValueError: pass
        return True
    except ValueError:return False

def summary_unit(raw: Any) -> dict:
    if not isinstance(raw, dict): fail('Resumo da unidade inválido.')
    required={'id','language','level','order','title','subtitle','revision','lessons'}
    if set(raw) != required: fail('Campos do resumo da unidade inesperados.')
    if not string(raw['id'], 40) or not UNIT_ID.fullmatch(raw['id']): fail('ID da unidade inválido.')
    if raw['language'] != raw['id'][:2] or raw['level'] != raw['id'].split('-')[1].upper(): fail('Idioma/nível inválido.')
    if not integer(raw['order'],2,9999) or not integer(raw['revision'],1,99999): fail('Ordem/revisão inválida.')
    if not string(raw['title'],90) or not string(raw['subtitle'],180): fail('Título/subtítulo inválido.')
    if not isinstance(raw['lessons'],list) or not 1 <= len(raw['lessons']) <= 20: fail('Número de lições inválido.')
    lesson_ids=set()
    for lesson in raw['lessons']:
        if not isinstance(lesson,dict) or set(lesson) != {'id','title','subtitle','exerciseCount'}: fail('Resumo de lição inválido.')
        lid=lesson['id']
        if not isinstance(lid,str) or not LESSON_ID.fullmatch(lid) or not lid.startswith(raw['id'][:5]+'-') or lid in BUILTIN_LESSON_IDS or lid in lesson_ids: fail('ID de lição repetido ou inválido.')
        lesson_ids.add(lid)
        if not string(lesson['title'],90) or not string(lesson['subtitle'],180) or not integer(lesson['exerciseCount'],2,30): fail('Metadados da lição inválidos.')
    return raw

def parse_catalog(raw: Any, *, partial: bool) -> list[dict]:
    if not isinstance(raw,dict) or set(raw) != {'version','units'} or raw['version'] != 1 or not isinstance(raw['units'],list):fail('Formato do catálogo inválido.')
    if len(raw['units']) > (8 if partial else 100):fail('Quantidade excessiva de unidades no catálogo.')
    units=[summary_unit(v) for v in raw['units']]
    seen_units=set();seen_lessons=set(BUILTIN_LESSON_IDS)
    for unit in units:
        if unit['id'] in seen_units: fail('Unidade duplicada no catálogo.')
        seen_units.add(unit['id'])
        for entry in unit['lessons']:
            if entry['id'] in seen_lessons:fail('Lição repetida entre unidades.')
            seen_lessons.add(entry['id'])
    return units

def validate_exercise(ex: Any, used: set[str]) -> None:
    if not isinstance(ex,dict):fail('Exercício inválido.')
    eid=ex.get('id')
    if not isinstance(eid,str) or not EX_ID.fullmatch(eid) or eid in BUILTIN_EXERCISE_IDS or eid in used:fail('ID de exercício repetido, reservado ou inválido.')
    used.add(eid)
    typ=ex.get('type')
    if not all(string(ex.get(field),limit) for field,limit in [('prompt',500),('instruction',150),('explanation',1800 if typ=='info' else 700)]):fail('Texto do exercício inválido.')
    base={'type','id','prompt','instruction','explanation'}
    if typ == 'info':
        if set(ex) - (base | {'category','image'}):fail('Campos extras na explicação.')
        if ex.get('category','tip') not in ('vocabulary','culture','grammar','tip'):fail('Categoria de explicação inválida.')
        if 'image' in ex:
            photo=ex['image']
            if not isinstance(photo,dict) or not {'url','alt'} <= set(photo) <= {'url','alt','caption'} or not public_https_image(photo['url']) or not string(photo['alt'],180) or ('caption' in photo and not string(photo['caption'],240)):
                fail('Imagem explicativa inválida.')
    elif typ in ('choice','listen_choice'):
        extra={'options','correctOptionId'}|({'audioExerciseId'} if typ=='listen_choice' else set())
        if set(ex)!=base|extra or not isinstance(ex['options'],list) or not 2<=len(ex['options'])<=6:fail('Escolha inválida.')
        ids=set()
        for op in ex['options']:
            if not isinstance(op,dict) or set(op)!={'id','label'} or not string(op['id'],20) or not string(op['label'],160) or op['id'] in ids:fail('Opção inválida.')
            ids.add(op['id'])
        if ex['correctOptionId'] not in ids:fail('Resposta correta ausente.')
        if typ=='listen_choice' and (not isinstance(ex['audioExerciseId'],str) or not EX_ID.fullmatch(ex['audioExerciseId'])):fail('Referência de áudio inválida.')
    elif typ in ('write','listen_write'):
        extra={'acceptedAnswers','sampleAnswer'}|({'audioExerciseId'} if typ=='listen_write' else set())
        if set(ex)!=base|extra or not isinstance(ex['acceptedAnswers'],list) or not 1<=len(ex['acceptedAnswers'])<=10 or not all(string(a,180) for a in ex['acceptedAnswers']) or not string(ex['sampleAnswer'],180):fail('Resposta escrita inválida.')
        if typ=='listen_write' and (not isinstance(ex['audioExerciseId'],str) or not EX_ID.fullmatch(ex['audioExerciseId'])):fail('Referência de áudio inválida.')
    elif typ=='match':
        if set(ex)!=base|{'pairs'} or not isinstance(ex['pairs'],list) or not 2<=len(ex['pairs'])<=8:fail('Associação inválida.')
        ids=set()
        for p in ex['pairs']:
            if not isinstance(p,dict) or set(p)!={'id','left','right'} or not string(p['id'],30) or not re.fullmatch(r'[a-z0-9-]{1,30}',p['id']) or p['id'] in ids or not string(p['left'],100) or not string(p['right'],100):fail('Par inválido.')
            ids.add(p['id'])
    else:fail('Tipo de exercício ainda não suportado pelo aplicativo.')

def validate_unit(doc: Any, summary: dict, exercise_ids: set[str]) -> None:
    if not isinstance(doc,dict) or set(doc)!={'version','unitId','revision','lessons'} or doc['version']!=1 or doc['unitId']!=summary['id'] or doc['revision']!=summary['revision']:fail('Versão ou ID da unidade inválido.')
    if not isinstance(doc['lessons'],list) or len(doc['lessons'])!=len(summary['lessons']):fail('Lições não correspondem ao catálogo.')
    for l, ref in zip(doc['lessons'], summary['lessons']):
        if not isinstance(l,dict) or set(l)!={'id','title','subtitle','unit','exercises'}:fail('Campos da lição inválidos.')
        if l['id']!=ref['id'] or l['title']!=ref['title'] or l['subtitle']!=ref['subtitle'] or l['unit']!=summary['order']:fail('Lição diverge do resumo.')
        if not isinstance(l['exercises'],list) or len(l['exercises'])!=ref['exerciseCount']:fail('Contagem de exercícios incorreta.')
        if all(e.get('type') == 'info' for e in l['exercises'] if isinstance(e,dict)):fail('A lição precisa de ao menos um exercício avaliativo.')
        for ex in l['exercises']:validate_exercise(ex,exercise_ids)

def file_key(unit: dict) -> str:
    return f"courses/v1/units/{unit['id']}-r{unit['revision']}.json"

def read_package(path: Path) -> list[tuple[dict,bytes]]:
    if not PACK_FILE.fullmatch(path.name) or not path.is_file() or path.stat().st_size>MAX_ZIP_BYTES:fail('ZIP de cursos ausente, mal nomeado ou grande demais.')
    try:
        with zipfile.ZipFile(path) as z:
            info=[x for x in z.infolist() if not x.is_dir()]
            names=[x.filename for x in info]
            if len(set(names))!=len(names) or PART_FILE not in names:fail('ZIP sem catálogo parcial ou duplicado.')
            for f in info:
                if '\\' in f.filename or f.filename.startswith('/') or any(c in ('','.','..') for c in f.filename.split('/')) or f.flag_bits&1 or (f.external_attr>>16)&0o170000 not in (0,0o100000):fail('ZIP contém caminho inseguro ou link.')
            if sum(f.file_size for f in info)>MAX_ZIP_BYTES:fail('ZIP descompactado muito grande.')
            summaries=parse_catalog(read_json(z.read(PART_FILE),MAX_CATALOG_BYTES),partial=True)
            if not summaries or set(names)!={PART_FILE}|{file_key(u) for u in summaries}:fail('ZIP deve conter somente o catálogo e as unidades declaradas.')
            ex_ids=set(); result=[]
            for summary in summaries:
                body=z.read(file_key(summary))
                validate_unit(read_json(body,MAX_UNIT_BYTES),summary,ex_ids)
                result.append((summary,serialized(read_json(body,MAX_UNIT_BYTES),MAX_UNIT_BYTES)))
            return result
    except zipfile.BadZipFile as exc:raise PublicationError('ZIP corrompido.') from exc

def merge_catalog(current: list[dict], incoming: list[dict]) -> list[dict]:
    merged={u['id']:u for u in current}
    for u in incoming:
        old=merged.get(u['id'])
        if old:
            if u['revision']<old['revision']:fail('Revisão da unidade não pode retroceder.')
            if u['revision']==old['revision'] and u!=old:fail('Revisão existente não pode mudar conteúdo: crie uma nova revisão.')
            if u['language']!=old['language'] or u['level']!=old['level'] or u['order']!=old['order']:fail('Identidade e posição de uma unidade publicada são permanentes.')
        merged[u['id']]=u
    units=sorted(merged.values(),key=lambda u:(u['language'],u['level'],u['order'],u['id']))
    parse_catalog({'version':1,'units':units},partial=False)
    return units

def get_object(client: Any,key:str) -> bytes|None:
    from botocore.exceptions import ClientError
    try: response=client.get_object(Bucket=BUCKET,Key=key)
    except ClientError as exc:
        if exc.response.get('Error',{}).get('Code') in ('NoSuchKey','NotFound','404'):return None
        raise
    return response['Body'].read(MAX_UNIT_BYTES+1)

def publish(client:Any,paths:list[Path])->tuple[int,int]:
    if not paths:fail('Nenhum lote de cursos encontrado.')
    units=[item for p in paths for item in read_package(p)]
    if not units or len(units)>16:fail('Máximo de 16 unidades por publicação.')
    raw=get_object(client,CATALOG_KEY)
    current=parse_catalog(read_json(raw,MAX_CATALOG_BYTES),partial=False) if raw is not None else []
    future=merge_catalog(current,[u for u,_ in units])
    manifest=serialized({'version':1,'units':future},MAX_CATALOG_BYTES)
    new_count=0;keys=set()
    for summary,body in units:
        key=file_key(summary)
        if key in keys:fail('Mesmo arquivo incluído duas vezes.')
        keys.add(key)
        remote=get_object(client,key)
        if remote is not None and remote!=body:fail('Arquivo versionado já existe com conteúdo diferente: '+key)
    for summary,body in units:
        key=file_key(summary)
        if get_object(client,key) is None:
            client.put_object(Bucket=BUCKET,Key=key,Body=body,ContentType='application/json; charset=utf-8',CacheControl='public, max-age=31536000, immutable')
            print('[Lunivo] Unidade enviada:',summary['id'],'revisão',summary['revision'])
            new_count+=1
        else:print('[Lunivo] Unidade idêntica já existente:',summary['id'])
    if raw!=manifest:
        client.put_object(Bucket=BUCKET,Key=CATALOG_KEY,Body=manifest,ContentType='application/json; charset=utf-8',CacheControl='public, max-age=300')
    print(f'[Lunivo] Catálogo de cursos publicado: {len(future)} unidades, {new_count} objetos novos.')
    return len(future),new_count

def main():
    parser=argparse.ArgumentParser();parser.add_argument('packages',nargs='*',type=Path);parser.add_argument('--check-only',action='store_true')
    args=parser.parse_args()
    account=os.environ.get('LUNIVO_R2_ACCOUNT_ID','');key=os.environ.get('LUNIVO_R2_ACCESS_KEY_ID','');secret=os.environ.get('LUNIVO_R2_SECRET_ACCESS_KEY','')
    if not re.fullmatch(r'[a-f0-9]{32}',account) or not key or not secret:fail('Credenciais R2 do GitHub não configuradas.')
    import boto3
    client=boto3.client('s3',endpoint_url=f'https://{account}.r2.cloudflarestorage.com',aws_access_key_id=key,aws_secret_access_key=secret,region_name='auto')
    if args.check_only:
        client.list_objects_v2(Bucket=BUCKET,MaxKeys=1)
        print('[Lunivo] Conexão R2 verificada para unidades de cursos.')
        return
    publish(client,args.packages)

if __name__=='__main__':
    try:main()
    except PublicationError as exc:
        print('ERRO LUNIVO: '+str(exc),file=sys.stderr)
        raise SystemExit(1) from exc
