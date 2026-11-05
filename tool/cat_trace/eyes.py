import json, numpy as np, cv2
from extract import cells, silhouette, R
HEAD=json.load(open('head.json'))
NAMES={1:'tsukiko',2:'lumi',3:'yuko'}
def find_eyes(img, box, mask):
    x0,y0,x1,y1=box
    crop=img[y0:y1,x0:x1].astype(np.int32)
    r,g,b=crop[...,0],crop[...,1],crop[...,2]
    mx=np.maximum(np.maximum(r,g),b); mn=np.minimum(np.minimum(r,g),b)
    white=((mx>205)&(mx-mn<40)&(mask>0)).astype(np.uint8)
    n,lab,st,cen=cv2.connectedComponentsWithStats(white)
    comps=sorted([(st[i,cv2.CC_STAT_AREA],cen[i]) for i in range(1,n) if st[i,cv2.CC_STAT_AREA]>40],key=lambda t:-t[0])
    # best pair: two biggest with similar y
    best=None
    for i in range(min(6,len(comps))):
        for j in range(i+1,min(6,len(comps))):
            a,b2=comps[i],comps[j]
            dy=abs(a[1][1]-b2[1][1]); dx=abs(a[1][0]-b2[1][0])
            if dx<25 or dy>0.5*dx: continue
            score=a[0]+b2[0]-3*dy
            if best is None or score>best[0]: best=(score,a,b2)
    _,a,b2=best
    L,Rr=sorted([a[1],b2[1]],key=lambda c:c[0])
    return np.array(L)+[x0,y0], np.array(Rr)+[x0,y0]
if __name__=='__main__':
    out={}
    for i,name in NAMES.items():
        img=cv2.cvtColor(cv2.imread(f'{R}/{['','tsukiko','lumi','yuko'][i]}.webp'),cv2.COLOR_BGR2RGB)
        vis=img.copy(); h=HEAD[name]; res=[]
        for k,box in enumerate(cells(img)):
            m,c=silhouette(img,box)
            L,Rr=find_eyes(img,box,m)
            mid=(L+Rr)/2; d=Rr-L; gap=np.hypot(*d); ang=np.arctan2(d[1],d[0])
            s=gap/h['gap']  # px per rx
            ca,sa=np.cos(ang),np.sin(ang)
            pts=np.array([[mid[0]+s*(x*ca-y*sa), mid[1]+s*(x*sa+y*ca)] for x,y in h['outline']]).astype(np.int32)
            cv2.polylines(vis,[pts.reshape(-1,1,2)],True,(0,160,0),2)
            for e in (L,Rr): cv2.circle(vis,tuple(int(v) for v in e),4,(255,0,0),-1)
            res.append({'mid':mid.tolist(),'gap':float(gap),'ang':float(ang),'scale':float(s)})
        out[name]=res
        cv2.imwrite(f'eyes{i}.png',cv2.cvtColor(cv2.resize(vis,(vis.shape[1]//2,vis.shape[0]//2)),cv2.COLOR_RGB2BGR))
    json.dump(out,open('eyes.json','w'),indent=0)
    for k,v in out.items(): print(k,[round(r['scale'],1) for r in v],[round(np.degrees(r['ang']),1) for r in v])
