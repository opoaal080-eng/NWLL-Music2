#!/usr/bin/env python3
"""Reproduce the bundled on-device ranker. Synthetic metadata, never users' playlists.

Artist/song groups are disjoint between training and held-out validation. Swift
exports the actual runtime features, avoiding a second normalization implementation.
This benchmark is a regression/augmentation set, not a catalogue-wide recall claim.
Run: python3 scripts/train-transfer-model.py --swiftc /path/to/swiftc
"""
import argparse, hashlib, json, os, random, subprocess, tempfile
from pathlib import Path
import numpy as np
from sklearn.neural_network import MLPClassifier
from sklearn.metrics import precision_score, recall_score

ROOT = Path(__file__).resolve().parents[1]
RNG = random.Random(20261112)
CYR = dict(zip('абвгдеёжзийклмнопрстуфхцчшщъыьэюя',
               ['a','b','v','g','d','e','e','zh','z','i','y','k','l','m','n','o','p','r','s','t','u','f','h','ts','ch','sh','sch','','y','','e','yu','ya']))

def translit(s):
    return ''.join(CYR.get(c,c) for c in s.lower())

def typo(s, level=1):
    result=list(s)
    for _ in range(level):
        positions=[i for i in range(1,len(result)-1) if result[i].isalpha()]
        if not positions: break
        i=RNG.choice(positions)
        if i+1<len(result) and result[i+1].isalpha() and RNG.random()<0.5:
            result[i],result[i+1]=result[i+1],result[i]
        else: result.pop(i)
    return ''.join(result)

def build_pairs():
    adjectives=['Северный','Тихий','Лунный','Ночной','Медленный','Синий','Золотой','Тёплый','Пустой','Дальний','Последний','Первый',
                'Silent','Golden','Northern','Silver','Midnight','Crimson','Hidden','Velvet','Distant','Electric','Winter','Summer']
    nouns=['ветер','город','берег','голос','свет','рассвет','поезд','парус','снег','океан','дождь','вокзал',
           'River','Station','Skyline','Echo','Signal','Garden','Horizon','Shadow','Harbor','Dream','Sunrise','Motion']
    groups=[]
    for i in range(160):
        title=adjectives[i%len(adjectives)]+' '+nouns[(i*7+i//24)%len(nouns)]
        artist=('Группа ' if i%2==0 else 'Studio ')+adjectives[(i*5+3)%24]+' '+nouns[(i*11+4)%24]
        groups.append({'title':title,'artist':artist,'duration':150+(i*17)%150})
    pairs=[]
    def add(q,c,label,group,kind):
        pairs.append({'query':q,'candidate':dict(c,id='candidate'),'label':label,'group':group,'kind':kind})
    for i,q in enumerate(groups):
        t,a=q['title'],q['artist']
        group=i%24
        other=next(g for j,g in enumerate(groups) if (j%24%5==0)==(group%5==0) and g['artist']!=a and g['title']!=t)
        positive=[(t,a,'exact'),(t+' (Official Audio)',a,'promotion'),(t+' [Lyrics Video 4K]',a,'promotion'),
                  (translit(t),translit(a),'transliteration'),(typo(t),a,'title_typo'),(t,typo(a),'artist_typo'),
                  (typo(t),typo(a),'both_typos'),(typo(t,2),a,'two_typos'),
                  (a+' — '+t,'Music Archive','embedded_artist'),(t,a+' & Guest Voice','collaboration'),
                  (t+' (feat. Guest Voice)',a,'featuring'),(t.replace(' ',''),a.replace(' ',''),'spacing'),
                  (' '.join(reversed(t.split())),a,'word_order')]
        for title,artist,kind in positive:
            c={'title':title,'artist':artist,'duration':q['duration']+RNG.choice([-2,0,1,2])}
            add(q,c,1,group,kind)
            if kind not in ('two_typos','both_typos'):
                add({k:v for k,v in q.items() if k!='duration'}, {k:v for k,v in c.items() if k!='duration'},1,group,kind+'_no_duration')
        for suffix in [' (Live)',' (DJ North Remix)',' (Acoustic)',' (Instrumental)',' (Sped Up)',' (Slowed + Reverb)']:
            add(q,dict(q,title=t+suffix),0,group,'wrong_version')
            add(dict(q,title=t+suffix),dict(q,title=t+suffix.replace('DJ North','DJ South')),int('Remix' not in suffix),group,'version_identity')
        add(q,dict(other,title=t,duration=q['duration']),0,group,'wrong_artist')
        add(q,dict(other,artist=a,duration=q['duration']),0,group,'wrong_song')
        add(q,dict(other),0,group,'unrelated')
        add(q,dict(q,duration=30),0,group,'preview')
        add(q,dict(q,duration=q['duration']+70),0,group,'wrong_duration')
        add(dict(q,artist=a+' & Guest Voice'),dict(q,artist='Guest Voice & '+a),1,group,'credit_order')
    # A stable split by identity prevents decorations of the same song leaking
    # from training into the held-out metric.
    for row in pairs: row['split']='validation' if row['group']%5==0 else 'train'
    primary={split:{r['query']['artist'].split(' & ')[0] for r in pairs if r['split']==split} for split in ('train','validation')}
    assert primary['train'].isdisjoint(primary['validation'])
    return pairs

def swift_array(values):
    if isinstance(values[0],list): return '[\n'+',\n'.join('        '+swift_array(row) for row in values)+'\n    ]'
    return '['+', '.join(format(float(x),'.9g') for x in values)+']'

def main():
    p=argparse.ArgumentParser(); p.add_argument('--swiftc',default='swiftc'); args=p.parse_args()
    pairs=build_pairs()
    with tempfile.TemporaryDirectory(prefix='nw-transfer-training-') as temp:
        d=Path(temp); source=d/'pairs.json'; source.write_text(json.dumps(pairs,ensure_ascii=False))
        binary=d/'features'
        subprocess.run([args.swiftc,'-O','-swift-version','5',str(ROOT/'NightwellMusic/TransferSimilarity.swift'),
            str(ROOT/'scripts/transfer-features.swift'),'-o',str(binary)],check=True)
        features=json.loads(subprocess.check_output([str(binary),str(source)]))
    x=np.array(features); y=np.array([r['label'] for r in pairs]); train=np.array([r['split']=='train' for r in pairs])
    model=MLPClassifier(hidden_layer_sizes=(32,16),activation='tanh',solver='adam',alpha=.01,
        learning_rate_init=.003,max_iter=350,random_state=1126,early_stopping=True,
        validation_fraction=.12,n_iter_no_change=35,batch_size=128,tol=1e-6)
    model.fit(x[train],y[train])
    probability=model.predict_proba(x[~train])[:,1]; prediction=probability>=.92
    report={'model':'transfer-metadata-v2','architecture':[16,32,16,1],
        'training':'deterministic synthetic metadata augmentations; no user data',
        'split':'disjoint primary-artist identities and song/artist pairs','seed':20261112,'train_pairs':int(train.sum()),
        'held_out_pairs':int((~train).sum()),'threshold':.92,
        'precision':float(precision_score(y[~train],prediction,zero_division=0)),
        'recall':float(recall_score(y[~train],prediction,zero_division=0)),
        'iterations':model.n_iter_, 'feature_source_sha256':hashlib.sha256((ROOT/'NightwellMusic/TransferSimilarity.swift').read_bytes()).hexdigest(),
        'limitations':'Synthetic pair classification only. Not measured catalogue or user-playlist recall. Runtime version/ISRC/duration and ambiguity guards also apply.'}
    weights=[w.T.tolist() for w in model.coefs_]; biases=[b.tolist() for b in model.intercepts_]
    checks=np.flatnonzero(~train)[::83]
    model_data={'report':report,'weights':weights,'biases':biases,
                'parity':[{'features':features[int(i)],'probability':float(model.predict_proba(x[i:i+1])[0,1])} for i in checks]}
    (ROOT/'scripts/fixtures/transfer-model-v2.json').write_text(json.dumps(model_data,ensure_ascii=False,indent=2)+'\n')
    header='''import Foundation\n\n// Generated by scripts/train-transfer-model.py. Do not edit weights by hand.\n// Versioned synthetic-data training; runtime metadata guards remain mandatory.\nenum TransferNeuralModel {\n    static let version = "transfer-metadata-v2"\n'''
    for n,(w,b) in enumerate(zip(weights,biases)):
        header+=f'    private static let w{n}: [[Double]] = '+swift_array(w)+'\n'
        header+=f'    private static let b{n}: [Double] = '+swift_array(b)+'\n'
    header+='''    private static func layer(_ input: [Double], _ weights: [[Double]], _ bias: [Double], hidden: Bool) -> [Double] {
        weights.indices.map { row in
            var value = bias[row]
            for i in input.indices { value += weights[row][i] * input[i] }
            return hidden ? tanh(value) : 1 / (1 + exp(-max(-30,min(30,value))))
        }
    }
    static func predict(_ features: [Double]) -> Double {
        guard features.count == 16, features.allSatisfy({ $0.isFinite }) else { return 0 }
        let first = layer(features,w0,b0,hidden:true)
        let second = layer(first,w1,b1,hidden:true)
        return layer(second,w2,b2,hidden:false)[0]
    }
}
'''
    (ROOT/'NightwellMusic/TransferNeuralModel.swift').write_text(header)
    print(json.dumps(report,indent=2))
if __name__=='__main__': main()
